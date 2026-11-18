CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$ BEGIN
  CREATE TYPE public.user_role AS ENUM ('owner_admin','outlet_attendant');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.transaction_status AS ENUM ('draft','submitted','approved','rejected','voided');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.stock_movement_type AS ENUM
  ('opening_balance','receipt','transfer_out','transfer_in','sale','return_in','damage','adjustment_in','adjustment_out');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS public.outlets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text UNIQUE NOT NULL,
  name text UNIQUE NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.outlets(code,name) VALUES
 ('KIK','Kikubo'),('NAB','Nabweru'),('MBR','Mbra')
ON CONFLICT (code) DO NOTHING;

-- Render PostgreSQL has no Supabase auth.users table. This table replaces it.
CREATE TABLE IF NOT EXISTS public.app_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text UNIQUE NOT NULL,
  password_hash text NOT NULL,
  full_name text NOT NULL,
  role public.user_role NOT NULL DEFAULT 'outlet_attendant',
  outlet_id uuid REFERENCES public.outlets(id),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT attendant_must_have_outlet CHECK (role <> 'outlet_attendant' OR outlet_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sku text UNIQUE NOT NULL,
  product_name text NOT NULL,
  category text NOT NULL,
  colour text,
  size_label text,
  size_grams integer,
  valve_configuration text NOT NULL DEFAULT 'not_applicable',
  recovery_rate_ugx numeric(14,2) CHECK (recovery_rate_ugx IS NULL OR recovery_rate_ugx >= 0),
  piece_selling_price_ugx numeric(14,2) CHECK (piece_selling_price_ugx IS NULL OR piece_selling_price_ugx >= 0),
  bulk_pack_size integer NOT NULL DEFAULT 50 CHECK (bulk_pack_size > 0),
  bulk_pack_price_ugx numeric(14,2) CHECK (bulk_pack_price_ugx IS NULL OR bulk_pack_price_ugx >= 0),
  purchase_cost_ugx numeric(14,2) CHECK (purchase_cost_ugx IS NULL OR purchase_cost_ugx >= 0),
  reorder_level integer NOT NULL DEFAULT 0 CHECK (reorder_level >= 0),
  active boolean NOT NULL DEFAULT true,
  source_description text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS products_analytics_idx
ON public.products(category,colour,size_grams,valve_configuration);

CREATE TABLE IF NOT EXISTS public.stock_locations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  location_code text UNIQUE NOT NULL,
  location_name text NOT NULL,
  location_type text NOT NULL CHECK (location_type IN ('central_store','outlet')),
  outlet_id uuid UNIQUE REFERENCES public.outlets(id),
  active boolean NOT NULL DEFAULT true,
  CHECK ((location_type = 'outlet' AND outlet_id IS NOT NULL) OR
         (location_type = 'central_store' AND outlet_id IS NULL))
);

INSERT INTO public.stock_locations(location_code,location_name,location_type,outlet_id)
SELECT o.code,o.name,'outlet',o.id FROM public.outlets o
ON CONFLICT (location_code) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.stock_balances (
  location_id uuid NOT NULL REFERENCES public.stock_locations(id),
  product_id uuid NOT NULL REFERENCES public.products(id),
  quantity_on_hand integer NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(location_id,product_id)
);

CREATE TABLE IF NOT EXISTS public.stock_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  location_id uuid NOT NULL REFERENCES public.stock_locations(id),
  product_id uuid NOT NULL REFERENCES public.products(id),
  movement_type public.stock_movement_type NOT NULL,
  source_type text CHECK (source_type IN ('central_store','supplier_direct','outlet_transfer','opening_balance','other')),
  supplier_name text,
  quantity integer NOT NULL CHECK (quantity > 0),
  unit_cost_ugx numeric(14,2),
  reference text,
  related_movement_id uuid REFERENCES public.stock_movements(id),
  notes text,
  status public.transaction_status NOT NULL DEFAULT 'submitted',
  created_by uuid REFERENCES public.app_users(id),
  approved_by uuid REFERENCES public.app_users(id),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS stock_movements_period_idx ON public.stock_movements(location_id,occurred_at);
