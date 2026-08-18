-- koko B2B — Combined schema, PART 4 OF 4 (comments stripped to keep this short)
-- Run all 4 parts IN ORDER in Supabase SQL Editor. Only full-line comments and
-- blank lines were removed from the original migrations to shrink upload size —
-- every actual SQL statement is untouched, so behavior is unchanged. Skip all 4
-- if your Supabase project already has the koko-website schema.

-- Source: 0010_catalog_images_tiers_coins.sql
alter table public.product_catalog
  add column if not exists images text[] not null default '{}';
alter table public.product_catalog
  add column if not exists tiers jsonb not null default '[]'::jsonb;
alter table public.product_catalog
  add column if not exists coins_per_unit int not null default 10 check (coins_per_unit >= 0);
update public.product_catalog
set images = array[image_url]
where images = '{}' and image_url is not null and image_url <> '';
comment on column public.product_catalog.images is 'Multiple product photos. images[1] (or image_url if empty) is the cover image.';
comment on column public.product_catalog.tiers is 'Optional bulk pricing breaks: [{"min":1,"max":49,"price":..}]. Empty = flat b2b_base_price at any quantity.';
comment on column public.product_catalog.coins_per_unit is 'Coins an end customer earns scanning one packet''s QR code — shown to B2B buyers at purchase time.';
update public.products set is_active = false;
comment on table public.products is 'LEGACY/UNUSED as of migration 0010 — demo raw-materials rows only. The live B2B catalog reads from public.product_catalog instead. Kept for history, not read by the app.';
commit;

-- Source: 0011_chatbot_web_auth.sql
alter table public.user_wallets add column if not exists email text;
alter table public.user_wallets add column if not exists password_hash text;
alter table public.user_wallets add column if not exists is_web_registered boolean not null default false;
create unique index if not exists user_wallets_email_unique_idx
  on public.user_wallets (lower(email))
  where email is not null;
