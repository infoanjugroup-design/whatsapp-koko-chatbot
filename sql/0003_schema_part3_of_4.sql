-- koko B2B — Combined schema, PART 3 OF 4 (comments stripped to keep this short)
-- Run all 4 parts IN ORDER in Supabase SQL Editor. Only full-line comments and
-- blank lines were removed from the original migrations to shrink upload size —
-- every actual SQL statement is untouched, so behavior is unchanged. Skip all 4
-- if your Supabase project already has the koko-website schema.

-- Source: 0006_product_catalog_wallets.sql
create table if not exists public.product_catalog (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sku text unique not null,
  flavor_profile text not null, -- e.g. "Spicy Peri-Peri", "Cheese Burst"
  retail_price numeric not null check (retail_price >= 0),
  b2b_base_price numeric not null check (b2b_base_price >= 0),
  pack_weight_grams numeric not null default 35.0 check (pack_weight_grams > 0),
  description text,
  ingredients text[] not null default '{}',
  nutritional_info jsonb not null default '{"calories": 140, "protein_g": 3, "fat_g": 6, "carbs_g": 20}'::jsonb,
  image_url text not null,
  is_active boolean not null default true,
  corn_ratio_percent numeric not null default 100.0 check (corn_ratio_percent >= 0),
  spice_ratio_percent numeric not null default 9.0 check (spice_ratio_percent >= 0),
  oil_ratio_percent numeric not null default 16.0 check (oil_ratio_percent >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists product_catalog_active_idx on public.product_catalog (is_active);
create index if not exists product_catalog_sku_idx on public.product_catalog (sku);
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists trg_product_catalog_updated_at on public.product_catalog;
create trigger trg_product_catalog_updated_at
before update on public.product_catalog
for each row execute function public.set_updated_at();
alter table public.product_catalog enable row level security;
drop policy if exists "product_catalog_public_read" on public.product_catalog;
create policy "product_catalog_public_read"
  on public.product_catalog for select
  to anon, authenticated
  using (is_active = true);
drop policy if exists "product_catalog_staff_read_all" on public.product_catalog;
create policy "product_catalog_staff_read_all"
  on public.product_catalog for select
  to authenticated
  using (
    exists (select 1 from public.profiles where id = auth.uid() and role in ('admin', 'manager'))
  );
drop policy if exists "product_catalog_admin_write" on public.product_catalog;
create policy "product_catalog_admin_write"
  on public.product_catalog for all
  to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'))
  with check (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));
create table if not exists public.user_wallets (
  id uuid primary key default gen_random_uuid(),
  phone text unique not null,
  name text,
  coin_balance int not null default 0 check (coin_balance >= 0),
  referral_code text unique not null,
  referred_by text references public.user_wallets(phone) on delete set null,
  is_creator_monetized boolean not null default false,
  total_referrals_count int not null default 0,
  total_packets_scanned int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists user_wallets_phone_idx on public.user_wallets (phone);
create index if not exists user_wallets_referral_code_idx on public.user_wallets (referral_code);
drop trigger if exists trg_user_wallets_updated_at on public.user_wallets;
create trigger trg_user_wallets_updated_at
before update on public.user_wallets
for each row execute function public.set_updated_at();
create or replace function public.generate_referral_code()
returns text language plpgsql as $$
declare
  v_code text;
  v_exists boolean;
begin
  loop
    v_code := 'KOKO-' || upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 6));
    select exists(select 1 from public.user_wallets where referral_code = v_code) into v_exists;
    exit when not v_exists;
  end loop;
  return v_code;
end;
$$;
create or replace function public.set_wallet_referral_code()
returns trigger language plpgsql as $$
begin
  if new.referral_code is null then
    new.referral_code := public.generate_referral_code();
  end if;
  return new;
end;
$$;
drop trigger if exists trg_user_wallets_referral_code on public.user_wallets;
create trigger trg_user_wallets_referral_code
before insert on public.user_wallets
for each row execute function public.set_wallet_referral_code();
alter table public.user_wallets enable row level security;
drop policy if exists "user_wallets_staff_read" on public.user_wallets;
create policy "user_wallets_staff_read"
  on public.user_wallets for select
  to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role in ('admin', 'manager')));
