# Muninn

Muninn runs a small business from the phone keyboard.
You chat with a client as usual. Muninn reads the chat and offers one-tap actions: send an invoice, share a pay link, send a reminder, or refund.
Every money action goes through PayPal.
The app also shows the day at a glance: money in, late invoices, disputes and clients.

## How it works

```
iOS keyboard + iOS app
        │  HTTPS, device token
        ▼
Hono server (Node 24, SQLite, per-user encryption)
        ├── PayPal APIs: Invoicing, Orders, Payments, Transaction Search, Disputes, Webhooks
        ├── Regex first: drops plain chat with no model call, reads amounts, currencies and emails
        ├── TypeSafe jev: sorts the typed message into an intent, and labels tone (upset, blunt, ok)
        └── OpenRouter: Llama 3.3 70B, with Gemini 2.5 Flash as the backup, fills in only the details regex
            cannot read, and writes text (fixes, rewrites, calm replies, the daily brief)
```

- The keyboard sends the typed text to `/v1/suggest`. The server returns chips. It never moves money on its own.
- A tap on a chip calls `/v1/actions/*`. Each action needs a tap header and an idempotency key.
- `/v1/summary`, `/v1/transactions`, `/v1/clients`, `/v1/disputes` and `/v1/brief` power the app home screen.
- PayPal is the only live integration. Stripe, Square, Google Calendar, Gmail and Shopify show as "coming soon".

## Run it locally

You need Node 24 or later and a PayPal sandbox app.

1. Create `.env` in the repo root with these keys:
   `PAYPAL_ENV=sandbox`, `PAYPAL_CLIENT_ID`, `PAYPAL_CLIENT_SECRET`, `OPENROUTER_API_KEY`, `TYPESAFE_API_KEY`.
2. `cd server && npm ci`
3. `npm run setup` adds a `DATA_ENCRYPTION_KEY` to `.env`. It never prints the key.
4. `npm run seed:demo` creates the demo business with real sandbox invoices. It writes the demo device token to `server/data/demo-device.json`.
5. `npm run dev` starts the server on port 8787.
6. `npm test` runs the tests. `npm run e2e` runs one live pass against the sandbox.

Run `npm run seed:demo -- --refresh-today` on a demo day. It adds today's paid invoices.

## For judges

- Server: `<hosted URL, added by the owner>`
- Demo device token: the owner shares it with you. It never goes in this repo.
- PayPal sandbox logins: `<added by the owner>`

Try it:

```
curl -H "Authorization: Bearer <token>" <hosted URL>/v1/brief
curl -H "Authorization: Bearer <token>" <hosted URL>/v1/summary
curl -H "Authorization: Bearer <token>" <hosted URL>/v1/clients
```

The demo is "Rae Okafor Hair & Design", a stylist who also designs brands.
Its invoices are real PayPal sandbox invoices.
The paid ones use PayPal's "record payment" API, so they show as `paid_via: recorded_payment`. No buyer paid them.

## Deploy

`render.yaml` describes one Render web service with a 1 GB disk for SQLite.
Render asks for each secret in its dashboard.
With `DEMO_SEED=1`, the first boot seeds the demo and prints the demo token once in the logs.

## Built with

- PayPal REST APIs and the PayPal Agent Toolkit
- TypeSafe jev
- OpenRouter (Llama 3.3 70B on Groq, Gemini 2.5 Flash)
- Hono, zod, Node.js built-in SQLite
- Swift and SwiftUI

## Security

- Client names and emails are encrypted with AES-256-GCM. Each user has their own key.
- Device tokens are stored as hashes.
- Every query filters by the user from the token. Another user's ids return 404.
- Money actions need a tap and an idempotency key. A refund takes two steps.
- PayPal webhooks are checked with PayPal before use.

Read [server/SECURITY.md](server/SECURITY.md) for the full model and the known gaps.

## License

MIT. See [LICENSE](LICENSE).
