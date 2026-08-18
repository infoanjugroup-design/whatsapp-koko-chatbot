-- koko B2B — Combined schema, PART 2 OF 4 (comments stripped to keep this short)
-- Run all 4 parts IN ORDER in Supabase SQL Editor. Only full-line comments and
-- blank lines were removed from the original migrations to shrink upload size —
-- every actual SQL statement is untouched, so behavior is unchanged. Skip all 4
-- if your Supabase project already has the koko-website schema.

-- Source: 0004_production_management.sql
do $$ begin
  alter type public.user_role add value if not exists 'production_manager';
exception when duplicate_object then null; end $$;
create table if not exists public.app_config (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
insert into public.app_config (key, value) values
  ('production_track_base_url', 'https://kokosnacks.com/track/batch'),
  ('production_box_track_base_url', 'https://kokosnacks.com/track/box'),
  ('production_trace_base_url', 'https://kokosnacks.com/trace'),
  ('whatsapp_bot_number', '910000000000')
on conflict (key) do nothing;
do $$ begin
  create type public.production_batch_status as enum ('planning', 'in_production', 'completed');
exception when duplicate_object then null; end $$;
create table if not exists public.production_batches (
  id uuid primary key default gen_random_uuid(),
  batch_number text not null unique,
  parent_qr_code text unique,
  total_target_packets int not null check (total_target_packets > 0),
  total_boxes_count int not null default 0,
  mfg_date date not null default current_date,
  expiry_date date,
  status public.production_batch_status not null default 'planning',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists production_batches_status_idx on public.production_batches (status);
create index if not exists production_batches_created_at_idx on public.production_batches (created_at desc);
create table if not exists public.production_boxes (
  id uuid primary key default gen_random_uuid(),
  parent_batch_id uuid not null references public.production_batches(id) on delete cascade,
  box_serial_number text not null unique,
  box_id_qr text unique,
  box_coin_qr text unique,
  custom_packet_capacity int not null check (custom_packet_capacity > 0),
  is_coin_claimed boolean not null default false,
  claimed_by_partner_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists production_boxes_batch_idx on public.production_boxes (parent_batch_id);
create index if not exists production_boxes_claimed_idx on public.production_boxes (is_coin_claimed);
create table if not exists public.production_packets (
  id uuid primary key default gen_random_uuid(),
  parent_box_id uuid not null references public.production_boxes(id) on delete cascade,
  parent_batch_id uuid not null references public.production_batches(id) on delete cascade,
  packet_serial_number text not null unique,
  packet_id_qr text unique,
  packet_coin_code text unique,
  packet_coin_qr text unique,
  is_coin_claimed boolean not null default false,
  claimed_by_phone text,
  created_at timestamptz not null default now()
);
create index if not exists production_packets_box_idx on public.production_packets (parent_box_id);
create index if not exists production_packets_batch_idx on public.production_packets (parent_batch_id);
create index if not exists production_packets_claimed_idx on public.production_packets (is_coin_claimed);
create index if not exists production_packets_serial_idx on public.production_packets (packet_serial_number);
create sequence if not exists public.koko_box_seq start 1;
create sequence if not exists public.koko_packet_seq start 1;
create or replace function public.set_batch_qr()
returns trigger language plpgsql as $$
declare
  v_base text;
begin
  if new.id is null then
    new.id := gen_random_uuid();
  end if;
  if new.parent_qr_code is null then
    select value into v_base from public.app_config where key = 'production_track_base_url';
    new.parent_qr_code := coalesce(v_base, 'https://kokosnacks.com/track/batch') || '/' || new.id::text;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_set_batch_qr on public.production_batches;
create trigger trg_set_batch_qr
before insert on public.production_batches
for each row execute function public.set_batch_qr();
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
    new.box_coin_qr := 'https://wa.me/' || coalesce(v_wa_number, '910000000000') || '?text=CLAIMBOX-' || v_serial;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_set_box_fields on public.production_boxes;
create trigger trg_set_box_fields
before insert on public.production_boxes
for each row execute function public.set_box_fields();
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
    new.packet_coin_qr := 'https://wa.me/' || coalesce(v_wa_number, '910000000000') || '?text=CLAIM-' || v_coin_code;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_set_packet_fields on public.production_packets;
create trigger trg_set_packet_fields
before insert on public.production_packets
for each row execute function public.set_packet_fields();
create or replace function public.recalc_batch_boxes_count()
returns trigger language plpgsql as $$
declare
  v_batch_id uuid := coalesce(new.parent_batch_id, old.parent_batch_id);
begin
  update public.production_batches b
  set total_boxes_count = (select count(*) from public.production_boxes where parent_batch_id = v_batch_id),
      status = case when b.status = 'planning' then 'in_production' else b.status end
  where b.id = v_batch_id;
  return coalesce(new, old);
end;
$$;
drop trigger if exists trg_boxes_count on public.production_boxes;
create trigger trg_boxes_count
after insert or delete on public.production_boxes
for each row execute function public.recalc_batch_boxes_count();
create or replace function public.recalc_batch_completion()
returns trigger language plpgsql as $$
declare
  v_batch_id uuid;
begin
  for v_batch_id in select distinct parent_batch_id from new_packets
  loop
    update public.production_batches b
    set status = 'completed'
    where b.id = v_batch_id
      and b.status <> 'completed'
      and (select count(*) from public.production_packets p where p.parent_batch_id = b.id) >= b.total_target_packets;
  end loop;
  return null;
end;
$$;
drop trigger if exists trg_packets_completion on public.production_packets;
create trigger trg_packets_completion
after insert on public.production_packets
referencing new table as new_packets
for each statement execute function public.recalc_batch_completion();
create or replace function public.generate_sequential_packets(p_box_id uuid, p_count int)
returns setof public.production_packets
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch_id uuid;
  v_capacity int;
  v_existing int;
begin
  if not public.is_production_staff() then
    raise exception 'Not authorized to generate packets';
  end if;
  if p_count is null or p_count <= 0 or p_count > 5000 then
    raise exception 'p_count must be between 1 and 5000 per call';
  end if;
  select parent_batch_id, custom_packet_capacity
    into v_batch_id, v_capacity
  from public.production_boxes
  where id = p_box_id;
  if v_batch_id is null then
    raise exception 'Box % not found', p_box_id;
  end if;
  select count(*) into v_existing from public.production_packets where parent_box_id = p_box_id;
  if v_existing + p_count > v_capacity then
    raise exception 'Requested % packets would exceed this box''s capacity of % (already has %)',
      p_count, v_capacity, v_existing;
  end if;
  return query
  insert into public.production_packets (parent_box_id, parent_batch_id)
  select p_box_id, v_batch_id
  from generate_series(1, p_count)
  returning *;
end;
$$;
grant execute on function public.generate_sequential_packets(uuid, int) to authenticated;
create or replace function public.is_production_staff()
returns boolean language sql security definer set search_path = public stable as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'production_manager')
  );
$$;
alter table public.production_batches enable row level security;
alter table public.production_boxes enable row level security;
alter table public.production_packets enable row level security;
alter table public.app_config enable row level security;
drop policy if exists "Production staff manage batches" on public.production_batches;
create policy "Production staff manage batches" on public.production_batches for all
  to authenticated using (public.is_production_staff()) with check (public.is_production_staff());
drop policy if exists "Production staff manage boxes" on public.production_boxes;
create policy "Production staff manage boxes" on public.production_boxes for all
  to authenticated using (public.is_production_staff()) with check (public.is_production_staff());
drop policy if exists "Production staff manage packets" on public.production_packets;
create policy "Production staff manage packets" on public.production_packets for all
  to authenticated using (public.is_production_staff()) with check (public.is_production_staff());
drop policy if exists "Production staff can read app_config" on public.app_config;
create policy "Production staff can read app_config" on public.app_config for select
  to authenticated using (public.is_production_staff());
drop policy if exists "Admins manage app_config" on public.app_config;
create policy "Admins manage app_config" on public.app_config for all
  to authenticated using (public.is_admin()) with check (public.is_admin());
create or replace view public.production_box_stats
with (security_invoker = true) as
select
  b.id as box_id,
  b.parent_batch_id,
  b.box_serial_number,
  b.custom_packet_capacity,
  b.is_coin_claimed as box_coin_claimed,
  count(p.id)::int as packets_generated,
  count(p.id) filter (where p.is_coin_claimed)::int as packets_claimed,
  case when count(p.id) > 0
    then round(100.0 * count(p.id) filter (where p.is_coin_claimed) / count(p.id), 1)
    else 0
  end as claim_percentage
from public.production_boxes b
left join public.production_packets p on p.parent_box_id = b.id
group by b.id;
grant select on public.production_box_stats to authenticated;
create or replace view public.production_batch_stats
with (security_invoker = true) as
select
  bt.id as batch_id,
  bt.batch_number,
  bt.status,
  bt.total_target_packets,
  bt.total_boxes_count,
  count(distinct bx.id)::int as boxes_generated,
  count(p.id)::int as packets_generated,
  count(p.id) filter (where p.is_coin_claimed)::int as packets_claimed,
  case when count(p.id) > 0
    then round(100.0 * count(p.id) filter (where p.is_coin_claimed) / count(p.id), 1)
    else 0
  end as claim_percentage
from public.production_batches bt
left join public.production_boxes bx on bx.parent_batch_id = bt.id
left join public.production_packets p on p.parent_batch_id = bt.id
group by bt.id;
grant select on public.production_batch_stats to authenticated;
create or replace function public.trace_packet(p_serial text)
returns table (
  packet_serial_number text,
  is_coin_claimed boolean,
  box_serial_number text,
  batch_number text,
  mfg_date date,
  expiry_date date
)
language sql security definer set search_path = public stable as $$
  select
    p.packet_serial_number,
    p.is_coin_claimed,
    b.box_serial_number,
    bt.batch_number,
    bt.mfg_date,
    bt.expiry_date
  from public.production_packets p
  join public.production_boxes b on b.id = p.parent_box_id
  join public.production_batches bt on bt.id = p.parent_batch_id
  where p.packet_serial_number = p_serial
  limit 1;
$$;
grant execute on function public.trace_packet(text) to anon, authenticated;
create or replace function public.track_batch(p_batch_id uuid)
returns table (
  batch_number text,
  status public.production_batch_status,
  mfg_date date,
  expiry_date date,
  total_target_packets int,
  total_boxes_count int
)
language sql security definer set search_path = public stable as $$
  select batch_number, status, mfg_date, expiry_date, total_target_packets, total_boxes_count
  from public.production_batches
  where id = p_batch_id
  limit 1;
$$;
grant execute on function public.track_batch(uuid) to anon, authenticated;
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'production_packets'
  ) then
    alter publication supabase_realtime add table public.production_packets;
  end if;
