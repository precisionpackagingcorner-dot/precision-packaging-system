
import os
import csv
from pathlib import Path

import psycopg2
from werkzeug.security import generate_password_hash

DATABASE_URL = os.environ.get("DATABASE_URL")

if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL is required.")

base = Path(__file__).resolve().parent
schema_file = base / "schema.sql"

if not schema_file.exists():
    raise RuntimeError("schema.sql was not found.")

schema_sql = schema_file.read_text(encoding="utf-8")

with psycopg2.connect(DATABASE_URL) as conn:

    # Create the existing database schema.
    with conn.cursor() as cur:
        cur.execute(schema_sql)

        # Safely add catalogue source fields.
        cur.execute("""
            ALTER TABLE public.products
            ADD COLUMN IF NOT EXISTS source_item_number integer,
            ADD COLUMN IF NOT EXISTS source_price_ugx numeric(14,2),
            ADD COLUMN IF NOT EXISTS source_price_label text,
            ADD COLUMN IF NOT EXISTS source_sheet text,
            ADD COLUMN IF NOT EXISTS source_description text
        """)

    # Create the owner account if it does not already exist.
    owner_email = os.environ.get("OWNER_EMAIL", "").strip().lower()
    owner_password = os.environ.get("OWNER_PASSWORD", "")
    owner_name = os.environ.get(
        "OWNER_FULL_NAME", "System Owner"
    ).strip()

    if owner_email and owner_password:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO public.app_users
                (email, password_hash, full_name, role, outlet_id, active)
                VALUES (%s, %s, %s, 'owner_admin', NULL, true)
                ON CONFLICT (email) DO NOTHING
            """, (
                owner_email,
                generate_password_hash(owner_password),
                owner_name
            ))

    # Import the product catalogue.
    seed_path = base / "catalogue_seed.csv"

    if seed_path.exists():

        with seed_path.open(
            newline="",
            encoding="utf-8-sig"
        ) as csv_file:

            reader = csv.DictReader(csv_file)

            required_columns = {
                "sku",
                "product_name",
                "category",
                "source_item_number",
                "source_price_ugx",
                "source_price_label",
                "source_sheet",
                "source_description"
            }

            if not required_columns.issubset(set(reader.fieldnames or [])):
                raise RuntimeError(
                    "catalogue_seed.csv is missing required columns."
                )

            with conn.cursor() as cur:

                for item in reader:

                    raw_item_no = (
                        item.get("source_item_number") or ""
                    ).strip()

                    item_no = (
                        int(float(raw_item_no))
                        if raw_item_no else None
                    )

                    raw_price = (
                        item.get("source_price_ugx") or ""
                    ).strip()

                    price = raw_price if raw_price else None

                    cur.execute("""
                        INSERT INTO public.products
                        (
                            sku,
                            product_name,
                            category,
                            source_item_number,
                            source_price_ugx,
                            source_price_label,
                            source_sheet,
                            source_description
                        )
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                        ON CONFLICT (sku) DO NOTHING
                    """, (
                        item["sku"],
                        item["product_name"],
                        item["category"],
                        item_no,
                        price,
                        item.get("source_price_label") or None,
                        item["source_sheet"],
                        item["source_description"]
                    ))

        print("Product catalogue import checked.")
    else:
        print("Catalogue seed file not found; import skipped.")

print("Database schema and initialisation completed.")

