-- koko B2B — Combined schema, PART 1 OF 4 (comments stripped to keep this short)
-- Run all 4 parts IN ORDER in Supabase SQL Editor. Only full-line comments and
-- blank lines were removed from the original migrations to shrink upload size —
-- every actual SQL statement is untouched, so behavior is unchanged. Skip all 4
-- if your Supabase project already has the koko-website schema.

-- Source: 0001_init.sql
create extension if not exists "pgcrypto"; -- for gen_random_uuid()
create type public.user_role as enum ('b2b_customer', 'admin');
create type public.order_type as enum ('B2C', 'B2B');
create type public.payment_status as enum ('pending', 'paid', 'cod');
create type public.order_status as enum (
  'order_placed',
  'sample_sent',
  'in_production',
  'shipped',
  'out_for_delivery',
  'delivered',
  'cancelled'
);
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role public.user_role not null default 'b2b_customer',
  company_name text,
  gstin text,
  contact_person text,
  phone text,
  is_approved boolean not null default true, -- flip to false + manual admin approval if you want gated onboarding later
  created_at timestamptz not null default now()
);
comment on table public.profiles is 'Extends auth.users with B2B business details and role.';
create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sku text not null unique,
  category text not null,
  icon text default 'Package', -- lucide-react icon name
  tiers jsonb not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
comment on table public.products is 'B2B bulk catalog. tiers.max = null means "and above".';
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text unique, -- auto-filled by trigger below if left null
  created_at timestamptz not null default now(),
  order_type public.order_type not null,
  user_id uuid references public.profiles(id) on delete set null, -- set for logged-in B2B orders, null for guest B2C
  customer_name text not null,
  phone text not null,
  email text,
  company_name text,
  gst_number text,
  items jsonb not null default '[]'::jsonb,
  quantity int not null,           -- total unit count across all line items
  unit_price numeric not null,     -- blended / primary unit price (for simple B2C orders)
  subtotal numeric not null default 0,
  discount_amount numeric not null default 0,
  tax_amount numeric not null default 0,
  total_amount numeric not null,
  payment_status public.payment_status not null default 'pending',
  order_status public.order_status not null default 'order_placed',
  tracking_courier_name text,
  tracking_number text,
  delivery_address text not null,
  city text,
  state text,
  pincode text,
  status_timeline jsonb not null default '[]'::jsonb -- [{ status, timestamp }]
);
create index orders_order_number_idx on public.orders (order_number);
create index orders_phone_idx on public.orders (phone);
create index orders_user_id_idx on public.orders (user_id);
create index orders_order_status_idx on public.orders (order_status);
create index orders_order_type_idx on public.orders (order_type);
create sequence public.koko_order_seq start 1001;
create or replace function public.set_order_number()
returns trigger
language plpgsql
as $$
begin
  if new.order_number is null then
    new.order_number := 'KOKO-' || extract(year from now())::text || '-' || nextval('public.koko_order_seq')::text;
  end if;
  if new.status_timeline is null or new.status_timeline = '[]'::jsonb then
    new.status_timeline := jsonb_build_array(
      jsonb_build_object('status', new.order_status, 'timestamp', now())
    );
  end if;
  return new;
end;
$$;
create trigger trg_set_order_number
before insert on public.orders
for each row
execute function public.set_order_number();
create or replace function public.append_status_timeline()
returns trigger
language plpgsql
as $$
begin
  if new.order_status is distinct from old.order_status then
    new.status_timeline := coalesce(old.status_timeline, '[]'::jsonb) ||
      jsonb_build_object('status', new.order_status, 'timestamp', now());
  end if;
  return new;
end;
$$;
create trigger trg_append_status_timeline
before update on public.orders
for each row
execute function public.append_status_timeline();
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
  on conflict (id) do nothing;
  return new;
end;
$$;
create trigger trg_handle_new_user
after insert on auth.users
for each row
execute function public.handle_new_user();
create or replace function public.track_order(p_order_number text, p_phone text)
returns setof public.orders
language sql
security definer set search_path = public
stable
as $$
  select *
  from public.orders
  where order_number = p_order_number
    and phone = p_phone
  limit 1;