end $$;
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'production_boxes'
  ) then
    alter publication supabase_realtime add table public.production_boxes;
  end if;
end $$;
commit;

-- Source: 0005_production_forecast.sql
create table if not exists public.raw_inventory (
  id uuid primary key default gen_random_uuid(),
  item_name text unique not null,
  category text not null check (category in ('corn', 'spice', 'oil', 'packaging', 'freshener')),
  current_stock_qty numeric not null default 0 check (current_stock_qty >= 0),
  unit text not null, -- 'kg' | 'units' | 'liters'
  reorder_level numeric not null default 50,
  unit_cost numeric not null,
  preferred_supplier text,
  lead_time_days int not null default 7,
  updated_at timestamptz not null default now()
);
comment on table public.raw_inventory is
  'Raw-material / packaging stock ledger for Koko Crispy Peri-Peri Popcorn. Matched by item_name against the BOM engine output in lib/production/bom-engine.ts.';
create index if not exists raw_inventory_category_idx on public.raw_inventory (category);
insert into public.raw_inventory (item_name, category, current_stock_qty, unit, reorder_level, unit_cost, preferred_supplier, lead_time_days)
values
  ('Mushroom Corn Kernels', 'corn', 150.0, 'kg', 100.0, 130.0, 'Agro Imports Ltd', 5),
  ('Peri-Peri Master Seasoning', 'spice', 15.0, 'kg', 20.0, 350.0, 'SpiceCraft Hub', 7),
  ('Refined Popping & Butter Oil', 'oil', 25.0, 'kg', 30.0, 220.0, 'PureOils Corp', 3),
  ('Ecolastic Bio Zip-Lock Pouches (35g)', 'packaging', 2500, 'units', 3000, 2.50, 'Ecolastic Bio Ltd', 10),
  ('Biodegradable Finger Sleeves', 'packaging', 2500, 'units', 3000, 0.40, 'Ecolastic Bio Ltd', 10),
  ('Gud Gum Natural Fresheners', 'freshener', 500, 'units', 1000, 4.00, 'Gud Gum India', 7)
