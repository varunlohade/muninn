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
- `/v1/integrations` lists PayPal (live), Supplier payouts through PayPal (live), Contacts (on the phone only), Google reviews and Slack. Reminders, Calendly, Google Calendar and Shopify orders show as "coming soon".

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

## How Muninn uses PayPal (sandbox)

| Typed in any chat | PayPal API | What happens |
|---|---|---|
| "Sign in with PayPal" (onboarding) | Partner Referrals v2 | Connects the owner's PayPal business account |
| `invoice Sam 45 for a haircut` | Invoicing v2 | Creates and emails a real invoice |
| `send me 45 for the haircut` | Orders v2 | Makes a one-tap pay link |
| `remind Leo` | Invoicing v2 (remind) | Nudges a late client |
| `mark sam paid` / `cancel sam's invoice` | Invoicing v2 (payments, cancel) | Records or cancels, with Undo where PayPal allows it |
| `refund sam $20` | Payments v2 (captures/refund) | Refunds a paid payment |
| `pay Joe $20` | Payouts | Pays a supplier, with a strict confirm and a daily cap |
| `bill ana $40 every month`, `pause ana's plan` | Subscriptions (catalog products, plans, subscriptions) | Monthly client billing, pause, resume, cancel |
| `make me a projection for next 3 months` | Transaction Search | Monthly sales history behind the forecast chart |
| App Home | Transaction Search, Balances, Invoicing search, Disputes | Money in, who owes you, disputes |
| (background) | Webhooks + verify-webhook-signature | Live "Sam paid $45 ✓" updates |

The server also uses the **PayPal Agent Toolkit** (`@paypal/agent-toolkit`) for typed PayPal tools.
Nothing moves money without the owner's tap and a confirm step, and the server re-checks every amount and recipient.

## How Muninn uses AI

1. **Rules first.** Regex drops plain chat and reads clear amounts with no model call, so casual messages cost nothing.
2. **TypeSafe jev** (`jev-latest`) routes the message to an intent (invoice, pay link, reminder, refund, payout, plan, chart or none) in about 0.2 s.
3. **Meta Llama 3.3 70B Instruct via OpenRouter** extracts the details (who, which item, quantity) and writes replies and the daily brief. **Gemini 2.5 Flash via OpenRouter** is the backup.
4. **The business profile** ("What does your business do?") goes into every prompt, so "how much?" means a haircut for a barber and a per-screen price for an app developer.
5. **Prices come only from the owner's catalog, never from the model.** With no price, Muninn offers "Add a price".

Tested on 24 kinds of business and 163 messages (`server/test/business-matrix*.ts`, live eval `server/scripts/eval-businesses.ts`).

## For judges

- Server: `https://muninn-api-production-ea1c.up.railway.app` (hosted on Railway)
- iOS app: TestFlight (invite on request)
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

The live server runs on Railway (service with a volume for SQLite).
`render.yaml` also describes the same setup as one Render web service with a 1 GB disk.
Render asks for each secret in its dashboard.
With `DEMO_SEED=1`, the first boot seeds the demo and prints the demo token once in the logs.

## Built with

- PayPal REST APIs and the PayPal Agent Toolkit
- TypeSafe jev
- OpenRouter (Llama 3.3 70B on Groq, Gemini 2.5 Flash)
- Hono, zod, Node.js built-in SQLite, hosted on Railway
- Swift and SwiftUI (app + custom keyboard extension)
- Excalidraw (MIT) for charts and drawings in the keyboard
- No hackathon sponsor tools beyond PayPal

## Security

- Client names and emails are encrypted with AES-256-GCM. Each user has their own key.
- Device tokens are stored as hashes.
- Every query filters by the user from the token. Another user's ids return 404.
- Money actions need a tap and an idempotency key. A refund takes two steps.
- PayPal webhooks are checked with PayPal before use.

Read [server/SECURITY.md](server/SECURITY.md) for the full model and the known gaps.

## License

MIT. See [LICENSE](LICENSE).