CREATE INDEX IF NOT EXISTS stock_movements_product_idx ON public.stock_movements(product_id,occurred_at);

CREATE TABLE IF NOT EXISTS public.daily_sales_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id uuid NOT NULL REFERENCES public.outlets(id),
  business_date date NOT NULL,
  status public.transaction_status NOT NULL DEFAULT 'draft',
  submitted_by uuid REFERENCES public.app_users(id),
  submitted_at timestamptz,
  approved_by uuid REFERENCES public.app_users(id),
  approved_at timestamptz,
  notes text,
  device_submission_id text UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(outlet_id,business_date)
);

CREATE TABLE IF NOT EXISTS public.daily_sales_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id uuid NOT NULL REFERENCES public.daily_sales_reports(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id),
  quantity_sold integer NOT NULL CHECK (quantity_sold >= 0),
  bulk_packs_sold integer NOT NULL DEFAULT 0 CHECK (bulk_packs_sold >= 0),
  fixed_piece_price_ugx numeric(14,2) NOT NULL CHECK (fixed_piece_price_ugx >= 0),
  fixed_bulk_pack_price_ugx numeric(14,2) CHECK (fixed_bulk_pack_price_ugx IS NULL OR fixed_bulk_pack_price_ugx >= 0),
  bulk_pack_size integer NOT NULL DEFAULT 50 CHECK (bulk_pack_size > 0),
  total_units_sold integer GENERATED ALWAYS AS (quantity_sold + bulk_packs_sold * bulk_pack_size) STORED,
  line_revenue_ugx numeric(16,2) GENERATED ALWAYS AS
    (quantity_sold * fixed_piece_price_ugx + bulk_packs_sold * COALESCE(fixed_bulk_pack_price_ugx,0)) STORED,
  UNIQUE(report_id,product_id)
);

CREATE TABLE IF NOT EXISTS public.sales_tenders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id uuid NOT NULL REFERENCES public.daily_sales_reports(id) ON DELETE CASCADE,
  tender_type text NOT NULL CHECK (tender_type IN ('cash','mobile_money','bank','other')),
  amount_ugx numeric(16,2) NOT NULL CHECK (amount_ugx >= 0),
  provider_or_reference text,
  notes text
);

CREATE TABLE IF NOT EXISTS public.stock_transfers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_number text UNIQUE NOT NULL,
  from_location_id uuid NOT NULL REFERENCES public.stock_locations(id),
  to_location_id uuid NOT NULL REFERENCES public.stock_locations(id),
  status public.transaction_status NOT NULL DEFAULT 'draft',
  dispatched_by uuid REFERENCES public.app_users(id),
  received_by uuid REFERENCES public.app_users(id),
  dispatched_at timestamptz,
  received_at timestamptz,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (from_location_id <> to_location_id)
);

CREATE TABLE IF NOT EXISTS public.stock_transfer_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id uuid NOT NULL REFERENCES public.stock_transfers(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id),
  quantity_dispatched integer NOT NULL CHECK (quantity_dispatched > 0),
  quantity_received integer CHECK (quantity_received IS NULL OR quantity_received >= 0),
  UNIQUE(transfer_id,product_id)
);

CREATE TABLE IF NOT EXISTS public.audit_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_user_id uuid REFERENCES public.app_users(id),
  action text NOT NULL,
  entity_table text NOT NULL,
  entity_id uuid,
  before_data jsonb,
  after_data jsonb,
  occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.notification_preferences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.app_users(id),
  channel text NOT NULL CHECK (channel IN ('in_app','email','whatsapp')),
  destination text,
  event_key text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  UNIQUE(user_id,channel,event_key)
);

CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.app_users(id),
  outlet_id uuid REFERENCES public.outlets(id),
  channel text NOT NULL,
  event_key text NOT NULL,
  title text NOT NULL,
  message text NOT NULL,
  delivery_status text NOT NULL DEFAULT 'queued',
  provider_reference text,
  created_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz
);

-- Nabweru is one of the three outlets. It can receive/distribute stock AND record sales.
-- No fourth warehouse is created by this schema.
