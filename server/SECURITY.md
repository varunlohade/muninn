# Security

## What we encrypt
- Client names and client emails on invoices and orders.
- We do not store typed message text. `/v1/suggest` and `/v1/reply` read it, send it to the models, and drop it.
- Device tokens: we store only a SHA-256 hash.

## How
- AES-256-GCM, a random 12-byte IV per record, a 16-byte auth tag. Format: `v1:base64(iv | tag | ciphertext)`.
- Each user gets their own data key: `HKDF-SHA256(DATA_ENCRYPTION_KEY, salt = user_id, info = "pro-keyboard/data/v1")`.
- The `user_id` is the GCM additional data. A row copied to another user fails to decrypt.

## Key handling
- `DATA_ENCRYPTION_KEY` is 32 random bytes (64 hex chars) in `.env`. `npm run setup` creates it if it is missing and never prints it.
- `.env` is git-ignored with mode 0600. Secrets come only from the environment.
- No PayPal secret and no encryption key goes to any model. The models get only the message text and the owner's catalog.
- Logs redact keys that look like tokens, secrets, names, emails or text.

## Per-user data
- A device token maps to one `user_id`. One user can have several devices.
- Every table has a `user_id`. Every query filters by the `user_id` from the token, never from the request body.
- Another user's ids return 404, not 403, so nothing leaks about whether they exist.
- Webhooks find the owner from our own invoice and order tables. We ignore unknown ids.
- PayPal access goes through `getPayPalClientForUser(user_id)`. Today it returns the one hackathon sandbox merchant. A real "Connect PayPal" flow plugs in per-user credentials there.

## Money actions
- Actions run only with `X-User-Action: tap` and an `Idempotency-Key`. `/v1/suggest` never runs them.
- The server checks amounts: more than 0, at most 10000, at most 2 decimals, allowed currencies only.
- A refund takes two calls. The first call returns a one-time confirm token that expires in 2 minutes.
- PayPal calls carry a `PayPal-Request-Id` made from the user and the idempotency key.

## Threat model
1. **Stolen DB file.** Names and emails are ciphertext. Without the env key, an attacker gets amounts and item names only.
2. **Stolen or guessed device token.** Tokens have 256 random bits. The DB has only hashes. A stolen token reaches only that one user's data, and rate limits slow abuse.
3. **Prompt injection in chat text.** The model only fills fields and chips. It cannot move money, because each action needs a tap, and the server checks every amount again.
4. **Forged PayPal webhooks.** PayPal's verify-webhook-signature API checks each event. Without `PAYPAL_WEBHOOK_ID` we reject all webhooks.
5. **Replays and double taps.** Idempotency keys and PayPal-Request-Id stop duplicate invoices. Refund tokens work once.

## Known gaps
- The rate limiter lives in memory, so it resets on restart and does not span instances.
- There is no key rotation yet. The `v1:` prefix leaves room for it.
- CORS allows no origins by default. Set `CORS_ORIGINS` for a web client.
