-- whatsapp-koko-chatbot — required table (run after parts 1-4, if used).
-- Assumes user_wallets, coin_transactions, chatbot_password_resets and the
-- award_coins/claim_packet_coins/claim_box_coins/redeem_payout RPCs already
-- exist in this Supabase project (from the main koko-website schema).
-- Idempotent — safe to re-run.

create table if not exists public.whatsapp_chat_state (
  phone text primary key,
  flow_json jsonb,
  session_json jsonb,
  updated_at timestamptz not null default now()
);

comment on table public.whatsapp_chat_state is
  'Per-phone flow/session state for the whatsapp-koko-chatbot auto-reply channel.';

alter table public.whatsapp_chat_state enable row level security;

-- Service-role only — never read/written from a browser.
drop policy if exists "service role only" on public.whatsapp_chat_state;
create policy "service role only" on public.whatsapp_chat_state
  for all using (false) with check (false);
