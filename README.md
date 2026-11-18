# Precision Packaging Corner Management System

This starter uses:
- GitHub for source code
- Render Web Service for the Flask application
- Render PostgreSQL for the database

## Important business structure
The system has three outlets: Kikubo, Nabweru and Mbra. Nabweru is both the main receiving/distribution hub and a selling outlet. It must record its own direct sales, stock balances and payment reconciliation like the other outlets.

Product recovery rates, piece prices and bulk prices are separate configurable fields. Bulk pack size defaults to 50 but is stored per product.

## Render environment variables
Set these in the Render Web Service:
- `DATABASE_URL`: use the **Internal Database URL** from the Render PostgreSQL database, because the web service and database are in the same region.
- `SECRET_KEY`: a long random secret generated privately.
- `OWNER_EMAIL`: initial owner email address.
- `OWNER_PASSWORD`: a strong initial owner password.
- `OWNER_FULL_NAME`: owner's display name.

Never put database URLs, passwords, or SECRET_KEY in GitHub.

## First database initialisation
For the first deployment, temporarily set the Render Web Service **Start Command** to:

`python init_db.py && gunicorn app:app`

This runs the idempotent schema setup before starting the web app. After the first successful initialisation, you may leave it in place; the schema uses `IF NOT EXISTS` and safe enum creation. Keep OWNER_EMAIL and OWNER_PASSWORD set only until the owner account has been created, then remove OWNER_PASSWORD from Render environment variables and redeploy.

## Current scope and production caution
This is a connection and database foundation. It provides login and a basic dashboard, but it is NOT yet the completed inventory/sales application. Product catalogue, opening stock import, stock receipts, transfers, sales entry, cash/mobile-money reconciliation, approvals, audit workflows and role/outlet restrictions must be implemented and tested before operational use.

Before real business data is entered, implement proper server-side authorization for every operation, CSRF protection, secure session settings, database backups, and transactional stock/sales functions. Do not expose database credentials to the browser or commit them to GitHub.
