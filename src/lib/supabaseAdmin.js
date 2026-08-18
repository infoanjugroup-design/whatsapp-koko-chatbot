// Service-role Supabase client. Bypasses RLS — this file is only ever used
// server-side (never bundled to a browser, since this whole service has no
// frontend). Same project as the main koko-website app: this service does
// NOT own its own schema, it reads/writes the same user_wallets,
// coin_transactions, chatbot_password_resets, and whatsapp_chat_state
// tables the main site's Supabase project already has.

import { createClient } from "@supabase/supabase-js";

let cached = null;

export function getSupabaseAdmin() {
  if (cached) return cached;

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !serviceRoleKey) {
    throw new Error(
      "Supabase is not configured: set NEXT_PUBLIC_SUPABASE_URL (or SUPABASE_URL) and SUPABASE_SERVICE_ROLE_KEY in the environment."
    );
  }

  cached = createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  return cached;
}
