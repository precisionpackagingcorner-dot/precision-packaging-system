create extension if not exists pgcrypto;

do $$ begin
  create type public.user_role as enum ('owner_admin','outlet_attendant');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.transaction_status as enum ('draft','submitted','approved','rejected','voided');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.stock_movement_type as enum
  ('opening_balance','receipt','transfer_out','transfer_in','sale','return_in','damage','adjustment_in','adjustment_out');
exception when duplicate_object then null; end $$;

create table if not exists public.outlets (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text unique not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.outlets(code,name) values
 ('KIK','Kikubo'),('NAB','Nabweru'),('MBR','Mbra')
on conflict (code) do nothing;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role public.user_role not null,
  outlet_id uuid references public.outlets(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint attendant_must_have_outlet check (role <> 'outlet_attendant' or outlet_id is not null)
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  sku text unique not null,
  product_name text not null,
  category text not null,
  colour text,
  size_label text,
  size_grams integer,
  valve_configuration text not null default 'not_applicable',
  recovery_rate_ugx numeric(14,2) check (recovery_rate_ugx is null or recovery_rate_ugx >= 0),
  piece_selling_price_ugx numeric(14,2) check (piece_selling_price_ugx is null or piece_selling_price_ugx >= 0),
  bulk_pack_size integer not null default 50 check (bulk_pack_size > 0),
  bulk_pack_price_ugx numeric(14,2) check (bulk_pack_price_ugx is null or bulk_pack_price_ugx >= 0),
  purchase_cost_ugx numeric(14,2) check (purchase_cost_ugx is null or purchase_cost_ugx >= 0),
  reorder_level integer not null default 0 check (reorder_level >= 0),
  active boolean not null default true,
  source_description text,
  created_at timestamptz not null default now()
);

create index if not exists products_analytics_idx
on public.products(category,colour,size_grams,valve_configuration);

create table if not exists public.stock_locations (
  id uuid primary key default gen_random_uuid(),
  location_code text unique not null,
  location_name text not null,
  location_type text not null check (location_type in ('central_store','outlet')),
  outlet_id uuid unique references public.outlets(id),
  active boolean not null default true,
  check ((location_type = 'outlet' and outlet_id is not null) or
         (location_type = 'central_store' and outlet_id is null))
);

insert into public.stock_locations(location_code,location_name,location_type,outlet_id)
select o.code,o.name,'outlet',o.id from public.outlets o
on conflict (location_code) do nothing;

create table if not exists public.stock_balances (
  location_id uuid not null references public.stock_locations(id),
  product_id uuid not null references public.products(id),
  quantity_on_hand integer not null default 0 check (quantity_on_hand >= 0),
  updated_at timestamptz not null default now(),
  primary key(location_id,product_id)
);

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.stock_locations(id),
  product_id uuid not null references public.products(id),
  movement_type public.stock_movement_type not null,
  source_type text check (source_type in ('central_store','supplier_direct','outlet_transfer','opening_balance','other')),
  supplier_name text,
  quantity integer not null check (quantity > 0),
  unit_cost_ugx numeric(14,2),
  reference text,
  related_movement_id uuid references public.stock_movements(id),
  notes text,
  status public.transaction_status not null default 'submitted',
  created_by uuid references public.profiles(user_id),
  approved_by uuid references public.profiles(user_id),
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists stock_movements_period_idx on public.stock_movements(location_id,occurred_at);
create index if not exists stock_movements_product_idx on public.stock_movements(product_id,occurred_at);

create table if not exists public.daily_sales_reports (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id),
  business_date date not null,
  status public.transaction_status not null default 'draft',
  submitted_by uuid references public.profiles(user_id),
  submitted_at timestamptz,
  approved_by uuid references public.profiles(user_id),
  approved_at timestamptz,
  notes text,
  device_submission_id text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(outlet_id,business_date)
);

create table if not exists public.daily_sales_lines (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.daily_sales_reports(id) on delete cascade,
  product_id uuid not null references public.products(id),
  quantity_sold integer not null check (quantity_sold >= 0),
  bulk_packs_sold integer not null default 0 check (bulk_packs_sold >= 0),
  fixed_piece_price_ugx numeric(14,2) not null check (fixed_piece_price_ugx >= 0),
  fixed_bulk_pack_price_ugx numeric(14,2) check (fixed_bulk_pack_price_ugx is null or fixed_bulk_pack_price_ugx >= 0),
  bulk_pack_size integer not null default 50 check (bulk_pack_size > 0),
  total_units_sold integer generated always as (quantity_sold + bulk_packs_sold * bulk_pack_size) stored,
  line_revenue_ugx numeric(16,2) generated always as
    (quantity_sold * fixed_piece_price_ugx + bulk_packs_sold * coalesce(fixed_bulk_pack_price_ugx,0)) stored,
  unique(report_id,product_id)
);

create table if not exists public.sales_tenders (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.daily_sales_reports(id) on delete cascade,
  tender_type text not null check (tender_type in ('cash','mobile_money','bank','other')),
  amount_ugx numeric(16,2) not null check (amount_ugx >= 0),
  provider_or_reference text,
  notes text
);

create table if not exists public.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  transfer_number text unique not null,
  from_location_id uuid not null references public.stock_locations(id),
  to_location_id uuid not null references public.stock_locations(id),
  status public.transaction_status not null default 'draft',
  dispatched_by uuid references public.profiles(user_id),
  received_by uuid references public.profiles(user_id),
  dispatched_at timestamptz,
  received_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  check (from_location_id <> to_location_id)
);

create table if not exists public.stock_transfer_lines (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.stock_transfers(id) on delete cascade,
  product_id uuid not null references public.products(id),
  quantity_dispatched integer not null check (quantity_dispatched > 0),
  quantity_received integer check (quantity_received is null or quantity_received >= 0),
  unique(transfer_id,product_id)
);

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  actor_user_id uuid references public.profiles(user_id),
  action text not null,
  entity_table text not null,
  entity_id uuid,
  before_data jsonb,
  after_data jsonb,
  occurred_at timestamptz not null default now()
);

create table if not exists public.notification_preferences (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(user_id),
  channel text not null check (channel in ('in_app','email','whatsapp')),
  destination text,
  event_key text not null,
  enabled boolean not null default true,
  unique(user_id,channel,event_key)
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(user_id),
  outlet_id uuid references public.outlets(id),
  channel text not null,
  event_key text not null,
  title text not null,
  message text not null,
  delivery_status text not null default 'queued',
  provider_reference text,
  created_at timestamptz not null default now(),
  delivered_at timestamptz
);

-- RLS is intentionally enabled only after the app's access policies and trusted
-- transaction functions have been reviewed. Do not expose the service-role key
-- to browsers. The first deployment uses server-side access only.
