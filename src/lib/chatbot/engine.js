// The koko-chatbot brain. Rule-based (keyword/regex matching) on purpose —
// no LLM round-trip in the hot path, so replies are effectively instant and
// 100% deterministic for money-moving actions like coin claims and payouts.
//
// Ported 1:1 from the main koko-website app's lib/chatbot/engine.ts so
// behavior and copy stay identical between the website widget and this
// WhatsApp channel. Uses the exact same Supabase RPCs — award_coins /
// claim_packet_coins / claim_box_coins / redeem_payout — so wallets/
// balances stay one single source of truth in user_wallets/coin_transactions
// regardless of which channel a user came from.
//
// Auth here is NOT Supabase Auth — it's koko-chatbot's own mobile+password
// system layered onto the same `user_wallets` table (password_hash,
// is_web_registered columns, added by the main app's 0011 migration).
//
// IMPORTANT: this file assumes the main koko-website Supabase schema is
// already applied to your project — user_wallets, coin_transactions,
// chatbot_password_resets tables, and the award_coins / claim_packet_coins /
// claim_box_coins / redeem_payout RPCs (from the main app's migrations
// 0001, 0006, 0011, 0012). This service does not create or own that schema —
// see sql/ in this repo for the one table this service adds on top
// (whatsapp_chat_state).

import { hashPassword, verifyPassword } from "./password.js";
import { sendPasswordResetOtp } from "../email/sendOtp.js";
import { randomInt, createHash } from "node:crypto";

const IDLE = { step: "idle" };
const MENU_QUICK_REPLIES = ["Register", "Login", "Balance", "Help"];

export function normalizePhone(raw) {
  return String(raw ?? "")
    .replace(/[^\d]/g, "")
    .replace(/^91(?=\d{10}$)/, "");
}
function isValidPhone(phone) {
  return /^[6-9]\d{9}$/.test(phone);
}
function isValidEmail(email) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

const HELP_TEXT = [
  "🍿 *koko* — main kya kar sakta hoon:",
  "• *REGISTER* — mobile, naam, email aur password se account banao",
  "• *LOGIN* — apne account me login karo",
  "• *CLAIM-<code>* — packet ka coin code claim karo",
  "• *BALANCE* — coin balance + expiry dekho",
  "• *PROFILE* — apni details dekho",
  "• *REFER* — apna referral code paao",
  "• *PAYOUT* — coins ko cash me redeem karo (monetization)",
  "• *LOGOUT* — session khatam karo",
].join("\n");

export async function handleChatMessage(supabase, rawText, flow, session) {
  const text = String(rawText ?? "").trim().slice(0, 500);
  const upper = text.toUpperCase();

  if (!text) {
    return { reply: ["Kuch toh likho! 🙂"], flow };
  }

  if (upper === "CANCEL" && flow.step !== "idle") {
    return { reply: ["Theek hai, cancel kar diya."], flow: IDLE, quickReplies: MENU_QUICK_REPLIES };
  }

  // ---- Mid-flow steps take priority over global commands ----
  if (flow.step !== "idle") {
    return continueFlow(supabase, text, upper, flow, session);
  }

  // ---- Global commands (idle state) ----
  if (/^(register|sign\s*up|account\s*bana)/i.test(text)) {
    if (session) return { reply: [`Aap already logged in ho, ${session.name || "koko user"}! Type PROFILE to see your details.`], flow: IDLE };
    return { reply: ["Chaliye account banate hain! 📱 Apna 10-digit mobile number bhejo."], flow: { step: "register_phone" } };
  }

  if (/^(log\s*in|sign\s*in)$/i.test(text)) {
    if (session) return { reply: [`Aap already logged in ho, ${session.name || "koko user"}!`], flow: IDLE };
    return { reply: ["📱 Apna registered mobile number bhejo."], flow: { step: "login_phone" } };
  }

  if (/^logout$/i.test(text)) {
    if (!session) return { reply: ["Aap login nahi ho."], flow: IDLE };
    return { reply: ["👋 Aap logout ho gaye. Phir milte hain!"], flow: IDLE, session: null };
  }

  if (/^forgot/i.test(text)) {
    return { reply: ["Password reset karte hain. 📧 Apna registered email address bhejo."], flow: { step: "forgot_email" } };
  }

  if (upper.startsWith("CLAIM-") && !upper.startsWith("CLAIMBOX-")) {
    return claimPacket(supabase, session, text);
  }

  if (upper.startsWith("CLAIMBOX-")) {
    return claimBox(supabase, session, text);
  }

  if (upper === "BALANCE" || upper === "BAL" || upper === "COINS") {
    return showBalance(supabase, session);
  }

  if (upper === "PROFILE" || upper === "MY PROFILE") {
    return showProfile(supabase, session);
  }

  if (upper === "REFER" || upper === "REFERRAL") {
    return showReferral(supabase, session);
  }

  if (/^(payout|redeem|withdraw|monetiz)/i.test(text)) {
    if (!session) return needLogin();
    return { reply: ["💸 Apna UPI ID bhejo (jaise yourname@upi) — 25,000 coins ko ₹250 me redeem karenge."], flow: { step: "payout_upi" } };
  }

  if (upper === "HELP" || upper === "MENU") {
    return { reply: [HELP_TEXT], flow: IDLE, quickReplies: MENU_QUICK_REPLIES };
  }

  return {
    reply: [session ? `Samajh nahi aaya. Type HELP for menu.` : "Namaste! 🍿 Main koko hoon. Type REGISTER to create an account, ya LOGIN, ya HELP for full menu."],
    flow: IDLE,
    quickReplies: MENU_QUICK_REPLIES,
  };
}

