// GET  /api/whatsapp/webhook — Meta's one-time verification handshake.
// POST /api/whatsapp/webhook — inbound message events.
//
// This webhook stays redirect-only on purpose (same behavior as the main
// koko-website app's version) — it does NOT call claim_packet_coins /
// claim_box_coins / redeem_payout or read user_wallets directly. It just
// keeps responding to WhatsApp (so Meta doesn't mark the number as broken)
// and points coin-related messages at the full chatbot.
//
// Configure this URL as the webhook callback in Meta App Dashboard →
// WhatsApp → Configuration, using WHATSAPP_WEBHOOK_VERIFY_TOKEN below as
// the verify token.

import { Router } from "express";
import { sendWhatsAppMessage, parseIncomingMessages, normalizeMsisdn } from "../lib/whatsapp/client.js";
import { resolveReply } from "../lib/whatsapp/replyLogic.js";

const router = Router();

router.get("/", (req, res) => {
  const mode = req.query["hub.mode"];
  const token = req.query["hub.verify_token"];
  const challenge = req.query["hub.challenge"];

  const expectedToken = process.env.WHATSAPP_WEBHOOK_VERIFY_TOKEN;

  if (mode === "subscribe" && expectedToken && token === expectedToken) {
    return res.status(200).type("text/plain").send(challenge ?? "");
  }

  return res.status(403).json({ error: "Verification failed" });
});

router.post("/", async (req, res) => {
  try {
    const payload = req.body;
    const messages = parseIncomingMessages(payload);

    if (messages.length === 0) {
      // Status callbacks (sent/delivered/read) land here too — always 200 so Meta doesn't retry.
      return res.json({ received: true });
    }

    for (const msg of messages) {
      try {
        await handleIncomingMessage(msg.from, msg.text);
      } catch (err) {
        // One malformed/unlucky message should never fail the whole batch.
        console.error("WhatsApp message handling error:", err, { from: msg.from, text: msg.text });
        await sendWhatsAppMessage(msg.from, "Sorry, something went wrong. Please try again in a moment.").catch(() => {});
      }
    }

    return res.json({ received: true });
  } catch (err) {
    console.error("WhatsApp webhook error:", err);
    // Still 200 — a non-200 makes Meta re-deliver the same payload repeatedly.
    return res.json({ received: true });
  }
});

async function handleIncomingMessage(fromRaw, textRaw) {
  const phone = normalizeMsisdn(fromRaw);
  await sendWhatsAppMessage(phone, resolveReply(textRaw));
}

export default router;
