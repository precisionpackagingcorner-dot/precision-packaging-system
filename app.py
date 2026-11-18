import os
from functools import wraps
from flask import Flask, render_template, request, redirect, url_for, session, flash
from supabase import create_client, Client

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "change-this-before-deployment")

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

supabase: Client | None = None
auth_client: Client | None = None

if SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY:
    supabase = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
if SUPABASE_URL and SUPABASE_ANON_KEY:
    auth_client = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("user_id"):
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return wrapped


@app.context_processor
def inject_globals():
    return {"current_user": session.get("full_name"), "current_role": session.get("role")}


@app.route("/")
def index():
    return redirect(url_for("dashboard") if session.get("user_id") else url_for("login"))


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if not auth_client or not supabase:
            flash("The application is not connected to Supabase yet. Add the required environment variables in Render.", "error")
            return render_template("login.html")
        email = request.form.get("email", "").strip()
        password = request.form.get("password", "")
        try:
            result = auth_client.auth.sign_in_with_password({"email": email, "password": password})
            user = result.user
            if not user:
                raise ValueError("Login was not successful.")
            profile = supabase.table("profiles").select("full_name, role, outlet_id, active").eq("user_id", user.id).single().execute().data
            if not profile or not profile.get("active", True):
                auth_client.auth.sign_out()
                raise ValueError("Your user profile is inactive or has not been configured.")
            session.clear()
            session["user_id"] = str(user.id)
            session["full_name"] = profile["full_name"]
            session["role"] = profile["role"]
            session["outlet_id"] = profile.get("outlet_id")
            session["access_token"] = result.session.access_token
            return redirect(url_for("dashboard"))
        except Exception as exc:
            flash(f"Unable to sign in: {str(exc)}", "error")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/dashboard")
@login_required
def dashboard():
    totals = {"products": 0, "outlets": 0, "stock_units": 0}
    recent_movements = []
    connection_message = "Connected to Supabase" if supabase else "Supabase connection not configured"
    if supabase:
        try:
            totals["products"] = supabase.table("products").select("id", count="exact").eq("active", True).execute().count or 0
            totals["outlets"] = supabase.table("outlets").select("id", count="exact").eq("active", True).execute().count or 0
            rows = supabase.table("stock_balances").select("quantity_on_hand").execute().data or []
            totals["stock_units"] = sum(int(row.get("quantity_on_hand") or 0) for row in rows)
            recent_movements = (supabase.table("stock_movements")
                .select("movement_type, quantity, occurred_at, status, products(product_name), stock_locations(location_name)")
                .order("occurred_at", desc=True).limit(8).execute().data or [])
        except Exception as exc:
            connection_message = f"Database setup incomplete: {exc}"
    return render_template("dashboard.html", totals=totals, recent_movements=recent_movements,
                           connection_message=connection_message)


@app.route("/health")
def health():
    return {"status": "ok", "application": "Precision Packaging Corner"}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)), debug=False)