function needLogin() {
  return { reply: ["Pehle LOGIN ya REGISTER karo, phir ye kaam ho payega."], flow: IDLE, quickReplies: ["Login", "Register"] };
}

async function continueFlow(supabase, text, upper, flow, session) {
  switch (flow.step) {
    // ---------------- REGISTRATION WIZARD ----------------
    case "register_phone": {
      const phone = normalizePhone(text);
      if (!isValidPhone(phone)) {
        return { reply: ["Ye valid 10-digit mobile number nahi lag raha. Phir se try karo (e.g. 9876543210)."], flow };
      }
      const { data: existing } = await supabase.from("user_wallets").select("is_web_registered").eq("phone", phone).maybeSingle();
      if (existing?.is_web_registered) {
        return { reply: ["Is number se already ek account hai. Type LOGIN karke login karo."], flow: IDLE, quickReplies: ["Login"] };
      }
      return { reply: ["👤 Apna naam bhejo."], flow: { step: "register_name", phone } };
    }

    case "register_name": {
      if (text.length < 2 || text.length > 60) {
        return { reply: ["Naam thoda chota/bada lag raha. 2-60 characters me bhejo."], flow };
      }
      return { reply: ["📧 Ab apna email address bhejo."], flow: { step: "register_email", phone: flow.phone, name: text } };
    }

    case "register_email": {
      if (!isValidEmail(text)) {
        return { reply: ["Ye valid email nahi lag raha. Phir se try karo."], flow };
      }
      const { data: existing } = await supabase.from("user_wallets").select("phone").ilike("email", text).maybeSingle();
      if (existing) {
        return { reply: ["Is email se already ek account registered hai. Type LOGIN karo, ya doosra email try karo."], flow, quickReplies: ["Login"] };
      }
      return { reply: ["🔒 Ab ek password set karo (kam se kam 6 characters)."], flow: { step: "register_password", phone: flow.phone, name: flow.name, email: text } };
    }

    case "register_password": {
      if (text.length < 6) {
        return { reply: ["Password kam se kam 6 characters ka hona chahiye. Phir try karo."], flow };
      }
      const passwordHash = await hashPassword(text);
      return {
        reply: ["🎟️ Koi coupon/referral code hai? Type karo, ya *SKIP* likho (ye optional hai)."],
        flow: { step: "register_coupon", phone: flow.phone, name: flow.name, email: flow.email, passwordHash },
      };
    }

    case "register_coupon": {
      let couponCode = null;
      let referrerPhone = null;

      if (upper !== "SKIP") {
        const { data: referrer, error: lookupErr } = await supabase
          .from("user_wallets")
          .select("phone")
          .eq("referral_code", text.trim().toUpperCase())
          .maybeSingle();
        if (lookupErr) {
          console.error("register_coupon referral lookup error:", lookupErr);
        }
        if (!referrer) {
          return { reply: ["Ye coupon code valid nahi mila. Phir try karo, ya *SKIP* likho."], flow };
        }
        couponCode = text.trim().toUpperCase();
        referrerPhone = referrer.phone;
      }

      // Create/upgrade the wallet — a phone that already has a WhatsApp-only
      // wallet (name/coins from packet scans) simply gets login layered on
      // top; coins are unified, nothing is lost or duplicated.
      const { data: wallet, error: upsertError } = await supabase
        .from("user_wallets")
        .upsert(
          {
            phone: flow.phone,
            name: flow.name,
            email: flow.email,
            password_hash: flow.passwordHash,
            is_web_registered: true,
            referred_by: referrerPhone,
          },
          { onConflict: "phone" }
        )
        .select()
        .single();

      if (upsertError || !wallet) {
        console.error("chatbot registration upsert error:", upsertError);
        return { reply: ["Registration me kuch gadbad ho gayi, please phir try karo."], flow: IDLE };
      }

      let bonusLine = "";
      if (couponCode && referrerPhone) {
        const { error: bonusErr } = await supabase.rpc("award_coins", {
          p_phone: flow.phone,
          p_amount: 15,
          p_type: "coupon_bonus",
          p_packet_code: null,
          p_metadata: { coupon: couponCode },
        });
        if (!bonusErr) {
          bonusLine = "\n🪙 +15 coins coupon bonus!";
          await supabase.rpc("award_coins", {
            p_phone: referrerPhone,
            p_amount: 25,
            p_type: "referral_bonus",
            p_packet_code: null,
            p_metadata: { referred_phone: flow.phone, via: "whatsapp_registration" },
          });
        }
      }

      const { data: fresh } = await supabase.from("user_wallets").select("coin_balance, referral_code").eq("phone", flow.phone).single();

      return {
        reply: [
          `✅ Welcome to koko, ${flow.name}! Aapka account ban gaya.${bonusLine}`,
          `💰 Balance: ${fresh?.coin_balance ?? 0} coins\n🤝 Referral code: ${fresh?.referral_code ?? "-"}\n\nType PROFILE, BALANCE, ya HELP.`,
        ],
        flow: IDLE,
        session: { phone: flow.phone, name: flow.name },
        quickReplies: ["Balance", "Profile", "Help"],
      };
    }

    // ---------------- LOGIN WIZARD ----------------
    case "login_phone": {
      const phone = normalizePhone(text);
      if (!isValidPhone(phone)) {
        return { reply: ["Ye valid mobile number nahi lag raha. Phir try karo."], flow };
      }
      const { data: wallet } = await supabase.from("user_wallets").select("is_web_registered").eq("phone", phone).maybeSingle();
      if (!wallet?.is_web_registered) {
        return { reply: ["Is number se koi account nahi mila. Type REGISTER karke naya account banao."], flow: IDLE, quickReplies: ["Register"] };
      }
      return { reply: ["🔒 Password bhejo. (Bhool gaye? Type FORGOT)"], flow: { step: "login_password", phone, attempts: 0 } };
    }

    case "login_password": {
      if (upper === "FORGOT") {
        return { reply: ["📧 Apna registered email address bhejo."], flow: { step: "forgot_email" } };
      }
      const { data: wallet } = await supabase.from("user_wallets").select("name, password_hash").eq("phone", flow.phone).maybeSingle();
      const ok = await verifyPassword(text, wallet?.password_hash ?? null);
      if (!ok) {
        const attempts = flow.attempts + 1;
        if (attempts >= 5) {
          return { reply: ["Bahut saare galat attempts. Type LOGIN karke phir try karo."], flow: IDLE };
        }
        return { reply: [`Galat password. Phir try karo. (${5 - attempts} attempts left, ya type FORGOT)`], flow: { ...flow, attempts } };
      }
      const { data: fresh } = await supabase.from("user_wallets").select("coin_balance").eq("phone", flow.phone).single();
      return {
        reply: [`✅ Welcome back, ${wallet?.name || "koko user"}!\n💰 Balance: ${fresh?.coin_balance ?? 0} coins`],
        flow: IDLE,
        session: { phone: flow.phone, name: wallet?.name ?? null },
        quickReplies: ["Balance", "Profile", "Help"],
      };
    }

    // ---------------- FORGOT PASSWORD WIZARD ----------------
    case "forgot_email": {
      if (!isValidEmail(text)) {
        return { reply: ["Ye valid email nahi lag raha. Phir try karo."], flow };
      }
      const { data: wallet } = await supabase.from("user_wallets").select("phone").ilike("email", text).maybeSingle();
      if (!wallet) {
        return { reply: ["Is email se koi account nahi mila."], flow: IDLE };
      }
      const otp = String(randomInt(100000, 999999));
      const otpHash = createHash("sha256").update(otp).digest("hex");
      const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();

      const { error: insertErr } = await supabase.from("chatbot_password_resets").insert({
        phone: wallet.phone,
        email: text,
        otp_hash: otpHash,
        expires_at: expiresAt,
      });
      if (insertErr) {
        console.error("chatbot_password_resets insert error:", insertErr);
        return { reply: ["Kuch gadbad ho gayi, please phir try karo."], flow: IDLE };
      }

      try {
        await sendPasswordResetOtp(text, otp);
      } catch (err) {
        console.error("sendPasswordResetOtp error:", err);
        return { reply: ["OTP email bhejne me dikkat aa rahi hai. Thodi der baad try karo, ya support se contact karo."], flow: IDLE };
      }

      return { reply: ["📨 OTP aapke email par bhej diya hai (10 minute valid). Wo 6-digit code yahan bhejo."], flow: { step: "forgot_otp", phone: wallet.phone, email: text, attempts: 0 } };
    }

    case "forgot_otp": {
      const otpHash = createHash("sha256").update(text.trim()).digest("hex");
      const { data: resetRow } = await supabase
        .from("chatbot_password_resets")
        .select("id, otp_hash, expires_at, used")
        .eq("phone", flow.phone)
        .eq("email", flow.email)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();

      const valid =
        resetRow && !resetRow.used && resetRow.otp_hash === otpHash && new Date(resetRow.expires_at) > new Date();

      if (!valid) {
        const attempts = flow.attempts + 1;
        if (attempts >= 5) {
          return { reply: ["Bahut saare galat attempts. Type FORGOT karke phir se shuru karo."], flow: IDLE };
        }
        return { reply: [`Galat ya expired OTP. Phir try karo. (${5 - attempts} attempts left)`], flow: { ...flow, attempts } };
      }

      await supabase.from("chatbot_password_resets").update({ used: true }).eq("id", resetRow.id);

      return { reply: ["✅ OTP verify ho gaya! Ab naya password bhejo (kam se kam 6 characters)."], flow: { step: "forgot_new_password", phone: flow.phone, email: flow.email } };
    }

    case "forgot_new_password": {
      if (text.length < 6) {
        return { reply: ["Password kam se kam 6 characters ka hona chahiye. Phir try karo."], flow };
      }
      const passwordHash = await hashPassword(text);
      const { error } = await supabase.from("user_wallets").update({ password_hash: passwordHash }).eq("phone", flow.phone);
      if (error) {
        console.error("password reset update error:", error);
        return { reply: ["Password update nahi ho paaya, please phir try karo."], flow: IDLE };
      }
      return { reply: ["✅ Password successfully update ho gaya! Ab type LOGIN karke login karo."], flow: IDLE, quickReplies: ["Login"] };
    }

    // ---------------- PAYOUT ----------------
    case "payout_upi": {
      if (!session) return needLogin();
      if (!text.includes("@")) {
        return { reply: ["Ye valid UPI ID nahi lag raha (jaise yourname@upi). Phir try karo."], flow };
      }
      const { data, error } = await supabase.rpc("redeem_payout", {
        p_phone: session.phone,
        p_upi_id: text,
        p_coins: 25000,
        p_amount_inr: 250.0,
      });
      if (error) {
        console.error("redeem_payout error:", error);
        return { reply: ["Payout process nahi ho paaya, please phir try karo."], flow: IDLE };
      }
      const result = data?.[0];
      return { reply: [result?.ok ? `✅ ${result.message}` : `❌ ${result?.message ?? "Payout request fail ho gaya."}`], flow: IDLE };
    }

    default:
      return { reply: [HELP_TEXT], flow: IDLE, quickReplies: MENU_QUICK_REPLIES };
  }
}