create table if not exists public.coin_transactions (
  id uuid primary key default gen_random_uuid(),
  phone text not null references public.user_wallets(phone) on delete cascade,
  amount int not null,
  type text not null check (type in (
    'welcome_scan', 'instagram_task', 'youtube_task', 'linkedin_task',
    'facebook_task', 'twitter_task', 'referral_bonus', 'b2b_cashback',
    'payout_redeem', 'order_discount'
  )),
  packet_code text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists coin_transactions_phone_idx on public.coin_transactions (phone);
create index if not exists coin_transactions_type_idx on public.coin_transactions (type);
create index if not exists coin_transactions_packet_code_idx on public.coin_transactions (packet_code);
create unique index if not exists coin_transactions_packet_claim_unique
  on public.coin_transactions (packet_code)
  where type = 'welcome_scan' and packet_code is not null;
alter table public.coin_transactions enable row level security;
drop policy if exists "coin_transactions_staff_read" on public.coin_transactions;
create policy "coin_transactions_staff_read"
  on public.coin_transactions for select
  to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role in ('admin', 'manager')));
create table if not exists public.payout_requests (
  id uuid primary key default gen_random_uuid(),
  phone text not null references public.user_wallets(phone) on delete cascade,
  upi_id text not null,
  coins_redeemed int not null default 25000 check (coins_redeemed > 0),
  amount_inr numeric not null default 250.00 check (amount_inr >= 0),
  status text not null check (status in ('pending', 'approved', 'rejected')) default 'pending',
  processed_at timestamptz,
  processed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists payout_requests_phone_idx on public.payout_requests (phone);
create index if not exists payout_requests_status_idx on public.payout_requests (status);
alter table public.payout_requests enable row level security;
drop policy if exists "payout_requests_staff_all" on public.payout_requests;
create policy "payout_requests_staff_all"
  on public.payout_requests for all
  to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role in ('admin', 'manager')))
  with check (exists (select 1 from public.profiles where id = auth.uid() and role in ('admin', 'manager')));