$$;
grant execute on function public.track_order(text, text) to anon, authenticated;
create or replace function public.is_admin()
returns boolean
language sql
security definer set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
create policy "Users can read own profile"
on public.profiles for select
to authenticated
using (id = auth.uid() or public.is_admin());
create policy "Users can update own profile"
on public.profiles for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());
create policy "Admins can update any profile"
on public.profiles for update
to authenticated
using (public.is_admin());
create policy "Authenticated users can read active products"
on public.products for select
to authenticated
using (is_active = true or public.is_admin());
create policy "Admins can insert products"
on public.products for insert
to authenticated
with check (public.is_admin());
create policy "Admins can update products"
on public.products for update
to authenticated
using (public.is_admin());
create policy "Admins can delete products"
on public.products for delete
to authenticated
using (public.is_admin());
create policy "Anyone can place an order"
on public.orders for insert
to anon, authenticated
with check (
  (user_id is null) or (user_id = auth.uid())
);
create policy "Admins can read all orders"
on public.orders for select
to authenticated
using (public.is_admin());
create policy "B2B customers can read their own orders"
on public.orders for select
to authenticated
using (user_id = auth.uid());
create policy "Admins can update orders"
on public.orders for update
to authenticated
using (public.is_admin());
insert into public.products (name, sku, category, icon, tiers) values
('HDPE Granules (Grade 05)', 'HDPE-GR-05', 'Raw Materials', 'Boxes',
  '[{"min":1,"max":49,"price":500},{"min":50,"max":199,"price":420},{"min":200,"max":null,"price":350}]'),
('Galvanized Steel Sheets (4x8 ft)', 'GSS-4X8', 'Raw Materials', 'Layers',
  '[{"min":1,"max":49,"price":1450},{"min":50,"max":199,"price":1290},{"min":200,"max":null,"price":1100}]'),
('Industrial Safety Helmets', 'ISH-STD-01', 'Industrial Supplies', 'HardHat',
  '[{"min":1,"max":49,"price":220},{"min":50,"max":199,"price":185},{"min":200,"max":null,"price":150}]'),
('Heavy-Duty Nitrile Gloves (Box/100)', 'HDNG-BX100', 'Industrial Supplies', 'Hand',
  '[{"min":1,"max":49,"price":340},{"min":50,"max":199,"price":290},{"min":200,"max":null,"price":240}]'),
('Corrugated Shipping Boxes (18x12x12)', 'CSB-181212', 'Packaged Goods', 'Package',
  '[{"min":1,"max":49,"price":65},{"min":50,"max":199,"price":52},{"min":200,"max":null,"price":41}]'),
('PET Preforms (28mm neck)', 'PET-28MM', 'Raw Materials', 'FlaskConical',
  '[{"min":1,"max":49,"price":8},{"min":50,"max":199,"price":6.4},{"min":200,"max":null,"price":5.1}]'),
('Industrial Cable Ties (Pack/500)', 'ICT-PK500', 'Industrial Supplies', 'Plug',
  '[{"min":1,"max":49,"price":410},{"min":50,"max":199,"price":355},{"min":200,"max":null,"price":300}]'),
('Stretch Wrap Film (500mm x 300m)', 'SWF-500-300', 'Packaged Goods', 'Layers',
  '[{"min":1,"max":49,"price":480},{"min":50,"max":199,"price":410},{"min":200,"max":null,"price":350}]');
alter publication supabase_realtime add table public.orders;
commit;

-- Source: 0002_payments.sql
do $$
begin
  if not exists (select 1 from pg_type where typname = 'payment_method') then
    create type public.payment_method as enum ('UPI', 'CARD', 'NETBANKING', 'WALLET', 'COD', 'OTHER');
  end if;
end $$;
do $$
begin
  if not exists (select 1 from pg_type where typname = 'payment_gateway_status') then
    create type public.payment_gateway_status as enum
      ('initiated', 'pending', 'success', 'failed', 'refunded', 'cancelled');
  end if;
end $$;
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  merchant_transaction_id text not null unique, -- generated by us, sent to PhonePe
  phonepe_transaction_id text,                  -- PhonePe's own transactionId (from status check)
  amount numeric not null,                      -- rupees (matches orders.total_amount at time of payment)
  currency text not null default 'INR',
  payment_method public.payment_method,
  gateway_status public.payment_gateway_status not null default 'initiated',
  utr_number text,          -- bank UTR reference, present on success
  response_code text,       -- PhonePe responseCode / status code, e.g. PAYMENT_SUCCESS
  gateway_response jsonb,   -- full raw response from PhonePe (pay + status calls)
  initiated_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.payments is 'PhonePe transaction log — one row per payment attempt on an order.';
create index if not exists payments_order_id_idx on public.payments (order_id);
create index if not exists payments_merchant_txn_idx on public.payments (merchant_transaction_id);
create index if not exists payments_gateway_status_idx on public.payments (gateway_status);
create or replace function public.set_payments_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists trg_payments_updated_at on public.payments;
create trigger trg_payments_updated_at
before update on public.payments
for each row execute function public.set_payments_updated_at();
create or replace function public.sync_order_payment_status()
returns trigger language plpgsql as $$
begin
  if new.gateway_status = 'success' then
    update public.orders set payment_status = 'paid' where id = new.order_id;
  elsif new.gateway_status in ('failed', 'cancelled') then
    update public.orders set payment_status = 'pending'
      where id = new.order_id and payment_status <> 'paid';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_sync_order_payment_status on public.payments;