async function claimPacket(supabase, session, text) {
  if (!session) return needLogin();
  const coinCode = text.replace(/^CLAIM-/i, "").trim();
  const { data, error } = await supabase.rpc("claim_packet_coins", {
    p_phone: session.phone,
    p_coin_code: coinCode,
    p_name: session.name,
    p_referral_code: null,
  });
  if (error) {
    console.error("claim_packet_coins error:", error);
    return { reply: ["Claim process nahi ho paaya, please phir try karo."], flow: IDLE };
  }
  const result = data?.[0];
  if (!result) return { reply: ["Claim process nahi ho paaya, please phir try karo."], flow: IDLE };
  return {
    reply: [result.ok ? `✅ ${result.message}\n+${result.coins_awarded} coins earned.\n💰 Balance: ${result.new_balance} coins.` : `❌ ${result.message}`],
    flow: IDLE,
  };
}

async function claimBox(supabase, session, text) {
  if (!session) return needLogin();
  const boxSerial = text.replace(/^CLAIMBOX-/i, "KOKO-BOX-").trim();
  const { data, error } = await supabase.rpc("claim_box_coins", {
    p_phone: session.phone,
    p_box_serial: boxSerial,
    p_name: session.name,
  });
  if (error) {
    console.error("claim_box_coins error:", error);
    return { reply: ["Box claim process nahi ho paaya, please phir try karo."], flow: IDLE };
  }
  const result = data?.[0];
  if (!result) return { reply: ["Box claim process nahi ho paaya, please phir try karo."], flow: IDLE };
  return {
    reply: [result.ok ? `✅ ${result.message}\n+${result.coins_awarded} coins earned.\n💰 Balance: ${result.new_balance} coins.` : `❌ ${result.message}`],
    flow: IDLE,
  };
}

