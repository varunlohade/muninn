# Security

## What we encrypt
- Client names and client emails on invoices and orders.
- Integration config (one row per user and provider).
- We do not store typed message text. `/v1/suggest` and `/v1/reply` read it, send it to the models, and drop it.
- Device tokens: we store only a SHA-256 hash.
- Apple user ids (`sub`): we store only a keyed hash, `HMAC-SHA256(HKDF(DATA_ENCRYPTION_KEY, info = "pro-keyboard/index/v1"), sub)`. We ask Apple for no name and no email.

## How
- AES-256-GCM, a random 12-byte IV per record, a 16-byte auth tag. Format: `v1:base64(iv | tag | ciphertext)`.
- Each user gets their own data key: `HKDF-SHA256(DATA_ENCRYPTION_KEY, salt = user_id, info = "pro-keyboard/data/v1")`.
- The `user_id` is the GCM additional data. A row copied to another user fails to decrypt.

## Key handling
- `DATA_ENCRYPTION_KEY` is 32 random bytes (64 hex chars) in `.env`. `npm run setup` creates it if it is missing and never prints it.
- `.env` is git-ignored with mode 0600. Secrets come only from the environment.
- No PayPal secret and no encryption key goes to any model. The models get only the message text and the owner's catalog.
- `/v1/brief` sends the model summary numbers and the first name of the most late client, nothing else. The server rejects any number in the reply that is not in those facts and falls back to a template.
- Logs redact keys that look like tokens, secrets, names, emails or text.

## Sign in with Apple
- `POST /v1/auth/apple` takes the identity token and the raw nonce. It is the only `/v1` route with no device token.
- The server checks the RS256 signature against Apple's keys (`https://appleid.apple.com/auth/keys`, cached for a day), then `iss`, `aud` (`APPLE_BUNDLE_ID`, default `com.orseliyas.muninn`), `exp`, and that the token's `nonce` is the SHA-256 of the raw nonce.
- Every failure returns the same `401 {"error":"unauthorized"}`. The reason goes only to the server log. The token never goes to the log.
- A good token finds or creates the user and returns a new device token. The limit is 10 calls a minute per client IP.

## Per-user data
- A device token maps to one `user_id`. One user can have several devices.
- Every table has a `user_id`. Every query filters by the `user_id` from the token, never from the request body.
- Another user's ids return 404, not 403, so nothing leaks about whether they exist.
- Webhooks find the owner from our own invoice and order tables. We ignore unknown ids.
- PayPal transactions and disputes come from the user's own PayPal client and sit in a 60 s cache keyed by `user_id`. Another user's dispute id returns 404.
- PayPal access goes through `getPayPalClientForUser(user_id)`. Today it returns the one hackathon sandbox merchant. A real "Connect PayPal" flow plugs in per-user credentials there.

## Money actions
- Actions, and `POST /v1/disputes/:id/message`, run only with `X-User-Action: tap` and an `Idempotency-Key`. `/v1/suggest` never runs them.
- The server checks amounts: more than 0, at most 10000, at most 2 decimals, allowed currencies only.
- A refund takes two calls. The first call returns a one-time confirm token that expires in 2 minutes.
- The confirm step runs in one SQLite transaction. Only one refund per payment runs at a time. The server checks the amount again against what is left. Claiming one token voids every other open token for that payment.
- We do not cache the first refund step, so no confirm token or summary sits in the idempotency table.
- We reserve an idempotency key before the PayPal call and store a hash of the body. A key in progress returns 409, and so does a reused key with a different body.
- PayPal calls carry a `PayPal-Request-Id` made from the user and the idempotency key.
- We strip control, newline and bidi characters from item names, client names and chip labels, before display and before PayPal.
- The invoice chip label shows the recipient. If the email is not in the typed text and not a known client, the chip gets `needs_confirm: true`.

## Shared drawings ("Send as link")
- `POST /v1/drawings` takes one PNG (checked by its magic bytes), at most 1 MB, 20 an hour per user.
- The id is 128 random bits (`/d/<22 base64url chars>.png`). It holds nothing about the user or the time, and no route lists ids.
- `GET /d/<id>.png` needs no token: whoever has the link sees the image, served as `image/png` with `nosniff` and `default-src 'none'`, and nothing else. 120 views a minute per address.
- A link works for 30 days. Expired rows are deleted on the next upload, and an expired id answers like an unknown one (404).
- The image itself is not encrypted at rest: anyone with the link may see it, by design.
- `/v1/explain` and `/v1/explain/visual` take only text the phone read as an explain question (max 200 characters). They log sizes and timings, never the question or the answer. 10 a minute and 100 a day per user.

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
- The server trusts `X-Forwarded-For` only with `TRUST_PROXY=1`, and then only the right-most hop. Behind Cloudflare (Render), set `CLIENT_IP_HEADER=cf-connecting-ip`, because there the right-most hop is the Cloudflare edge. Failed webhook checks count per IP. Verified events have their own budget.
- `npm audit` still lists 12 issues. All of them come in through `@paypal/agent-toolkit` (langchain, ai-sdk, mathjs, uuid, its own zod 3). The only fix npm offers is a downgrade to toolkit 1.3.5.