create trigger trg_sync_order_payment_status
after insert or update on public.payments
for each row execute function public.sync_order_payment_status();
create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_number text unique,
  order_id uuid not null references public.orders(id) on delete cascade,
  payment_id uuid references public.payments(id) on delete set null,
  billing_name text not null,
  billing_address text not null,
  billing_gstin text,
  place_of_supply text,
  taxable_amount numeric not null default 0,
  cgst_amount numeric not null default 0,
  sgst_amount numeric not null default 0,
  igst_amount numeric not null default 0,
  total_tax numeric not null default 0,
  total_amount numeric not null,
  invoice_pdf_url text,
  issued_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
comment on table public.invoices is 'GST billing record per order, linked to the payment that settled it.';
create index if not exists invoices_order_id_idx on public.invoices (order_id);
create index if not exists invoices_invoice_number_idx on public.invoices (invoice_number);
create sequence if not exists public.koko_invoice_seq start 5001;
create or replace function public.set_invoice_number()
returns trigger language plpgsql as $$
begin
  if new.invoice_number is null then
    new.invoice_number := 'INV-' || extract(year from now())::text || '-' || nextval('public.koko_invoice_seq')::text;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_set_invoice_number on public.invoices;
create trigger trg_set_invoice_number
before insert on public.invoices
for each row execute function public.set_invoice_number();
alter table public.payments enable row level security;
alter table public.invoices enable row level security;
drop policy if exists "Admins can read all payments" on public.payments;
create policy "Admins can read all payments" on public.payments for select
  to authenticated using (public.is_admin());
drop policy if exists "Owners can read their own order payments" on public.payments;
create policy "Owners can read their own order payments" on public.payments for select
  to authenticated using (
    exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid())
  );
drop policy if exists "Admins can read all invoices" on public.invoices;
create policy "Admins can read all invoices" on public.invoices for select
  to authenticated using (public.is_admin());
drop policy if exists "Owners can read their own invoices" on public.invoices;
create policy "Owners can read their own invoices" on public.invoices for select
  to authenticated using (
    exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid())
  );
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'payments'
  ) then
    alter publication supabase_realtime add table public.payments;
  end if;
end $$;
commit;

-- Source: 0003_employees_payroll.sql
do $$ begin
  alter type public.user_role add value if not exists 'manager';
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.attendance_status as enum ('present', 'absent', 'half_day', 'leave', 'holiday');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.payout_status as enum ('pending', 'processing', 'success', 'failed', 'on_hold');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.salary_type as enum ('monthly', 'daily', 'hourly');
exception when duplicate_object then null; end $$;
create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles(id) on delete set null, -- login account, if they have portal access
  employee_code text not null unique,
  full_name text not null,
  designation text not null,          -- e.g. 'Manager - Sales', 'Order Executive'
  department text,
  phone text not null,
  email text,
  salary_type public.salary_type not null default 'monthly',
  base_salary numeric not null default 0,   -- monthly CTC, or per-day/hour rate depending on salary_type
  bank_account_number text,
  bank_ifsc text,
  bank_account_holder text,
  upi_id text,                        -- PhonePe payout destination (VPA)
  is_active boolean not null default true,
  joined_at date not null default current_date,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists employees_profile_id_idx on public.employees (profile_id);
create index if not exists employees_is_active_idx on public.employees (is_active);
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists trg_employees_updated_at on public.employees;
create trigger trg_employees_updated_at
before update on public.employees
for each row execute function public.set_updated_at();
create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  work_date date not null,
  status public.attendance_status not null default 'present',
  check_in time,
  check_out time,
  notes text,
  marked_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (employee_id, work_date)
);
create index if not exists attendance_employee_date_idx on public.attendance (employee_id, work_date);
create table if not exists public.performance_reviews (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  period_month int not null check (period_month between 1 and 12),
  period_year int not null,
  rating numeric(3,1) not null check (rating between 0 and 5),
  orders_handled int default 0,
  notes text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (employee_id, period_month, period_year)
);
create table if not exists public.salary_payouts (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  period_month int not null check (period_month between 1 and 12),
  period_year int not null,
  base_salary numeric not null,
  present_days int not null default 0,
  total_working_days int not null default 30,
  performance_rating numeric(3,1),
  performance_bonus numeric not null default 0,
  deductions numeric not null default 0,
  net_amount numeric not null default 0,
  payout_status public.payout_status not null default 'pending',
  payout_method text not null default 'PHONEPE',
  merchant_transaction_id text unique,
  phonepe_transfer_id text,
  utr_number text,
  gateway_response jsonb,
  approved_by uuid references public.profiles(id) on delete set null,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (employee_id, period_month, period_year)
);
create index if not exists salary_payouts_employee_idx on public.salary_payouts (employee_id);
create index if not exists salary_payouts_status_idx on public.salary_payouts (payout_status);
drop trigger if exists trg_salary_payouts_updated_at on public.salary_payouts;
create trigger trg_salary_payouts_updated_at
before update on public.salary_payouts
for each row execute function public.set_updated_at();
create or replace function public.calc_salary_payout()
returns trigger language plpgsql as $$
begin
  if new.net_amount is null or new.net_amount = 0 then
    new.net_amount := round(
      (new.base_salary * new.present_days / nullif(new.total_working_days, 0))
      + coalesce(new.performance_bonus, 0) - coalesce(new.deductions, 0)
    , 2);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_calc_salary_payout on public.salary_payouts;