async function showBalance(supabase, session) {
  if (!session) return needLogin();
  const { data: wallet } = await supabase
    .from("user_wallets")
    .select("coin_balance, total_referrals_count, total_packets_scanned")
    .eq("phone", session.phone)
    .maybeSingle();

  if (!wallet) return { reply: ["Wallet nahi mila."], flow: IDLE };

  const { data: nextExpiry } = await supabase
    .from("coin_transactions")
    .select("amount, expires_at")
    .eq("phone", session.phone)
    .gt("amount", 0)
    .gt("expires_at", new Date().toISOString())
    .order("expires_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  const expiryLine = nextExpiry
    ? `⏳ ${nextExpiry.amount} coins expire on ${new Date(nextExpiry.expires_at).toLocaleDateString("en-IN", { day: "numeric", month: "short", year: "numeric" })}`
    : "⏳ No coins expiring soon";

  return {
    reply: [
      `💰 Balance: ${wallet.coin_balance} coins\n📦 Packets scanned: ${wallet.total_packets_scanned}\n🤝 Referrals: ${wallet.total_referrals_count}\n${expiryLine}`,
    ],
    flow: IDLE,
    quickReplies: ["Profile", "Payout", "Help"],
  };
}

async function showProfile(supabase, session) {
  if (!session) return needLogin();
  const { data: wallet } = await supabase
    .from("user_wallets")
    .select("name, phone, email, coin_balance, referral_code, is_creator_monetized, total_referrals_count, total_packets_scanned, created_at")
    .eq("phone", session.phone)
    .maybeSingle();

  if (!wallet) return { reply: ["Profile nahi mila."], flow: IDLE };

  return {
    reply: [
      [
        `👤 *${wallet.name || "koko user"}*`,
        `📱 ${wallet.phone}`,
        wallet.email ? `📧 ${wallet.email}` : null,
        `💰 ${wallet.coin_balance} coins`,
        `🤝 Referral code: ${wallet.referral_code}`,
        `📦 ${wallet.total_packets_scanned} packets scanned · ${wallet.total_referrals_count} referrals`,
        wallet.is_creator_monetized ? "⭐ Monetized creator" : null,
        `📅 Member since ${new Date(wallet.created_at).toLocaleDateString("en-IN", { day: "numeric", month: "short", year: "numeric" })}`,
      ]
        .filter(Boolean)
        .join("\n"),
    ],
    flow: IDLE,
    quickReplies: ["Balance", "Payout", "Help"],
  };
}

async function showReferral(supabase, session) {
  if (!session) return needLogin();
  const { data: wallet } = await supabase.from("user_wallets").select("referral_code").eq("phone", session.phone).maybeSingle();
  if (!wallet) return { reply: ["Referral code nahi mila."], flow: IDLE };
  return { reply: [`🤝 Aapka referral code: *${wallet.referral_code}*\nShare karo — jab koi isse register/scan karta hai to aapko 25 coins milte hain.`], flow: IDLE };
}
