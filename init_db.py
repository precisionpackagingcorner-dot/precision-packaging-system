import os, csv
from pathlib import Path
import psycopg2
from werkzeug.security import generate_password_hash

DATABASE_URL = os.environ.get('DATABASE_URL')
if not DATABASE_URL:
    raise RuntimeError('DATABASE_URL is required.')
base = Path(__file__).resolve().parent
schema_sql = (base / 'schema.sql').read_text(encoding='utf-8')
with psycopg2.connect(DATABASE_URL) as conn:
    with conn.cursor() as cur:
        cur.execute(schema_sql)
        # Safe, additive migration: preserve existing records and tables.
        cur.execute('''ALTER TABLE public.products
            ADD COLUMN IF NOT EXISTS source_item_number integer,
            ADD COLUMN IF NOT EXISTS source_price_ugx numeric(14,2),
            ADD COLUMN IF NOT EXISTS source_price_label text,
            ADD COLUMN IF NOT EXISTS source_sheet text''')
    owner_email = os.environ.get('OWNER_EMAIL', '').strip().lower()
    owner_password = os.environ.get('OWNER_PASSWORD', '')
    owner_name = os.environ.get('OWNER_FULL_NAME', 'System Owner').strip()
    if owner_email and owner_password:
        with conn.cursor() as cur:
            cur.execute('''INSERT INTO public.app_users(email,password_hash,full_name,role,outlet_id,active)
                VALUES (%s,%s,%s,'owner_admin',NULL,true) ON CONFLICT (email) DO NOTHING''',
                (owner_email, generate_password_hash(owner_password), owner_name))
    # Import the source workbook's August 2026 product descriptions once, keyed by stable SKU.
    seed_path = base / 'catalogue_seed.csv'
    if seed_path.exists():
        with seed_path.open(newline='', encoding='utf-8-sig') as f:
            for item in csv.DictReader(f):
               item_no = int(float(item['source_item_number'])) if item['source_item_number'] else None
price = item['source_price_ugx'] or None
                with conn.cursor() as cur:
                    cur.execute('''INSERT INTO public.products
                        (sku,product_name,category,source_item_number,source_price_ugx,
                         source_price_label,source_sheet,source_description)
                        VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
                        ON CONFLICT (sku) DO NOTHING''',
                        (item['sku'],item['product_name'],item['category'],item_no,price,
                         item['source_price_label'] or None,item['source_sheet'],item['source_description']))
print('Database schema and catalogue seed checked.')
