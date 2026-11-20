Precision Packaging Corner - Multi-Outlet Management System

This version adds the Product Catalogue to the existing Render PostgreSQL login/dashboard foundation.

Deployment: keep the existing Render service environment variables. The existing start command `python init_db.py && gunicorn app:app` remains correct. Push the contents of this folder to the existing GitHub repository's main branch, replacing files with matching names and adding catalogue_seed.csv and templates/products.html and templates/product_form.html.

The startup script uses additive ALTER TABLE statements and inserts catalogue items with ON CONFLICT DO NOTHING. It does not drop tables or erase existing records.

The catalogue is seeded from the workbook sheet `Kikubo Aug 26`, including 114 numbered product entries and the unnumbered Drip bags entry. Workbook `Price` is stored separately as `source_price_ugx`; it is not assumed to be a recovery rate or a selling price. Recovery rate, piece selling price and bulk-pack selling price remain blank until confirmed. Bulk pack quantity defaults to 50 pieces.

This is still an incremental development version. Stock opening balances, receipts, transfers, daily sales, tender reconciliation, approval workflows, audit/security hardening and backups remain to be built and tested before live operation.
