# Precision Packaging Corner Management System

A web-based, multi-outlet inventory and sales management application for Kikubo, Nabweru and Mbra.

## Technology
- Python / Flask
- Render hosting
- Supabase PostgreSQL and Supabase Auth

## Deployment on Render
Create a **Python** web service (not Docker).

- Build command: `pip install -r requirements.txt`
- Start command: `gunicorn app:app`

Add these environment variables in Render:
- `SECRET_KEY` — a long random secret
- `SUPABASE_URL` — Project URL from Supabase
- `SUPABASE_ANON_KEY` — Supabase anon/public key
- `SUPABASE_SERVICE_ROLE_KEY` — Supabase service-role key; keep this secret and never put it in GitHub

## Database
Review and run `schema.sql` in the Supabase SQL Editor before deploying the application.

## First administrator
Create the administrator through Supabase Authentication, then insert the matching profile row into `public.profiles` with role `owner_admin`. Do not expose the service-role key in browser-side code.

This is the initial application foundation. Stock, transfer, sales, approvals, reporting and product-pricing workflows will be implemented and tested in stages before live use.