comment on column public.user_wallets.email is 'Only set for users who registered via the website chatbot. Null for WhatsApp-only wallets.';
comment on column public.user_wallets.password_hash is 'bcrypt hash, set only for website-chatbot registrations. WhatsApp-only wallets never have one.';
comment on column public.user_wallets.is_web_registered is 'True once this phone has completed website-chatbot registration (mobile + email + name + password).';
create table if not exists public.chatbot_password_resets (
  id uuid primary key default gen_random_uuid(),
  phone text not null references public.user_wallets(phone) on delete cascade,
  email text not null,
  otp_hash text not null,
  expires_at timestamptz not null,
  used boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists chatbot_password_resets_phone_idx on public.chatbot_password_resets (phone);
create index if not exists chatbot_password_resets_email_idx on public.chatbot_password_resets (lower(email));
alter table public.chatbot_password_resets enable row level security;
alter table public.coin_transactions add column if not exists expires_at timestamptz;
create or replace function public.set_coin_transaction_expiry()
returns trigger language plpgsql as $$
begin
  if new.amount > 0 and new.expires_at is null then
    new.expires_at := new.created_at + interval '365 days';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_coin_transactions_expiry on public.coin_transactions;
create trigger trg_coin_transactions_expiry
before insert on public.coin_transactions
for each row execute function public.set_coin_transaction_expiry();
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions add constraint coin_transactions_type_check check (type in (
  'welcome_scan', 'instagram_task', 'youtube_task', 'linkedin_task',
  'facebook_task', 'twitter_task', 'referral_bonus', 'b2b_cashback',
  'payout_redeem', 'order_discount',
  'coupon_bonus'          -- new customer entered a valid coupon/referral code at web signup
));
commit;

-- Source: 0012_coin_verification_to_website_chatbot.sql
insert into public.app_config (key, value) values
  ('website_chatbot_base_url', 'https://kokofoods.in')
on conflict (key) do nothing;
create or replace function public.set_box_fields()
returns trigger language plpgsql as $$
declare
  v_serial text;
  v_track_base text;
  v_chatbot_base text;
begin
  if new.id is null then
    new.id := gen_random_uuid();
  end if;
  if new.box_serial_number is null then
    v_serial := 'KOKO-BOX-' || lpad(nextval('public.koko_box_seq')::text, 4, '0');
    new.box_serial_number := v_serial;
  else
    v_serial := new.box_serial_number;
  end if;
  select value into v_track_base from public.app_config where key = 'production_box_track_base_url';
  select value into v_chatbot_base from public.app_config where key = 'website_chatbot_base_url';
  if new.box_id_qr is null then
    new.box_id_qr := coalesce(v_track_base, 'https://kokosnacks.com/track/box') || '/' || v_serial;
  end if;
  if new.box_coin_qr is null then
    new.box_coin_qr := coalesce(v_chatbot_base, 'https://kokofoods.in') || '/?claim=CLAIMBOX-' || v_serial;
  end if;
  return new;
end;
$$;
create or replace function public.set_packet_fields()
returns trigger language plpgsql as $$
declare
  v_serial text;
  v_coin_code text;
  v_trace_base text;
  v_chatbot_base text;
begin
  if new.id is null then
    new.id := gen_random_uuid();
  end if;
  if new.packet_serial_number is null then
    v_serial := 'KOKO-PKT-' || lpad(nextval('public.koko_packet_seq')::text, 6, '0');
    new.packet_serial_number := v_serial;
  else
    v_serial := new.packet_serial_number;
  end if;
  select value into v_trace_base from public.app_config where key = 'production_trace_base_url';
  select value into v_chatbot_base from public.app_config where key = 'website_chatbot_base_url';
  if new.packet_id_qr is null then
    new.packet_id_qr := coalesce(v_trace_base, 'https://kokosnacks.com/trace') || '/' || v_serial;
  end if;
  if new.packet_coin_code is null then
    v_coin_code := 'COIN-' || upper(encode(gen_random_bytes(4), 'hex'));
    new.packet_coin_code := v_coin_code;
  else
    v_coin_code := new.packet_coin_code;
  end if;
  if new.packet_coin_qr is null then
    new.packet_coin_qr := coalesce(v_chatbot_base, 'https://kokofoods.in') || '/?claim=CLAIM-' || v_coin_code;
  end if;
  return new;
end;
$$;
do $$
declare
  v_chatbot_base text;
begin
  select value into v_chatbot_base from public.app_config where key = 'website_chatbot_base_url';
  v_chatbot_base := coalesce(v_chatbot_base, 'https://kokofoods.in');
  update public.production_boxes
  set box_coin_qr = v_chatbot_base || '/?claim=CLAIMBOX-' || box_serial_number
  where box_coin_qr like 'https://wa.me/%CLAIMBOX-%';
  update public.production_packets
  set packet_coin_qr = v_chatbot_base || '/?claim=CLAIM-' || packet_coin_code
  where packet_coin_qr like 'https://wa.me/%CLAIM-%';
end $$;
commit;

-- Source: 0013_b2b_coins_automation.sql
alter table public.orders add column if not exists coins_earned int not null default 0;
alter table public.orders add column if not exists coins_awarded boolean not null default false;
comment on column public.orders.coins_earned is 'Total KOKO Coins this order will credit to the customer wallet (sum of line coins_per_unit × qty), snapshotted at checkout.';
comment on column public.orders.coins_awarded is 'Set true once award_b2b_coins_on_payment() has credited the wallet, so a payment retry/webhook replay never double-credits.';
create or replace function public.award_b2b_coins_on_payment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.order_type = 'B2B'
     and new.payment_status = 'paid'
     and (old.payment_status is distinct from 'paid')
     and new.coins_earned > 0
     and not coalesce(new.coins_awarded, false)
     and new.phone is not null and new.phone <> '' then
    insert into public.user_wallets (phone) values (new.phone)
      on conflict (phone) do nothing;
    perform public.award_coins(
      new.phone,
      new.coins_earned,
      'b2b_cashback',
      null,
      jsonb_build_object('order_id', new.id, 'order_number', new.order_number)
    );
    new.coins_awarded := true;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_award_b2b_coins on public.orders;
create trigger trg_award_b2b_coins
before update on public.orders
for each row execute function public.award_b2b_coins_on_payment();
drop policy if exists "user_wallets_self_read" on public.user_wallets;
create policy "user_wallets_self_read"
  on public.user_wallets for select
  to authenticated
  using (phone = (select phone from public.profiles where id = auth.uid()));
drop policy if exists "coin_transactions_self_read" on public.coin_transactions;
create policy "coin_transactions_self_read"
  on public.coin_transactions for select
  to authenticated
  using (phone = (select phone from public.profiles where id = auth.uid()));
commit;

-- Source: 0014_dashboard_aggregates.sql
create or replace function public.get_admin_dashboard_stats()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'kpis', (
      select jsonb_build_object(
        'total_sales', coalesce(sum(total_amount), 0),
        'total_orders', count(*),
        'b2b_value', coalesce(sum(total_amount) filter (where order_type = 'B2B'), 0),
        'b2c_value', coalesce(sum(total_amount) filter (where order_type = 'B2C'), 0),
        'active_production', count(*) filter (where order_status = 'in_production'),
        'pending_dispatch', count(*) filter (where order_status in ('order_placed', 'sample_sent', 'in_production')),
        'delivered_count', count(*) filter (where order_status = 'delivered'),
        'cancelled_count', count(*) filter (where order_status = 'cancelled'),
        'avg_order_value', case when count(*) > 0 then round(sum(total_amount) / count(*), 2) else 0 end,
        'this_month_sales', coalesce(
          sum(total_amount) filter (where date_trunc('month', created_at) = date_trunc('month', now())),
          0
        )
      )
      from public.orders
    ),
    'daily_sales', (
      select coalesce(jsonb_agg(row_to_json(s) order by s.day), '[]'::jsonb)
      from (
        select
          gs::date as day,
          coalesce(count(o.id), 0) as orders_count,
          coalesce(sum(o.total_amount), 0) as revenue
        from generate_series((current_date - interval '13 days')::date, current_date, interval '1 day') gs
        left join public.orders o on date_trunc('day', o.created_at)::date = gs::date
        group by gs
        order by gs
      ) s
    ),
    'status_breakdown', (
      select coalesce(jsonb_agg(row_to_json(x)), '[]'::jsonb)
      from (
        select order_status::text as status, count(*) as count
        from public.orders
        group by order_status
      ) x
    ),
    'type_breakdown', (
      select coalesce(jsonb_agg(row_to_json(x)), '[]'::jsonb)
      from (
        select order_type::text as type, count(*) as count, coalesce(sum(total_amount), 0) as value
        from public.orders
        group by order_type
      ) x
    ),
    'top_products', (
      select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      from (
        select
          item ->> 'name' as name,
          sum(coalesce((item ->> 'qty')::numeric, 0)) as qty,
          sum(coalesce((item ->> 'qty')::numeric, 0) * coalesce((item ->> 'unit_price')::numeric, 0)) as revenue
        from public.orders o, jsonb_array_elements(o.items) as item
        where o.order_status <> 'cancelled'
        group by item ->> 'name'
        order by revenue desc
        limit 5
      ) t
    )
  );
