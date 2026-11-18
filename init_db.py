import os
from pathlib import Path
import psycopg2
from werkzeug.security import generate_password_hash

database_url = os.environ.get("DATABASE_URL")
if not database_url:
    raise RuntimeError("DATABASE_URL is required.")

schema_path = Path(__file__).with_name("schema.sql")
schema_sql = schema_path.read_text(encoding="utf-8")

with psycopg2.connect(database_url) as conn:
    with conn.cursor() as cur:
        cur.execute(schema_sql)

    owner_email = os.environ.get("OWNER_EMAIL", "").strip().lower()
    owner_password = os.environ.get("OWNER_PASSWORD", "")
    owner_name = os.environ.get("OWNER_FULL_NAME", "System Owner").strip()

    if owner_email and owner_password:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO public.app_users(email,password_hash,full_name,role,outlet_id,active)
                VALUES (%s,%s,%s,'owner_admin',NULL,true)
                ON CONFLICT (email) DO NOTHING
            """, (owner_email, generate_password_hash(owner_password), owner_name))

print("Database schema initialised.")
if os.environ.get("OWNER_EMAIL") and os.environ.get("OWNER_PASSWORD"):
    print("Owner account checked/created.")