on conflict (item_name) do nothing;
create or replace function public.touch_raw_inventory_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists trg_touch_raw_inventory on public.raw_inventory;
create trigger trg_touch_raw_inventory
before update on public.raw_inventory
for each row execute function public.touch_raw_inventory_updated_at();
create table if not exists public.b2b_pipeline_inquiries (
  id uuid primary key default gen_random_uuid(),
  company_name text not null,
  contact_person text,
  phone text,
  email text,
  estimated_packets int not null check (estimated_packets > 0),
  stage text not null default 'new' check (stage in ('new', 'qualified', 'negotiating', 'won', 'lost')),
  conversion_probability numeric check (conversion_probability is null or (conversion_probability >= 0 and conversion_probability <= 1)),
  expected_close_date date,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.b2b_pipeline_inquiries is
  'Open B2B/corporate-kit inquiries feeding the forecast engine. Rows with stage=won should be converted into a real orders row; stage=lost/won are excluded from pipeline projections.';
create index if not exists b2b_pipeline_stage_idx on public.b2b_pipeline_inquiries (stage);
drop trigger if exists trg_touch_pipeline_inquiries on public.b2b_pipeline_inquiries;
create trigger trg_touch_pipeline_inquiries
before update on public.b2b_pipeline_inquiries
for each row execute function public.touch_raw_inventory_updated_at();
insert into public.b2b_pipeline_inquiries (company_name, contact_person, phone, estimated_packets, stage, expected_close_date, notes)
select * from (values
  ('Zomato Corporate Gifting', 'Priya Sharma', '919812340001', 5000, 'negotiating', (current_date + interval '20 days')::date, 'Diwali corporate hamper — 5000 x 35g pouches'),
  ('Reliance Retail Snack Aisle', 'Arjun Mehta', '919812340002', 12000, 'qualified', (current_date + interval '45 days')::date, 'Pilot listing across 40 stores'),
  ('Indigo Airlines In-flight Snacks', 'Kabir Anand', '919812340003', 8000, 'new', (current_date + interval '60 days')::date, 'Awaiting sample approval')
) as seed(company_name, contact_person, phone, estimated_packets, stage, expected_close_date, notes)
where not exists (select 1 from public.b2b_pipeline_inquiries);
create or replace function public.is_forecast_staff()
returns boolean language sql security definer set search_path = public stable as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'manager', 'production_manager')
  );
$$;
alter table public.raw_inventory enable row level security;
alter table public.b2b_pipeline_inquiries enable row level security;
drop policy if exists "Forecast staff manage raw inventory" on public.raw_inventory;
create policy "Forecast staff manage raw inventory" on public.raw_inventory for all
  to authenticated using (public.is_forecast_staff()) with check (public.is_forecast_staff());
drop policy if exists "Forecast staff manage pipeline inquiries" on public.b2b_pipeline_inquiries;
create policy "Forecast staff manage pipeline inquiries" on public.b2b_pipeline_inquiries for all
  to authenticated using (public.is_forecast_staff()) with check (public.is_forecast_staff());
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'raw_inventory'
  ) then
    alter publication supabase_realtime add table public.raw_inventory;
  end if;
end $$;
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'b2b_pipeline_inquiries'
  ) then
    alter publication supabase_realtime add table public.b2b_pipeline_inquiries;
  end if;
end $$;
commit;
