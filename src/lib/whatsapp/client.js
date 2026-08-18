// Meta WhatsApp Cloud API (official, direct — no BSP middleman) helper.
// Requires WHATSAPP_ACCESS_TOKEN + WHATSAPP_PHONE_NUMBER_ID from a Meta app
// with the WhatsApp product added (developers.facebook.com/apps).
//
// Only needed if you're using the official /api/whatsapp/webhook route in
// this service. The free /api/whatsapp/auto-reply channel doesn't call
// this — it just returns plain text for your automation app to send.

const GRAPH_API_VERSION = "v20.0";

function getConfig() {
  const accessToken = process.env.WHATSAPP_ACCESS_TOKEN;
  const phoneNumberId = process.env.WHATSAPP_PHONE_NUMBER_ID;

  if (!accessToken || !phoneNumberId) {
    throw new Error(
      "WhatsApp is not configured: set WHATSAPP_ACCESS_TOKEN and WHATSAPP_PHONE_NUMBER_ID in the environment."
    );
  }

  return { accessToken, phoneNumberId };
}

/** Normalizes a phone number to WhatsApp's expected format (digits only, country code, no +/spaces/dashes). */
export function normalizeMsisdn(raw) {
  return String(raw ?? "").replace(/[^\d]/g, "");
}

/**
 * Sends a plain text WhatsApp message via the Meta Cloud API.
 * Throws on failure — callers should catch and log; a failed reply should
 * never crash the webhook handler (Meta will retry the *inbound* delivery,
 * not our reply, so we just log and move on).
 */
export async function sendWhatsAppMessage(toPhone, body) {
  const { accessToken, phoneNumberId } = getConfig();
  const to = normalizeMsisdn(toPhone);

  const response = await fetch(`https://graph.facebook.com/${GRAPH_API_VERSION}/${phoneNumberId}/messages`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      to,
      type: "text",
      text: { preview_url: false, body },
    }),
  });

  if (!response.ok) {
    const errText = await response.text().catch(() => "");
    throw new Error(`WhatsApp send failed (${response.status}): ${errText}`);
  }
}

/**
 * Parses a Meta Cloud API webhook POST payload into a flat list of incoming
 * text messages, ignoring status callbacks (delivered/read receipts) and
 * non-text message types (images, reactions, etc.) which this bot doesn't
 * process.
 */
export function parseIncomingMessages(payload) {
  const messages = [];

  try {
    const entries = payload?.entry ?? [];
    for (const entry of entries) {
      const changes = entry?.changes ?? [];
      for (const change of changes) {
        const value = change?.value;
        const contacts = value?.contacts ?? [];
        const msgs = value?.messages ?? [];

        for (const msg of msgs) {
          if (msg.type !== "text" || !msg.text?.body) continue;
          const contact = contacts.find((c) => c.wa_id === msg.from);
          messages.push({
            from: msg.from,
            text: String(msg.text.body).trim(),
            profileName: contact?.profile?.name ?? null,
            messageId: msg.id,
          });
        }
      }
    }
  } catch {
    // Malformed payload — return whatever we managed to parse before the error.
  }

  return messages;
}
