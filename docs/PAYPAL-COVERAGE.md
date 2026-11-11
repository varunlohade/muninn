# PayPal coverage for Muninn (2026-11-11)

Source: the read-only audit agent. UNVERIFIED = not confirmed in developer.paypal.com docs.
Risk: MONEY = moves money, EMAIL = PayPal tells the customer, READ = read-only.

## Today
- Have: invoice create/send (app.ts:603), remind (app.ts:676), pay link (app.ts:628), refund with confirm_token (app.ts:695), subscribe create (app.ts:643), invoice list/status (app.ts:744), transactions/summary (app.ts:782/795), disputes list/view (app.ts:801/805), dispute message on the server only (app.ts:811, no iOS caller), webhooks (app.ts:1003).
- `recordPayment` exists (paypal.ts:296) but only the seed uses it.

## Gaps, ranked (cut line ~9.5 h)
0. UX copy fixes (section "Copy fixes") — 1 h. Do first.
1. Subscription status / pause (suspend) / resume (activate) / cancel — `/v1/billing/subscriptions/{id}/suspend|activate|cancel` — 1.5 h. Takes confirm_client.
2. Mark paid (`POST /v2/invoicing/invoices/{id}/payments`), undo it (`DELETE .../payments/{txn}`), cancel invoice (`.../cancel`), record refund (`.../refunds`) — 1.5 h. Takes confirm_client.
3. Balance — `GET /v1/reporting/balances` (UNVERIFIED in sandbox) — read-only; fallback to net from summary — 1 h.
4. Payouts — `POST /v1/payments/payouts`, cancel unclaimed item `POST /v1/payments/payouts-item/{id}/cancel` — strongest confirm (confirm_recipient + confirm_amount + confirm_currency), per-day cap — 2.5 h. Fix the "pay" collision first.
5. Disputes on iOS: send message, accept claim, make offer (`/v1/customer/disputes/{id}/send-message|accept-claim|make-offer`). Accept/offer take confirm_amount — 2 h.
--- cut line ---
6. Invoice QR (`/generate-qr-code`) 1 h. 7. Add tracking (`/v2/checkout/orders/{id}/track`) 1.5 h. 8. Auto reminders. 9. Dispute evidence upload. 10. Templates.

## One grammar
- Chip: `<Verb> <money> · <who>`. Verb names the effect in plain words.
- Confirm: one question naming who gets told and where money goes. Server checks every shown value (confirm_amount/currency/recipient/client → 409 needs_confirm on mismatch). Say "Can't undo." when PayPal can't undo it.
- Working: "<Verb>ing…". Done: "<Past verb> ✓", plus Undo only when PayPal can undo (pause→resume, mark paid→delete payment, payout→cancel while UNCLAIMED, tracking→cancel tracker).
- Only client-facing text goes into the chat field. Bar-only results (balance, status) never go into the field.
- All new actions go under `/v1/actions/*` so they inherit the tap gate and idempotency (app.ts:281-311).

