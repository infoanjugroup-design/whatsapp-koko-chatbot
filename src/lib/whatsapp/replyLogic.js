// Pure "what should we reply" logic for the OFFICIAL Meta Cloud API number
// (app/api/whatsapp/webhook on the main site). This channel intentionally
// stays redirect-only — no coin/wallet logic here — and points people at
// the full chatbot instead (the website widget, or this service's own
// /api/whatsapp/auto-reply channel if that's what you've wired your QR
// codes to). No side effects, no Supabase calls.

const SITE_URL = (process.env.NEXT_PUBLIC_SITE_URL || "https://kokofoods.in").replace(/\/$/, "");

function chatbotLink(claimCode) {
  return claimCode ? `${SITE_URL}/?claim=${encodeURIComponent(claimCode)}` : SITE_URL;
}

const MOVED_TEXT =
  "🍿 *koko rewards has a new home!*\n\n" +
  "Coin claiming, balance, referrals, and payouts are now handled by the *koko chatbot* — quicker, and works even without this WhatsApp number.\n\n" +
  `👉 ${chatbotLink()}\n\n` +
  "Just tap the chat bubble on the site, log in (or register in a few seconds), and it picks up right where WhatsApp left off.";

/**
 * Given an inbound message's raw text, returns the text we should reply
 * with. Never throws — falls back to MOVED_TEXT for anything unrecognized.
 */
export function resolveReply(textRaw) {
  const text = (textRaw ?? "").trim();
  const upperText = text.toUpperCase();

  if (upperText.startsWith("CLAIM-") && !upperText.startsWith("CLAIMBOX-")) {
    return (
      "🍿 Coin claiming has moved to the koko chatbot — tap below and it'll claim this code for you automatically once you're logged in:\n\n" +
      chatbotLink(text)
    );
  }

  if (upperText.startsWith("CLAIMBOX-")) {
    return (
      "🍿 Box coin claiming has moved to the koko chatbot — tap below and it'll claim this code for you automatically once you're logged in:\n\n" +
      chatbotLink(text)
    );
  }

  // Default also covers BALANCE/BAL/REFER/REFERRAL/PAYOUT* — every one of
  // those now just points at the full chatbot anyway.
  return MOVED_TEXT;
}
