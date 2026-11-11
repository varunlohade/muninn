# Connect PayPal

How a business owner connects their own PayPal account to Muninn, so invoices, pay links, repeat bills and refunds go to their account and not the shared sandbox demo merchant.

Checked 2026-11-11 against developer.paypal.com only. No live PayPal calls were made for this note.

## Verdict

Use **Partner Referrals v2** with **PayPal-Auth-Assertion**, not Log in with PayPal.

- Log in with PayPal gives identity (who the user is). It does not give a platform the right to make invoices or take refunds on another account.
- Partner Referrals onboards the seller and asks them to grant named third-party permissions to our REST app. After that, our platform credentials act for the seller with the `PayPal-Auth-Assertion` header.

**Sandbox:** PayPal says the Partner (Multiparty) APIs are for approved partners, and that unapproved live calls get `401 Unauthorized`. The same page says: "You can call and test the PayPal Complete Payments Platform APIs with your sandbox credentials before you are approved." So the sandbox flow works on an ordinary sandbox REST app. Live use needs PayPal partner approval.
Source: https://developer.paypal.com/docs/multiparty/get-started/

## The flow

1. App: owner taps **Connect PayPal**. Server: `POST /v1/paypal/connect`.
2. Server: `POST /v2/customer/partner-referrals` with a fresh random `tracking_id` (`mu` + 32 hex; never the email or user id), `operations[0] = API_INTEGRATION / PAYPAL / THIRD_PARTY` with the features below, `products: ["EXPRESS_CHECKOUT"]`, `legal_consents: SHARE_DATA_CONSENT`, and `partner_config_override.return_url = <PUBLIC_BASE_URL>/paypal/return`. PayPal answers with an `action_url` link (single use).
3. App: opens `action_url` in `ASWebAuthenticationSession`. The owner signs in to PayPal and grants the permissions.
4. PayPal sends the browser to `return_url` with `merchantId` (our tracking id), `merchantIdInPayPal`, `permissionsGranted`, `consentStatus`, `isEmailConfirmed`, `accountStatus`.
5. Server: trusts nothing in that query. It finds the pending connect by the tracking id's hash, asks PayPal `GET /v1/customer/partners/{partner_id}/merchant-integrations?tracking_id=` which merchant owns that tracking id, checks it equals `merchantIdInPayPal`, then reads `GET .../merchant-integrations/{merchant_id}` for `payments_receivable`, `primary_email_confirmed`, `primary_email`, and that `oauth_integrations` lists our client id. Then it stores the merchant id and email encrypted per user, and redirects to `muninn://paypal-connected?result=connected|declined|taken|failed`.
6. Webhooks: `MERCHANT.ONBOARDING.COMPLETED` finishes a pending connect the same way. `MERCHANT.PARTNER-CONSENT.REVOKED` deletes the connection, so the user is back on the demo merchant.

Sources:
- Onboard sellers before payment (request, return parameters, merchant-integrations check, webhooks): https://developer.paypal.com/docs/multiparty/seller-onboarding/before-payment/
- Partner Referrals v2 spec (`rest_endpoint_features` enum, `partner_config_override.return_url`): https://developer.paypal.com/docs/api/partner-referrals/v2/ (schema: https://developer.paypal.com/docs/api/partner-referrals/v2/schema.json)

## Features asked for, in one referral

`PAYMENT, REFUND, INVOICE_READ_WRITE, PAYOUTS, ADVANCED_TRANSACTIONS_SEARCH, READ_SELLER_DISPUTE, UPDATE_SELLER_DISPUTE, TRACKING_SHIPMENT_READWRITE, ACCESS_MERCHANT_INFORMATION, PAYPAL_BALANCE, BILLING_AGREEMENT`

All eleven are values of `rest_endpoint_features_enum` in the Partner Referrals v2 spec. One referral means the seller consents once for every feature the app has or will add (payouts, balance, disputes, subscriptions).

## Calling APIs for the seller

Header: `PayPal-Auth-Assertion: base64({"alg":"none"}) + "." + base64({"iss":<our client id>,"payer_id":<seller merchant id>}) + "."` (unsigned, empty signature, as PayPal's Node sample shows). Optional `PayPal-Partner-Attribution-Id: <BN code>`.
Source: https://developer.paypal.com/api/rest/requests/ and https://developer.paypal.com/docs/multiparty/checkout/immediate-capture/

Which APIs take it:
- **Orders v2 create and capture:** yes, the multiparty immediate-capture guide sends it on both.
- **Payments v2 refund:** yes, `PayPal-Auth-Assertion` is a documented header on `POST /v2/payments/captures/{id}/refund` in the Payments v2 spec.
- **Invoicing v2:** the API spec does not list the header, but PayPal's partner invoicing guide sends it on create draft and send, after onboarding with `INVOICE_READ_WRITE` and `ACCESS_MERCHANT_INFORMATION`, and sets `invoicer.email_address` to the seller's `primary_email`. The guide says "available to select partners only". https://developer.paypal.com/docs/multiparty/invoicing/integrate/
- **Subscriptions v1 and Catalog Products:** the API specs do not list the header, but PayPal's partner subscriptions guide sends it on create product, create plan and create subscription. Also "select partners only". https://developer.paypal.com/docs/multiparty/subscriptions/integrate/

The Agent Toolkit cannot send this header, so a connected seller's invoices go through our own REST calls; the demo merchant keeps using the toolkit.

## What Muninn does with it

- A user with no connection runs on the shared demo merchant, as before. Money answers carry `demo: true`; Integrations says "Demo PayPal (sandbox)".
- Each invoice, order and subscription row stores the account that made it (`pp_account`: a keyed hash of the merchant id, or NULL for demo). Reminders, refunds, status refresh and order capture use that same account, so demo objects keep working after the owner connects. An object whose account is no longer connected fails with "no longer connected" instead of going to the wrong account.
- Billing plan and product cache keys carry the account (`m:<hash>:`), so a seller never reuses a demo plan.
- All existing money rules stay: server-side confirms, one idempotency key per chip, email only from the owner's text or records.

## Server setup

| env | what |
| --- | --- |
| `PUBLIC_BASE_URL` | this server's public https address; PayPal returns to `<it>/paypal/return` |
| `PAYPAL_PARTNER_MERCHANT_ID` | the merchant id of the sandbox business account that owns the REST app (sandbox.paypal.com → Account settings → Business information) |
| `PAYPAL_BN_CODE` | optional partner attribution code |

Without the first two, `POST /v1/paypal/connect` answers 503 and the app stays on the demo account. Subscribe the webhook to `MERCHANT.ONBOARDING.COMPLETED` and `MERCHANT.PARTNER-CONSENT.REVOKED`.

## Not verified

- No live sandbox run of the referral, return or an assertion call was made. The request bodies follow the docs above.
- The exact shape of `oauth_integrations[].oauth_third_party[].partner_client_id` in the merchant-integrations answer comes from the docs' description, not a live response. If PayPal names it differently, every return ends as `declined`; check the first live run.
- Invoicing and Subscriptions with the assertion are "select partners only" in the guides. Sandbox may allow them before approval as the get-started page says, but that is not proven here.
- Disconnect only forgets the seller in Muninn. The seller removes the permission in their PayPal settings; that sends the revoke webhook.