## Phrase → chip → confirm → done
| Typed | Chip | Confirm | Done |
|---|---|---|---|
| invoice sam $45 sam@x.com | Invoice $45 · Sam | Email Sam (sam@x.com) a $45 invoice? | Invoice emailed to Sam ✓ |
| invoice sam $45 (no email) | Invoice link $45 · Sam | Make a $45 invoice link for Sam? No email goes out. | Invoice link ready ✓ |
| remind ana | Nudge Ana · $90 owed | Email Ana a reminder for $90? | Reminder emailed to Ana ✓ |
| refund sam $20 | Refund $20 · Sam | Refund $20 to Sam? PayPal tells Sam. Can't undo. | Refunded $20 to Sam ✓ |
| sam paid cash / mark sam paid | Mark paid $45 · Sam | Mark Sam's $45 invoice paid (cash)? No money moves. | Marked paid ✓ · Undo |
| cancel sam's invoice | Cancel invoice $45 · Sam | Cancel Sam's $45 invoice? PayPal tells Sam. Can't undo. | Invoice cancelled ✓ |
| pause ana's plan | Pause $40/mo · Ana | Pause Ana's $40 monthly bill? PayPal tells Ana. | Paused ✓ · Undo |
| restart ana's plan | Resume $40/mo · Ana | Restart Ana's $40 monthly bill? | Restarted ✓ |
| stop ana's plan for good | Cancel $40/mo · Ana | End Ana's $40 monthly bill? Can't undo. | Ended ✓ |
| what plans do I have | Repeat bills · 3 active | — | Ana $40/mo, Ben $20/wk +1 |
| pay my supplier joe $200 joe@x.com | Send $200 · Joe | Send Joe (joe@x.com) $200 from your PayPal? | Sent $200 to Joe ✓ · Undo |
| how much do I have | Balance | — | PayPal balance $1,240.50 |
| disputes | Disputes · 1 open | — | Sam $45 · reply by Thu |
| tell sam I shipped it (in a dispute) | Reply in dispute · Sam | Send this to Sam in PayPal's dispute? | Message sent ✓ |
| accept sam's claim | Accept claim $45 · Sam | Accept Sam's claim and refund $45? Can't undo. | Claim accepted ✓ |
| offer sam $20 back | Offer $20 · Sam | Offer Sam a $20 refund to close the dispute? | Offer sent ✓ |

## Copy fixes (today's confusing UX)
1. "pay joe $200" makes a pay link (quick.ts:44 `pay\w*`). Route "pay/send <name> <money>" to payout; until then no chip.
2. "Remind me" (SmartDetect.swift:40, private) vs "Remind Ana" (app.ts:541, emails client). Rename PayPal chip "Nudge Ana · $90 owed".
3. "Invoice sent" when no email (HomeView.swift:531, KeyboardModel.swift:374, confirm BarItems.swift:180-181). Say "Invoice link ready"; email confirm starts with "Email".
4. "Who paid?" opens who owes (ReadyChips.swift:27-28, app.ts:530). Rename "Who owes you · 3 unpaid". One waiting line: "Waiting on $45 · Sam" (BarItems.swift:84, ReadyChips.swift:34).
5. Three names for one action: "Invoice Sam" / "Bill Sam?" (HomeView.swift:236) / "Next: Sam 3pm" (ReadyChips.swift:23). Use "Invoice Sam" everywhere; "Next" informs only.
6. "Invoice later" (SmartDetect.swift:42) → "Remind me to invoice Sam".
7. Refund confirm → "Refund $20 to Sam? Can't undo."
8. Ask "no match" uses error style (HomeView.swift:441); hints list invoices only (app.ts:873/892). Neutral line: "Try: invoice Sam $45 · nudge Ana · refund Sam $20 · who owes me".
9. Disputes dead end (HomeView.swift:455-458, ClientDetailView.swift:64): show "Sam $45 · reply by Thu" with Reply / Offer / Accept.
10. Integrations says PayPal "Connected" (integrations.ts:26) on the shared sandbox merchant → "Demo PayPal (sandbox)" until Connect ships.

## Conflicts
- Typed search owns quick.ts lookups and /v1/ask table. Put new verb regexes in a new block at the end of quick.ts; new routes in `server/src/actions-more.ts` mounted from createApp.
- Connect PayPal: add every new method to the `PayPal` type (paypal.ts:7-23). Objects made under the platform account keep using the platform client. Plan cache key needs the merchant id.
- Partner-referral features: INVOICE_READ_WRITE, PAYMENT, REFUND, PAYOUTS, ADVANCED_TRANSACTIONS_SEARCH, PAYPAL_BALANCE (UNVERIFIED), READ_SELLER_DISPUTE, UPDATE_SELLER_DISPUTE, TRACKING_SHIPMENT_READWRITE, BILLING_AGREEMENT (UNVERIFIED), ACCESS_MERCHANT_INFORMATION. Ask for all in one referral.