create or replace function public.award_coins(
  p_phone text,
  p_amount int,
  p_type text,
  p_packet_code text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns public.coin_transactions
language plpgsql security definer set search_path = public as $$
declare
  v_txn public.coin_transactions;
begin
  if p_amount = 0 then
    raise exception 'award_coins: amount cannot be zero';
  end if;
  insert into public.coin_transactions (phone, amount, type, packet_code, metadata)
  values (p_phone, p_amount, p_type, p_packet_code, p_metadata)
  returning * into v_txn;
  update public.user_wallets
  set coin_balance = greatest(0, coin_balance + p_amount)
  where phone = p_phone;
  return v_txn;
end;
$$;
grant execute on function public.award_coins(text, int, text, text, jsonb) to service_role;
create or replace function public.claim_packet_coins(
  p_phone text,
  p_coin_code text,
  p_name text default null,
  p_referral_code text default null
)
returns table (
  ok boolean,
  message text,
  coins_awarded int,
  new_balance int
)
language plpgsql security definer set search_path = public as $$
declare
  v_packet public.production_packets;
  v_scan_bonus constant int := 10;
  v_referral_bonus constant int := 25;
  v_referrer_phone text;
  v_wallet public.user_wallets;
begin
  select * into v_packet from public.production_packets where packet_coin_code = p_coin_code for update;
  if not found then
    return query select false, 'Invalid or unrecognized coin code.', 0, 0;
    return;
  end if;
  if v_packet.is_coin_claimed then
    select coin_balance into v_wallet.coin_balance from public.user_wallets where phone = p_phone;
    return query select false, 'This packet has already been claimed.', 0, coalesce(v_wallet.coin_balance, 0);
    return;
  end if;
  if p_referral_code is not null then
    select phone into v_referrer_phone from public.user_wallets where referral_code = p_referral_code;
  end if;
  insert into public.user_wallets (phone, name, referred_by)
  values (p_phone, p_name, v_referrer_phone)
  on conflict (phone) do update set name = coalesce(public.user_wallets.name, excluded.name)
  returning * into v_wallet;
  update public.production_packets
  set is_coin_claimed = true, claimed_by_phone = p_phone
  where id = v_packet.id;
  update public.user_wallets
  set total_packets_scanned = total_packets_scanned + 1
  where phone = p_phone;
  perform public.award_coins(p_phone, v_scan_bonus, 'welcome_scan', p_coin_code,
    jsonb_build_object('batch_id', v_packet.parent_batch_id, 'box_id', v_packet.parent_box_id));
  if v_wallet.referred_by is not null then
    if (select total_packets_scanned from public.user_wallets where phone = p_phone) = 1 then
      perform public.award_coins(v_wallet.referred_by, v_referral_bonus, 'referral_bonus', p_coin_code,
        jsonb_build_object('referred_phone', p_phone));
      update public.user_wallets set total_referrals_count = total_referrals_count + 1
      where phone = v_wallet.referred_by;
    end if;
  end if;
  select coin_balance into v_wallet.coin_balance from public.user_wallets where phone = p_phone;
  return query select true, 'Coins credited successfully.', v_scan_bonus, v_wallet.coin_balance;
end;
$$;
grant execute on function public.claim_packet_coins(text, text, text, text) to service_role;
create or replace function public.claim_box_coins(
  p_phone text,
  p_box_serial text,
  p_name text default null
)
returns table (
  ok boolean,
  message text,
  coins_awarded int,
  new_balance int
)
language plpgsql security definer set search_path = public as $$
declare
  v_box public.production_boxes;
  v_bonus int;
  v_wallet public.user_wallets;
begin
  select * into v_box from public.production_boxes where box_serial_number = p_box_serial for update;
  if not found then
    return query select false, 'Invalid or unrecognized box code.', 0, 0;
    return;
  end if;
  if v_box.is_coin_claimed then
    select coin_balance into v_wallet.coin_balance from public.user_wallets where phone = p_phone;
    return query select false, 'This box has already been claimed.', 0, coalesce(v_wallet.coin_balance, 0);
    return;
  end if;
  v_bonus := v_box.custom_packet_capacity * 5;
  insert into public.user_wallets (phone, name)
  values (p_phone, p_name)
  on conflict (phone) do update set name = coalesce(public.user_wallets.name, excluded.name)
  returning * into v_wallet;
  update public.production_boxes
  set is_coin_claimed = true
  where id = v_box.id;
  perform public.award_coins(p_phone, v_bonus, 'b2b_cashback', p_box_serial,
    jsonb_build_object('box_id', v_box.id, 'capacity', v_box.custom_packet_capacity));
  select coin_balance into v_wallet.coin_balance from public.user_wallets where phone = p_phone;
  return query select true, 'Box cashback credited successfully.', v_bonus, v_wallet.coin_balance;
end;
$$;
grant execute on function public.claim_box_coins(text, text, text) to service_role;
create or replace function public.redeem_payout(
  p_phone text,
  p_upi_id text,
  p_coins int default 25000,
  p_amount_inr numeric default 250.00
)
returns table (ok boolean, message text, request_id uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_balance int;
  v_request_id uuid;
begin
  select coin_balance into v_balance from public.user_wallets where phone = p_phone for update;
  if not found then
    return query select false, 'No wallet found for this number.', null::uuid;
    return;
  end if;
  if v_balance < p_coins then
    return query select false, format('Insufficient balance: you have %s coins, need %s.', v_balance, p_coins), null::uuid;
    return;
  end if;
  insert into public.payout_requests (phone, upi_id, coins_redeemed, amount_inr)
  values (p_phone, p_upi_id, p_coins, p_amount_inr)
  returning id into v_request_id;
  perform public.award_coins(p_phone, -p_coins, 'payout_redeem', null,
    jsonb_build_object('payout_request_id', v_request_id, 'upi_id', p_upi_id));
  return query select true, 'Payout request submitted for review.', v_request_id;
end;
$$;
grant execute on function public.redeem_payout(text, text, int, numeric) to service_role;
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'user_wallets'
  ) then
    alter publication supabase_realtime add table public.user_wallets;
  end if;
end $$;
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'coin_transactions'
  ) then
    alter publication supabase_realtime add table public.coin_transactions;
  end if;
