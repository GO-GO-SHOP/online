# GO GO SHOP Online

An empty, production-ready copy of the GO GO SHOP storefront. It includes the public catalogue, cart, customer accounts, Stripe-hosted checkout, order history, product and inventory administration, vouchers, POS, receipts, PWA support, and Supabase database/Edge Function sources.

No products, supplier invoices, product imports, or product images are included. The initial catalogue is intentionally empty.

## Publish

GitHub Pages is served from the repository's default branch. The public site is:

`https://go-go-shop.github.io/online/`

## Connect the independent backend

1. Create a new Supabase project.
2. Run `supabase-schema.sql`, followed by the feature migrations documented in `SUPABASE_SETUP.md`.
3. Put only the new project's public URL and publishable/anon key in `store-config.js`.
4. Create the first account and promote it to administrator using the SQL in `SUPABASE_SETUP.md`.
5. Deploy the two Stripe Edge Functions and add their secrets in Supabase.

Until step 3 is completed, the public storefront deliberately renders an empty catalogue and cannot read data from the existing `gogoshop.nz` store.