$$;
comment on function public.get_admin_dashboard_stats() is
  'Aggregate stats (KPIs, 14-day trend, status/type breakdown, top products) for the admin Overview dashboard. RLS on orders still applies to the caller.';
grant execute on function public.get_admin_dashboard_stats() to authenticated;
commit;

-- Source: 0015_certificates.sql
create table if not exists public.certificates (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  issuer text,                      -- e.g. "FSSAI", "ISO 22000:2018"
  image_url text not null,          -- certificate scan/photo shown in the grid
  display_order int not null default 0,
  is_active boolean not null default true, -- show/hide on the homepage
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists certificates_active_idx on public.certificates (is_active);
create index if not exists certificates_display_order_idx on public.certificates (display_order);
drop trigger if exists trg_certificates_updated_at on public.certificates;
create trigger trg_certificates_updated_at
before update on public.certificates
for each row execute function public.set_updated_at();
alter table public.certificates enable row level security;
drop policy if exists "certificates_public_read" on public.certificates;
create policy "certificates_public_read"
  on public.certificates for select
  to anon, authenticated
  using (is_active = true);
drop policy if exists "certificates_staff_read_all" on public.certificates;
create policy "certificates_staff_read_all"
  on public.certificates for select
  to authenticated
  using (
    exists (select 1 from public.profiles where id = auth.uid() and role in ('admin', 'manager'))
  );
drop policy if exists "certificates_admin_write" on public.certificates;
create policy "certificates_admin_write"
  on public.certificates for all
  to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'))
  with check (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'certificates'
  ) then
    alter publication supabase_realtime add table public.certificates;
  end if;
end $$;
commit;

-- Source: 0016_payment_proof_ocr.sql
do $$
begin
  if not exists (
    select 1 from pg_enum
    where enumtypid = 'public.payment_status'::regtype
      and enumlabel = 'partially_paid'
  ) then
    alter type public.payment_status add value 'partially_paid';
  end if;
end $$;
alter table public.payments add column if not exists is_partial boolean not null default false;
alter table public.payments add column if not exists partial_percentage numeric;
alter table public.payments add column if not exists proof_file_url text;
alter table public.payments add column if not exists proof_file_name text;
alter table public.payments add column if not exists proof_uploaded_at timestamptz;
alter table public.payments add column if not exists ocr_transaction_id text;
alter table public.payments add column if not exists ocr_extracted_amount numeric;
alter table public.payments add column if not exists ocr_raw_text text;
alter table public.payments add column if not exists ocr_status text not null default 'not_attempted';
alter table public.payments add column if not exists verification_source text not null default 'manual';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'payments_ocr_status_check') then
    alter table public.payments
      add constraint payments_ocr_status_check
      check (ocr_status in ('not_attempted', 'extracted', 'no_match', 'failed'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payments_verification_source_check') then
    alter table public.payments
      add constraint payments_verification_source_check
      check (verification_source in ('manual', 'ocr_auto', 'admin'));
  end if;
end $$;
comment on column public.payments.is_partial is 'True when this row is an advance/partial payment (e.g. 50% before production) rather than the full order amount.';
comment on column public.payments.proof_file_url is 'Path (within the payment-proofs storage bucket) of the buyer-uploaded transfer receipt / screenshot.';
comment on column public.payments.ocr_transaction_id is 'UTR / UPI ref / transaction ID pulled automatically from the uploaded proof via OCR.';
comment on column public.payments.verification_source is 'How gateway_status=success was reached: manual (admin checked bank statement), ocr_auto (OCR match was confident enough to auto-verify), admin (admin overrode after reviewing proof).';
alter table public.invoices add column if not exists is_partial boolean not null default false;
alter table public.invoices add column if not exists advance_percentage numeric;
alter table public.invoices add column if not exists balance_due numeric not null default 0;
comment on column public.invoices.balance_due is 'Remaining amount owed on the order after this invoice (0 for a full-payment invoice).';
create or replace function public.sync_order_payment_status()
returns trigger language plpgsql as $$
begin
  if new.gateway_status = 'success' then
    if new.is_partial then
      update public.orders set payment_status = 'partially_paid'
        where id = new.order_id and payment_status <> 'paid';
    else
      update public.orders set payment_status = 'paid' where id = new.order_id;
    end if;
  elsif new.gateway_status in ('failed', 'cancelled') then
    update public.orders set payment_status = 'pending'
      where id = new.order_id and payment_status <> 'paid';
  end if;
  return new;
end;
$$;
insert into storage.buckets (id, name, public)
values ('payment-proofs', 'payment-proofs', false)
on conflict (id) do nothing;
drop policy if exists "Admins can read payment proofs" on storage.objects;
create policy "Admins can read payment proofs" on storage.objects for select
  to authenticated using (bucket_id = 'payment-proofs' and public.is_admin());
insert into storage.buckets (id, name, public)
values ('invoices', 'invoices', false)
on conflict (id) do nothing;
drop policy if exists "Admins can read invoice pdfs" on storage.objects;
create policy "Admins can read invoice pdfs" on storage.objects for select
  to authenticated using (bucket_id = 'invoices' and public.is_admin());
commit;

-- Source: 0017_invoice_settings.sql
create table if not exists public.invoice_settings (
  id int primary key default 1,
  seller_name text not null default 'KOKO INDUSTRIAL SUPPLIES',
  legal_line text not null default 'A BHABHA Group Company',
  address text not null default '',
  gstin text not null default '',
  hsn_default text not null default '3926',
  bank_account_name text not null default '',
  bank_account_number text not null default '',
  bank_ifsc text not null default '',
  bank_name text not null default '',
  bank_branch text not null default '',
  updated_at timestamptz not null default now(),
  constraint invoice_settings_single_row check (id = 1)
);
comment on table public.invoice_settings is 'Single-row seller + bank details printed on generated invoices. Admin-editable via /admin/settings/invoice.';
insert into public.invoice_settings (id)
values (1)
on conflict (id) do nothing;
drop trigger if exists trg_invoice_settings_updated_at on public.invoice_settings;
create trigger trg_invoice_settings_updated_at
before update on public.invoice_settings
for each row execute function public.set_updated_at();
alter table public.invoice_settings enable row level security;
drop policy if exists "invoice_settings_public_read" on public.invoice_settings;
create policy "invoice_settings_public_read"
  on public.invoice_settings for select
  to anon, authenticated
  using (true);
drop policy if exists "invoice_settings_admin_write" on public.invoice_settings;
create policy "invoice_settings_admin_write"
  on public.invoice_settings for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());
commit;

-- Source: 0018_whatsapp_chat_state.sql
create table if not exists whatsapp_chat_state (
  phone text primary key,
  flow_json jsonb,
  session_json jsonb,
  updated_at timestamptz not null default now()
);
comment on table whatsapp_chat_state is
  'Per-phone flow/session state for the free WhatsApp auto-reply channel (AutoResponder/Tasker). Not related to the Meta Cloud API webhook, which stays stateless.';
alter table whatsapp_chat_state enable row level security;
create policy "service role only" on whatsapp_chat_state
  for all
  using (false)
  with check (false);
commit;

-- Source: 0019_packet_qr_to_whatsapp.sql
insert into public.app_config (key, value) values
  ('whatsapp_bot_number', '917067546744')
on conflict (key) do update set value = excluded.value;
create or replace function public.set_box_fields()
returns trigger language plpgsql as $$
declare
  v_serial text;
  v_track_base text;
  v_wa_number text;
begin
  if new.id is null then
    new.id := gen_random_uuid();
  end if;
  if new.box_serial_number is null then
    v_serial := 'KOKO-BOX-' || lpad(nextval('public.koko_box_seq')::text, 4, '0');
    new.box_serial_number := v_serial;
  else
    v_serial := new.box_serial_number;
  end if;
  select value into v_track_base from public.app_config where key = 'production_box_track_base_url';
  select value into v_wa_number from public.app_config where key = 'whatsapp_bot_number';
  if new.box_id_qr is null then
    new.box_id_qr := coalesce(v_track_base, 'https://kokosnacks.com/track/box') || '/' || v_serial;
  end if;
  if new.box_coin_qr is null then
    new.box_coin_qr := 'https://wa.me/' || coalesce(v_wa_number, '917067546744') || '?text=CLAIMBOX-' || v_serial;
  end if;
  return new;
end;
$$;
create or replace function public.set_packet_fields()
returns trigger language plpgsql as $$
declare
  v_serial text;
  v_coin_code text;
  v_trace_base text;
  v_wa_number text;
begin
  if new.id is null then
    new.id := gen_random_uuid();
  end if;
  if new.packet_serial_number is null then
    v_serial := 'KOKO-PKT-' || lpad(nextval('public.koko_packet_seq')::text, 6, '0');
    new.packet_serial_number := v_serial;
  else
    v_serial := new.packet_serial_number;
  end if;
  select value into v_trace_base from public.app_config where key = 'production_trace_base_url';
  select value into v_wa_number from public.app_config where key = 'whatsapp_bot_number';
  if new.packet_id_qr is null then
    new.packet_id_qr := coalesce(v_trace_base, 'https://kokosnacks.com/trace') || '/' || v_serial;
  end if;
  if new.packet_coin_code is null then
    v_coin_code := 'COIN-' || upper(encode(gen_random_bytes(4), 'hex'));
    new.packet_coin_code := v_coin_code;
  else
    v_coin_code := new.packet_coin_code;
  end if;
  if new.packet_coin_qr is null then
    new.packet_coin_qr := 'https://wa.me/' || coalesce(v_wa_number, '917067546744') || '?text=CLAIM-' || v_coin_code;
  end if;
  return new;
end;
$$;
do $$
declare
  v_wa_number text;
begin
  select value into v_wa_number from public.app_config where key = 'whatsapp_bot_number';
  v_wa_number := coalesce(v_wa_number, '917067546744');
  update public.production_boxes
  set box_coin_qr = 'https://wa.me/' || v_wa_number || '?text=CLAIMBOX-' || box_serial_number
  where box_coin_qr like '%/?claim=CLAIMBOX-%';
  update public.production_packets
  set packet_coin_qr = 'https://wa.me/' || v_wa_number || '?text=CLAIM-' || packet_coin_code
  where packet_coin_qr like '%/?claim=CLAIM-%';
end $$;
commit;