end $$;
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'payout_requests'
  ) then
    alter publication supabase_realtime add table public.payout_requests;
  end if;
end $$;
commit;

-- Source: 0007_fix_handle_new_user.sql
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, company_name, gstin, contact_person, phone)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data ->> 'company_name',
    new.raw_user_meta_data ->> 'gstin',
    new.raw_user_meta_data ->> 'contact_person',
    new.raw_user_meta_data ->> 'phone'
  )
  on conflict (id) do update set
    company_name   = coalesce(public.profiles.company_name, excluded.company_name),
    gstin          = coalesce(public.profiles.gstin, excluded.gstin),
    contact_person = coalesce(public.profiles.contact_person, excluded.contact_person),
    phone          = coalesce(public.profiles.phone, excluded.phone);
  return new;
end;
$$;
drop trigger if exists trg_handle_new_user on auth.users;
create trigger trg_handle_new_user
after insert on auth.users
for each row
execute function public.handle_new_user();
update public.profiles p
set
  company_name   = coalesce(p.company_name, u.raw_user_meta_data ->> 'company_name'),
  gstin          = coalesce(p.gstin, u.raw_user_meta_data ->> 'gstin'),
  contact_person = coalesce(p.contact_person, u.raw_user_meta_data ->> 'contact_person'),
  phone          = coalesce(p.phone, u.raw_user_meta_data ->> 'phone')
from auth.users u
where u.id = p.id
  and (
    p.company_name is null
    or p.gstin is null
    or p.contact_person is null
    or p.phone is null
  )
  and (
    u.raw_user_meta_data ->> 'company_name' is not null
    or u.raw_user_meta_data ->> 'gstin' is not null
    or u.raw_user_meta_data ->> 'contact_person' is not null
    or u.raw_user_meta_data ->> 'phone' is not null
  );
commit;

-- Source: 0008_registration_integrity_and_indexes.sql
create unique index if not exists profiles_gstin_unique_idx
  on public.profiles (upper(gstin))
  where gstin is not null;
create unique index if not exists profiles_phone_unique_idx
  on public.profiles (phone)
  where phone is not null;
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, company_name, gstin, contact_person, phone)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data ->> 'company_name',
    new.raw_user_meta_data ->> 'gstin',
    new.raw_user_meta_data ->> 'contact_person',
    new.raw_user_meta_data ->> 'phone'
  )
  on conflict (id) do update set
    company_name   = coalesce(public.profiles.company_name, excluded.company_name),
    gstin          = coalesce(public.profiles.gstin, excluded.gstin),
    contact_person = coalesce(public.profiles.contact_person, excluded.contact_person),
    phone          = coalesce(public.profiles.phone, excluded.phone);
  return new;
exception
  when unique_violation then
    raise exception 'duplicate_registration: this GSTIN or phone number is already registered';
end;
$$;
drop trigger if exists trg_handle_new_user on auth.users;
create trigger trg_handle_new_user
after insert on auth.users
for each row
execute function public.handle_new_user();
create index if not exists products_is_active_idx on public.products (is_active);
create index if not exists products_category_idx on public.products (category);
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'product_catalog'
  ) then
    alter publication supabase_realtime add table public.product_catalog;
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'employees'
  ) then
    alter publication supabase_realtime add table public.employees;
  end if;
end $$;
commit;

-- Source: 0009_registration_precheck.sql
create or replace function public.check_registration_conflict(p_gstin text, p_phone text)
returns table (gstin_taken boolean, phone_taken boolean)
language sql
security definer
set search_path = public
stable
as $$
  select
    (p_gstin is not null and exists (
      select 1 from public.profiles where upper(gstin) = upper(p_gstin)
    )) as gstin_taken,
    (p_phone is not null and exists (
      select 1 from public.profiles where phone = p_phone
    )) as phone_taken;
$$;
grant execute on function public.check_registration_conflict(text, text) to anon, authenticated;
commit;
