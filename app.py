import os
from functools import wraps
from decimal import Decimal, InvalidOperation
from flask import Flask, render_template, request, redirect, url_for, session, flash
from werkzeug.security import check_password_hash
import psycopg2
from psycopg2.extras import RealDictCursor

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY')
if not app.secret_key:
    raise RuntimeError('Set SECRET_KEY in Render environment variables before starting the app.')
DATABASE_URL = os.environ.get('DATABASE_URL')

def get_db():
    if not DATABASE_URL:
        raise RuntimeError('DATABASE_URL is not configured in Render.')
    return psycopg2.connect(DATABASE_URL, cursor_factory=RealDictCursor)

def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get('user_id'):
            return redirect(url_for('login'))
        return view(*args, **kwargs)
    return wrapped

def optional_money(value, label):
    value = (value or '').strip()
    if not value:
        return None
    try:
        amount = Decimal(value)
        if amount < 0:
            raise InvalidOperation
        return amount
    except (InvalidOperation, ValueError):
        raise ValueError(f'{label} must be a non-negative number or left blank.')

@app.context_processor
def inject_globals():
    return {'current_user': session.get('full_name'), 'current_role': session.get('role')}

@app.route('/')
def index():
    return redirect(url_for('dashboard') if session.get('user_id') else url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        email = request.form.get('email', '').strip().lower()
        password = request.form.get('password', '')
        try:
            with get_db() as conn:
                with conn.cursor() as cur:
                    cur.execute('''SELECT id,email,password_hash,full_name,role,outlet_id,active
                                   FROM public.app_users WHERE lower(email)=%s''', (email,))
                    user = cur.fetchone()
            if not user or not user['active'] or not check_password_hash(user['password_hash'], password):
                flash('Invalid email or password, or the account is inactive.', 'error')
                return render_template('login.html')
            session.clear()
            session['user_id'] = str(user['id'])
            session['email'] = user['email']
            session['full_name'] = user['full_name']
            session['role'] = user['role']
            session['outlet_id'] = str(user['outlet_id']) if user['outlet_id'] else None
            return redirect(url_for('dashboard'))
        except Exception:
            app.logger.exception('Login failed')
            flash('Unable to sign in. Check the database configuration and try again.', 'error')
    return render_template('login.html')

@app.route('/logout', methods=['POST'])
@login_required
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/dashboard')
@login_required
def dashboard():
    totals = {'products': 0, 'outlets': 0, 'stock_units': 0}
    recent_movements = []
    connection_message = 'Connected to Render PostgreSQL'
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute('SELECT count(*) AS n FROM public.products WHERE active=true')
                totals['products'] = cur.fetchone()['n']
                cur.execute('SELECT count(*) AS n FROM public.outlets WHERE active=true')
                totals['outlets'] = cur.fetchone()['n']
                cur.execute('SELECT coalesce(sum(quantity_on_hand),0) AS n FROM public.stock_balances')
                totals['stock_units'] = cur.fetchone()['n']
                cur.execute('''SELECT sm.movement_type,sm.quantity,sm.occurred_at,sm.status,
                               p.product_name,sl.location_name FROM public.stock_movements sm
                               JOIN public.products p ON p.id=sm.product_id
                               JOIN public.stock_locations sl ON sl.id=sm.location_id
                               ORDER BY sm.occurred_at DESC LIMIT 8''')
                recent_movements = cur.fetchall()
    except Exception:
        app.logger.exception('Dashboard database query failed')
        connection_message = 'Database connected, but application tables may not yet be initialised.'
    return render_template('dashboard.html', totals=totals, recent_movements=recent_movements,
                           connection_message=connection_message)

@app.route('/products')
@login_required
def products():
    search = request.args.get('q', '').strip()
    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute('''SELECT id,sku,source_item_number,product_name,category,
                           source_price_ugx,source_price_label,recovery_rate_ugx,
                           piece_selling_price_ugx,bulk_pack_size,bulk_pack_price_ugx,active
                           FROM public.products
                           WHERE (%s='' OR product_name ILIKE %s OR sku ILIKE %s OR category ILIKE %s)
                           ORDER BY category,source_item_number NULLS LAST,product_name''',
                        (search, f'%{search}%', f'%{search}%', f'%{search}%'))
            rows = cur.fetchall()
    return render_template('products.html', products=rows, search=search)

@app.route('/products/new', methods=['GET', 'POST'])
@login_required
def new_product():
    if request.method == 'POST':
        sku = request.form.get('sku', '').strip().upper()
        name = request.form.get('product_name', '').strip()
        category = request.form.get('category', '').strip()
        try:
            if not sku or not name or not category:
                raise ValueError('Product code, product name and category are required.')
            recovery = optional_money(request.form.get('recovery_rate_ugx'), 'Recovery rate')
            piece = optional_money(request.form.get('piece_selling_price_ugx'), 'Piece selling price')
            bulk_price = optional_money(request.form.get('bulk_pack_price_ugx'), 'Bulk-pack selling price')
            pack_size = int(request.form.get('bulk_pack_size') or 50)
            if pack_size < 1:
                raise ValueError('Bulk pack quantity must be at least 1.')
            with get_db() as conn:
                with conn.cursor() as cur:
                    cur.execute('''INSERT INTO public.products
                        (sku,product_name,category,recovery_rate_ugx,piece_selling_price_ugx,
                         bulk_pack_size,bulk_pack_price_ugx,source_description)
                        VALUES (%s,%s,%s,%s,%s,%s,%s,%s)''',
                        (sku,name,category,recovery,piece,pack_size,bulk_price,
                         request.form.get('source_description','').strip() or None))
            flash('Product added to the catalogue.', 'success')
            return redirect(url_for('products'))
        except ValueError as exc:
            flash(str(exc), 'error')
        except psycopg2.errors.UniqueViolation:
            flash('That product code already exists. Use a different code.', 'error')
        except Exception:
            app.logger.exception('Could not add product')
            flash('The product could not be saved. Please check the entries and try again.', 'error')
    return render_template('product_form.html')

@app.route('/health')
def health():
    return {'status': 'ok', 'application': 'Precision Packaging Corner'}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 5000)))
