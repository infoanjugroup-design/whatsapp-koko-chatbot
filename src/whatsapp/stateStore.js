// Persists conversation state for the WhatsApp auto-reply channel, keyed by
// phone number, in the whatsapp_chat_state table (see sql/ for the
// migration). A notification-automation app (AutoResponder/Tasker) has no
// cookie jar — every call to /api/whatsapp/auto-reply is a fresh,
// independent HTTP request — so "what step of registration is this phone
// on" has to be looked up and written back on every message instead.

const IDLE = { step: "idle" };

export async function loadState(supabase, phone) {
  const { data, error } = await supabase
    .from("whatsapp_chat_state")
    .select("flow_json, session_json")
    .eq("phone", phone)
    .maybeSingle();

  if (error) {
    console.error("whatsapp_chat_state load error:", error);
    return { flow: IDLE, session: null };
  }
  if (!data) return { flow: IDLE, session: null };

  return {
    flow: data.flow_json ?? IDLE,
    session: data.session_json ?? null,
  };
}

/**
 * Writes back the flow/session state after handleChatMessage() runs.
 * `newSession` follows the same convention as ChatResult.session:
 * undefined = leave session unchanged, null = log out (clear it).
 */
export async function saveState(supabase, phone, newFlow, currentSession, newSession) {
  const session = newSession === undefined ? currentSession : newSession;

  const { error } = await supabase.from("whatsapp_chat_state").upsert({
    phone,
    flow_json: newFlow.step === "idle" ? null : newFlow,
    session_json: session,
    updated_at: new Date().toISOString(),
  });

  if (error) {
    console.error("whatsapp_chat_state save error:", error);
  }
}