create trigger trg_calc_salary_payout
before insert or update on public.salary_payouts
for each row execute function public.calc_salary_payout();
create table if not exists public.order_communications (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  employee_id uuid references public.employees(id) on delete set null,
  channel text not null default 'whatsapp',  -- whatsapp / call / email / sms
  message text not null,
  sent_at timestamptz not null default now()
);
create index if not exists order_communications_order_idx on public.order_communications (order_id);
create or replace function public.is_manager()
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('manager', 'admin'));
$$;
create or replace function public.current_employee_id()
returns uuid language sql security definer set search_path = public stable as $$
  select id from public.employees where profile_id = auth.uid() limit 1;
$$;
alter table public.employees enable row level security;
alter table public.attendance enable row level security;
alter table public.performance_reviews enable row level security;
alter table public.salary_payouts enable row level security;
alter table public.order_communications enable row level security;
drop policy if exists "Admins manage employees" on public.employees;
create policy "Admins manage employees" on public.employees for all
  to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "Employee can read own record" on public.employees;
create policy "Employee can read own record" on public.employees for select
  to authenticated using (profile_id = auth.uid());
drop policy if exists "Admins manage attendance" on public.attendance;
create policy "Admins manage attendance" on public.attendance for all
  to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "Managers can read attendance" on public.attendance;
create policy "Managers can read attendance" on public.attendance for select
  to authenticated using (public.is_manager());
drop policy if exists "Managers can mark attendance" on public.attendance;
create policy "Managers can mark attendance" on public.attendance for insert
  to authenticated with check (public.is_manager());
drop policy if exists "Managers can update attendance" on public.attendance;
create policy "Managers can update attendance" on public.attendance for update
  to authenticated using (public.is_manager());
drop policy if exists "Admins manage performance reviews" on public.performance_reviews;
create policy "Admins manage performance reviews" on public.performance_reviews for all
  to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "Employee can read own performance" on public.performance_reviews;
create policy "Employee can read own performance" on public.performance_reviews for select
  to authenticated using (
    exists (select 1 from public.employees e where e.id = employee_id and e.profile_id = auth.uid())
  );
drop policy if exists "Admins manage salary payouts" on public.salary_payouts;
create policy "Admins manage salary payouts" on public.salary_payouts for all
  to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "Employee can read own payouts" on public.salary_payouts;
create policy "Employee can read own payouts" on public.salary_payouts for select
  to authenticated using (
    exists (select 1 from public.employees e where e.id = employee_id and e.profile_id = auth.uid())
  );
drop policy if exists "Admins read all communications" on public.order_communications;
create policy "Admins read all communications" on public.order_communications for select
  to authenticated using (public.is_admin());
drop policy if exists "Managers can read communications" on public.order_communications;
create policy "Managers can read communications" on public.order_communications for select
  to authenticated using (public.is_manager());
drop policy if exists "Managers can log communications" on public.order_communications;
create policy "Managers can log communications" on public.order_communications for insert
  to authenticated with check (public.is_manager());
drop policy if exists "Managers can read all orders" on public.orders;
create policy "Managers can read all orders" on public.orders for select
  to authenticated using (public.is_manager());
drop policy if exists "Managers can update order status and tracking" on public.orders;
create policy "Managers can update order status and tracking" on public.orders for update
  to authenticated using (public.is_manager()) with check (public.is_manager());
create or replace function public.enforce_manager_order_update_scope()
returns trigger language plpgsql as $$
begin
  if public.is_admin() then
    return new;
  end if;
  if public.is_manager() then
    if new.total_amount    is distinct from old.total_amount
      or new.subtotal        is distinct from old.subtotal
      or new.discount_amount is distinct from old.discount_amount
      or new.tax_amount      is distinct from old.tax_amount
      or new.unit_price      is distinct from old.unit_price
      or new.quantity        is distinct from old.quantity
      or new.items           is distinct from old.items
      or new.payment_status  is distinct from old.payment_status
    then
      raise exception 'Managers cannot modify pricing or payment fields on an order';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_enforce_manager_order_update_scope on public.orders;
create trigger trg_enforce_manager_order_update_scope
before update on public.orders
for each row execute function public.enforce_manager_order_update_scope();
commit;
