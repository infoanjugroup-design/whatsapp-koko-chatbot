// Free/unofficial WhatsApp channel — see README "Phone-side setup".
//
// A spare Android phone stays logged into a normal WhatsApp or WhatsApp
// Business account, and a notification-reading automation app on that phone
// (AutoResponder for WhatsApp, Tasker + a WhatsApp plugin, etc.) is
// configured to:
//   1. Trigger on "new WhatsApp message" notifications.
//   2. Call this endpoint with the sender's number and message text.
//   3. Send whatever plain text this endpoint returns back through
//      WhatsApp itself, using the phone's own session.
//
// Runs the full chatbot engine (src/lib/chatbot/engine.js) — register,
// login, CLAIM-/CLAIMBOX- coin claims, BALANCE, PROFILE, REFER, PAYOUT.
// Per-phone state lives in Supabase (whatsapp_chat_state table) since a
// notification-automation app has no cookie jar.
//
// Money-moving actions (coin claim, payout) ARE reachable through this
// channel — login still requires the real mobile+password check before
// PROFILE/BALANCE/PAYOUT/claims work. Protect AUTO_REPLY_SHARED_SECRET.
//
// Because the request format differs between automation apps, this accepts
// several common shapes rather than one fixed schema:
//   GET  /api/whatsapp/auto-reply?message=...&phone=...
//   POST { "message": "...", "phone": "..." }        (JSON)
//   POST { "text": "...", "sender": "..." }           (JSON, alt names)
//   POST message=...&phone=...                        (form-encoded)
//
// Auth: set AUTO_REPLY_SHARED_SECRET and configure your automation app to
// send it as either ?key=... or an "x-auto-reply-key" header.

import { Router } from "express";
import { getSupabaseAdmin } from "../lib/supabaseAdmin.js";
import { handleChatMessage, normalizePhone } from "../lib/chatbot/engine.js";
import { loadState, saveState } from "../lib/whatsapp/stateStore.js";

const router = Router();

function isAuthorized(req) {
  const expected = process.env.AUTO_REPLY_SHARED_SECRET;
  if (!expected) return true; // no secret configured — open (fine for local testing only)
  const provided = req.headers["x-auto-reply-key"] || req.query.key;
  return provided === expected;
}

function extractFields(req) {
  const q = req.query || {};
  const queryMessage = q.message || q.text;
  const queryPhone = q.phone || q.sender || q.from;
  if (queryMessage || queryPhone) {
    return { message: queryMessage ?? "", phone: queryPhone ?? "" };
  }

  const body = req.body || {};
  return {
    message: body.message ?? body.text ?? body.body ?? "",
    phone: body.phone ?? body.sender ?? body.from ?? "",
  };
}

async function handle(req, res) {
  if (!isAuthorized(req)) {
    return res.status(401).type("text/plain").send("Unauthorized");
  }

  const { message, phone: rawPhone } = extractFields(req);
  const phone = normalizePhone(rawPhone);

  if (!phone) {
    // Automation app sent no usable sender number — nothing to key state
    // on, so we can't run the stateful engine. Check extractFields()
    // against what your app actually sends (its "test request" / logs
    // screen usually shows the exact field names).
    return res
      .type("text/plain; charset=utf-8")
      .send("Kuch technical dikkat aa gayi — please thodi der baad try karo.");
  }

  const supabase = getSupabaseAdmin();
  const { flow, session } = await loadState(supabase, phone);

  const result = await handleChatMessage(supabase, message, flow, session);

  await saveState(supabase, phone, result.flow, session, result.session);

  const replyText = result.reply.join("\n\n");

  // Plain text response — most notification-automation apps use the raw
  // response body as the reply, not a JSON field. If yours expects JSON,
  // e.g. { "reply": "..." }, change this to res.json({ reply: replyText }).
  res.type("text/plain; charset=utf-8").send(replyText);
}

router.get("/", (req, res, next) => handle(req, res).catch(next));
router.post("/", (req, res, next) => handle(req, res).catch(next));

export default router;
