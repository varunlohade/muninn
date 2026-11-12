import { test } from 'node:test';
import assert from 'node:assert/strict';
import { payoutAsk } from '../src/quick.ts';
import { PayPalError } from '../src/paypal.ts';
import { paidEvent, setup, sleep, webhookHeaders } from './helpers.ts';

const suggest = async (s: ReturnType<typeof setup>, token: string, text: string, context?: string) =>
  (await (await s.call(token, 'POST', '/v1/suggest', { text, ...(context ? { context } : {}) })).json()) as { chips: any[]; intent: string };

// ---- step 0: copy fixes

test('copy: "pay joe $200" is a payout phrase, never a pay link, and costs no model call', async () => {
  const s = setup({ cls: { intent: 'pay_link' } });
  const { token } = s.device();
  for (const text of ['pay joe $200', 'send my supplier joe $200 joe@x.com', 'send $200 to joe']) {
    const out = await suggest(s, token, text);
    assert.equal(out.chips.some((c) => c.kind === 'paylink' || c.kind === 'invoice'), false, text);
  }
  assert.equal(s.aiCalls.length, 0);
  const ask = await (await s.call(token, 'POST', '/v1/ask', { text: 'pay joe $200' })).json();
  assert.equal(ask.route, 'action');
  assert.equal(s.aiCalls.length, 0);
});

test('copy: payoutAsk reads name, amount and typed email; requests to be paid are not payouts', () => {
  assert.deepEqual(payoutAsk('pay my supplier joe $200 joe@x.com'), { name: 'Joe', amount: 200, currency: null, email: 'joe@x.com', note: null });
  assert.deepEqual(payoutAsk('send $200 to joe'), { name: 'Joe', amount: 200, currency: null, email: null, note: null });
  for (const t of ['pay me $45', 'send sam a $45 invoice', 'send you the $45 link', 'pay joe', 'can you pay $45 by friday']) assert.equal(payoutAsk(t), null, t);
  assert.deepEqual(payoutAsk('pay my staff ana 60 usd'), { name: 'Ana', amount: 60, currency: 'USD', email: null, note: null });
  assert.deepEqual(payoutAsk('pay joe smith $200'), { name: 'Joe Smith', amount: 200, currency: null, email: null, note: null });
  assert.deepEqual(payoutAsk('send $200 to joe for tiles'), { name: 'Joe', amount: 200, currency: null, email: null, note: 'tiles' });
  assert.deepEqual(payoutAsk('pay joe $200 for tiles joe@x.com'), { name: 'Joe', amount: 200, currency: null, email: 'joe@x.com', note: 'tiles' });
  assert.deepEqual(payoutAsk('send $200 to joe smith joe@x.com for the grout'), { name: 'Joe Smith', amount: 200, currency: null, email: 'joe@x.com', note: 'the grout' });
  for (const t of ['pay joe $200 for tiles tomorrow', 'pay joe $200 for friday', 'send $200 to joe for 3 tiles', 'pay joe $200 at 5pm', 'pay joe smith $200 on monday']) {
    assert.equal(payoutAsk(t), null, t);
  }
});

test('payouts: ordinary chat is never a payout and never ends suggest', async () => {
  const chat = ['send ana the address at 5pm', 'pay rent 1200 tomorrow', 'send me 2 photos', "i'll pay sam tomorrow",
    'pay sam $45 tomorrow', 'send joe $20 and $30'];
  for (const t of chat) assert.equal(payoutAsk(t), null, t);
  const s = setup({ cls: { intent: 'create_invoice' } });
  const { token } = s.device();
  for (const text of chat) {
    const out = await suggest(s, token, text);
    assert.equal(out.chips.some((c) => c.kind === 'payout' || /^(Type the amount|Add .* email)/.test(c.label)), false, text);
  }
  assert.ok(s.aiCalls.length > 0, 'the money path still runs');
});

test('copy: reminder chip says Nudge and owed; who-owes chip; refund confirm says it cannot be undone', async () => {
  const s = setup({ cls: { intent: 'send_reminder' } });
  const { token } = s.device();
  await s.call(token, 'POST', '/v1/actions/invoice', { amount: 90, item: 'Color', client_name: 'Ana' });
  const remind = await suggest(s, token, 'remind ana');
  assert.equal(remind.chips[0].label, 'Nudge Ana · $90 owed');

  const who = setup({ cls: { intent: 'payment_status' } });
  const w = who.device();
  assert.equal((await suggest(who, w.token, 'who paid me')).chips[0].label, 'Who owes you · 0 unpaid');

  const inv = await (await s.call(token, 'POST', '/v1/actions/invoice', { amount: 20, item: 'Trim', client_name: 'Sam' })).json();
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(inv.id), webhookHeaders);
  const step1 = await (await s.call(token, 'POST', '/v1/actions/refund', { id: inv.id })).json();
  assert.equal(step1.summary, "Refund $20 to Sam? Can't undo.");
});

test('copy: ask with no match gives the neutral hint line with every verb', async () => {
  const s = setup();
  const { token } = s.device();
  const out = await (await s.call(token, 'POST', '/v1/ask', { text: 'hi' })).json();
  assert.equal(out.result.line, 'Try: invoice Sam $45 · nudge Ana · refund Sam $20 · who owes me');
});

// ---- step 1: repeat bills

async function plan(s: ReturnType<typeof setup>, token: string, name: string, email: string, amount = 40, interval = 'month') {
  const sub = await (await s.call(token, 'POST', '/v1/actions/subscribe', {
    amount, interval, client_name: name, client_email: email, confirm_amount: amount, confirm_currency: 'USD', confirm_interval: interval, confirm_recipient: email,
  })).json();
  return sub.id as string;
}
const send = async (s: ReturnType<typeof setup>, token: string, path: string, body: unknown, key?: string) => {
  const res = await s.call(token, 'POST', path, body, key ? { 'Idempotency-Key': key } : {});
  return { status: res.status, json: (await res.json()) as any };
};
const confirmed = (ch: any) => ({ ...ch.payload.body, ...ch.payload.confirm });
/** The user's own PayPal is connected: payouts run on it with the full daily cap. */
function connectSeller(s: ReturnType<typeof setup>, userId: string, account = `acct-${userId.slice(0, 8)}`) {
  assert.ok(s.db.startPayPalConnect(userId, `track-${userId}`, Date.now()));
  assert.ok(s.db.finishPayPalConnect(userId, `track-${userId}`, { merchant_hash: account, merchant_enc: null, email_enc: null, payments_receivable: 1, email_confirmed: 1 }));
}

test('plans: "what plans do I have" lists them in one line, active count on the chip, no model call', async () => {
  const s = setup();
  const A = s.device();
  const ana = await plan(s, A.token, 'Ana', 'ana@x.com');
  await plan(s, A.token, 'Ben', 'ben@x.com', 20, 'week');
  await plan(s, A.token, 'Cy', 'cy@x.com', 90, 'year');
  s.db.setSubscriptionActive(A.userId, ana, Date.now());
  const out = await suggest(s, A.token, 'what plans do I have');
  assert.equal(out.chips.length, 1);
  assert.equal(out.chips[0].label, 'Repeat bills · 1 active');
  assert.equal(out.chips[0].payload.line, 'Ana $40/mo, Cy $90/yr waiting +1');
  assert.equal(s.aiCalls.length, 0);
  const B = s.device();
  assert.equal((await suggest(s, B.token, 'my plans')).chips[0].label, 'Repeat bills · none yet', 'B never sees A plans');
});

test('plans: pause asks first, checks client, amount and currency, runs once per key, and offers Undo', async () => {
  const s = setup();
  const { token, userId } = s.device();
  const id = await plan(s, token, 'Ana', 'ana@x.com');
  s.db.setSubscriptionActive(userId, id, Date.now());
  const [ch] = (await suggest(s, token, "pause ana's plan")).chips;
  assert.equal(ch.kind, 'plan_pause');
  assert.equal(ch.label, 'Pause $40/mo · Ana');
  assert.equal(ch.needs_confirm, true);
  assert.equal(ch.payload.question, "Pause Ana's $40 monthly bill? PayPal tells Ana.");

  const bare = await send(s, token, '/v1/actions/plan/pause', ch.payload.body);
  assert.equal(bare.status, 409);
  assert.equal(bare.json.needs_confirm, true);
  for (const wrong of [{ confirm_client: 'Ben' }, { confirm_amount: '41.00' }, { confirm_currency: 'EUR' }]) {
    assert.equal((await send(s, token, '/v1/actions/plan/pause', { ...confirmed(ch), ...wrong })).status, 409, JSON.stringify(wrong));
  }
  assert.equal(s.calls.filter((c) => c.fn === 'change_subscription').length, 0, 'nothing reaches PayPal before a matching confirm');

  const done = await send(s, token, '/v1/actions/plan/pause', confirmed(ch), 'pause-key-0001');
  assert.equal(done.status, 200);
  assert.equal(done.json.line, 'Paused ✓');
  assert.equal(done.json.undo.kind, 'plan_resume');
  const again = await send(s, token, '/v1/actions/plan/pause', confirmed(ch), 'pause-key-0001');
  assert.deepEqual(again.json, done.json, 'same key replays the stored answer');
  assert.deepEqual(s.calls.filter((c) => c.fn === 'change_subscription').map((c) => c.args.slice(0, 2)), [[id, 'suspend']]);
  assert.equal(s.db.getSubscription(userId, id)!.status, 'SUSPENDED');

  const undone = await send(s, token, '/v1/actions/plan/resume', done.json.undo.payload.body);
  assert.equal(undone.status, 200);
  assert.equal(undone.json.line, 'Restarted ✓');
  assert.equal(undone.json.undo, null);
  assert.equal(s.db.getSubscription(userId, id)!.status, 'ACTIVE');
});

test('plans: the restart Undo after a pause works for 10 minutes, then expires', async () => {
  let t = Date.now();
  const s = setup({ now: () => t });
  const { token, userId } = s.device();
  const run = async () => {
    const id = await plan(s, token, 'Ana', 'ana@x.com');
    s.db.setSubscriptionActive(userId, id, t);
    const [ch] = (await suggest(s, token, "pause ana's plan")).chips;
    return (await send(s, token, '/v1/actions/plan/pause', confirmed(ch))).json.undo.payload.body;
  };
  const fresh = await run();
  t += 9 * 60_000;
  assert.equal((await send(s, token, '/v1/actions/plan/resume', fresh)).status, 200);
  s.db.raw.prepare("UPDATE subscriptions SET status = 'CANCELLED' WHERE user_id = ?").run(userId);
  const stale = await run();
  t += 11 * 60_000;
  const late = await send(s, token, '/v1/actions/plan/resume', stale);
  assert.equal(late.status, 409);
  assert.match(late.json.error, /expired/);
  assert.equal(s.calls.filter((c) => c.fn === 'change_subscription' && c.args[1] === 'activate').length, 1);
});

test('plans: another user cannot pause, resume or read a plan; PayPal state wins over a stale row', async () => {
  const s = setup();
  const A = s.device();
  const id = await plan(s, A.token, 'Ana', 'ana@x.com');
  s.db.setSubscriptionActive(A.userId, id, Date.now());
  const [ch] = (await suggest(s, A.token, 'pause ana')).chips;
  const B = s.device();
  assert.equal((await send(s, B.token, '/v1/actions/plan/pause', confirmed(ch))).status, 404);
  assert.equal((await s.call(B.token, 'GET', `/v1/plans/${id}`)).status, 404);
  assert.equal(s.calls.some((c) => c.fn === 'change_subscription' || c.fn === 'get_subscription'), false);

  s.subStatus.set(id, 'SUSPENDED');
  const stale = await send(s, A.token, '/v1/actions/plan/pause', confirmed(ch));
  assert.equal(stale.status, 409);
  assert.equal(s.db.getSubscription(A.userId, id)!.status, 'SUSPENDED', 'the row now matches PayPal');
  const read = await (await s.call(A.token, 'GET', `/v1/plans/${id}`)).json();
  assert.equal(read.line, 'Ana $40/mo · paused');
});

test('plans: end needs a plan word and says it cannot be undone; a plan waiting for approval gets only a line', async () => {
  const s = setup({ cls: { intent: 'none' } });
  const { token, userId } = s.device();
  const id = await plan(s, token, 'Ana', 'ana@x.com');
  assert.equal((await suggest(s, token, "pause ana's plan")).chips[0].kind, 'show');
  s.db.setSubscriptionActive(userId, id, Date.now());
  const [end] = (await suggest(s, token, "stop ana's plan for good")).chips;
  assert.equal(end.kind, 'plan_cancel');
  assert.equal(end.payload.question, "End Ana's $40 monthly bill? Can't undo.");
  const done = await send(s, token, '/v1/actions/plan/cancel', confirmed(end));
  assert.equal(done.json.line, 'Ended ✓');
  assert.equal(done.json.undo, null);
  assert.equal((await suggest(s, token, 'stop by at 3 ana')).chips.some((c) => c.kind === 'plan_cancel'), false);
  assert.equal((await suggest(s, token, "how is ana's plan")).chips.length, 0, 'an ended plan is no longer open');
});

// ---- step 2: invoices

async function invoiceFor(s: ReturnType<typeof setup>, token: string, name: string, amount: number, email?: string) {
  const body = email
    ? { amount, currency: 'USD', item: 'Haircut', client_name: name, client_email: email, confirm_recipient: email, confirm_amount: amount, confirm_currency: 'USD' }
    : { amount, item: 'Haircut', client_name: name };
  return (await (await s.call(token, 'POST', '/v1/actions/invoice', body)).json()).id as string;
}

test('invoices: mark paid asks, checks client and amount, records once, and Undo takes the payment back', async () => {
  const s = setup();
  const A = s.device();
  const id = await invoiceFor(s, A.token, 'Sam', 45, 'sam@x.com');
  const [ch] = (await suggest(s, A.token, 'sam paid cash')).chips;
  assert.equal(ch.kind, 'invoice_mark_paid');
  assert.equal(ch.label, 'Mark paid $45 · Sam');
  assert.equal(ch.payload.question, "Mark Sam's $45 invoice paid (cash)? No money moves.");
  assert.deepEqual(ch.payload.body, { invoice_id: id, method: 'CASH' });
  assert.equal((await suggest(s, A.token, 'mark sam paid')).chips[0].payload.question, "Mark Sam's $45 invoice paid? No money moves.");

  assert.equal((await send(s, A.token, '/v1/actions/invoice/mark-paid', ch.payload.body)).status, 409);
  assert.equal((await send(s, A.token, '/v1/actions/invoice/mark-paid', { ...confirmed(ch), confirm_client: 'Ana' })).status, 409);
  assert.equal((await send(s, A.token, '/v1/actions/invoice/mark-paid', { ...confirmed(ch), confirm_amount: '40.00' })).status, 409);
  const B = s.device();
  assert.equal((await send(s, B.token, '/v1/actions/invoice/mark-paid', confirmed(ch))).status, 404);
  assert.equal(s.calls.filter((c) => c.fn === 'record_payment').length, 0);

  const done = await send(s, A.token, '/v1/actions/invoice/mark-paid', confirmed(ch), 'mark-key-0001');
  assert.equal(done.json.line, 'Marked paid ✓');
  assert.deepEqual(await send(s, A.token, '/v1/actions/invoice/mark-paid', confirmed(ch), 'mark-key-0001'), done);
  const recorded = s.calls.filter((c) => c.fn === 'record_payment');
  assert.equal(recorded.length, 1);
  assert.equal((recorded[0].args[1] as any).method, 'CASH');
  assert.equal(s.db.getInvoice(A.userId, id)!.status, 'MARKED_AS_PAID');
  assert.ok(s.db.getInvoice(A.userId, id)!.paid_at);

  assert.equal(done.json.undo.kind, 'invoice_unmark');
  const paymentId = (s.db.raw.prepare('SELECT payment_id FROM recorded_payments WHERE invoice_id = ?').get(id) as { payment_id: string }).payment_id;
  assert.match(paymentId, /^EXTR-/);
  const undo = await send(s, A.token, '/v1/actions/invoice/unmark-paid', done.json.undo.payload.body);
  assert.equal(undo.json.line, 'Back to unpaid ✓');
  assert.deepEqual(s.calls.find((c) => c.fn === 'delete_payment')!.args.slice(0, 2), [id, paymentId]);
  assert.equal(s.db.getInvoice(A.userId, id)!.paid_at, null);
  assert.equal(s.db.getInvoice(A.userId, id)!.status, 'SENT');
  assert.equal((await send(s, A.token, '/v1/actions/invoice/unmark-paid', done.json.undo.payload.body)).status, 409, 'nothing left to take back');
});

test('invoices: cancel says who PayPal tells and cannot be undone; two open invoices need the amount', async () => {
  const s = setup();
  const { token, userId } = s.device();
  const emailed = await invoiceFor(s, token, 'Sam', 45, 'sam@x.com');
  const [ch] = (await suggest(s, token, "cancel sam's invoice")).chips;
  assert.equal(ch.kind, 'invoice_cancel');
  assert.equal(ch.payload.question, "Cancel Sam's $45 invoice? PayPal tells Sam. Can't undo.");
  const done = await send(s, token, '/v1/actions/invoice/cancel', confirmed(ch));
  assert.equal(done.json.line, 'Invoice cancelled ✓');
  assert.equal(done.json.undo, null);
  assert.deepEqual(s.calls.find((c) => c.fn === 'cancel_invoice')!.args.slice(0, 2), [emailed, true]);
  assert.equal(s.db.getInvoice(userId, emailed)!.status, 'CANCELLED');
  assert.equal((await send(s, token, '/v1/actions/invoice/cancel', confirmed(ch))).status, 409);

  await invoiceFor(s, token, 'Ana', 30);
  await invoiceFor(s, token, 'Ana', 60);
  // Two open invoices: the chip takes the latest and its confirm names it; the list line comes second.
  const two = (await suggest(s, token, "cancel ana's invoice")).chips;
  assert.deepEqual(two.map((c: any) => [c.kind, c.label]), [['invoice_cancel', 'Cancel invoice $60 · Ana'], ['show', 'Ana has 2 open invoices']]);
  const [one] = (await suggest(s, token, "cancel ana's $60 invoice")).chips;
  assert.equal(one.payload.question, "Cancel Ana's $60 invoice? No email goes out. Can't undo.");
});

test('invoices: record a refund only on a payment made outside PayPal, never more than is left', async () => {
  const s = setup();
  const { token, userId } = s.device();
  const viaPayPal = await invoiceFor(s, token, 'Sam', 45, 'sam@x.com');
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(viaPayPal), webhookHeaders);
  const [hint] = (await suggest(s, token, 'record a $20 refund for sam')).chips;
  assert.equal(hint.kind, 'show');
  assert.match(hint.payload.line, /refund Sam \$20/);

  const cash = await invoiceFor(s, token, 'Ana', 45);
  const [mark] = (await suggest(s, token, 'ana paid cash')).chips;
  await send(s, token, '/v1/actions/invoice/mark-paid', confirmed(mark));
  const [ch] = (await suggest(s, token, 'refunded ana $20 in cash')).chips;
  assert.equal(ch.kind, 'invoice_refund');
  assert.equal(ch.label, 'Record refund $20 · Ana');
  assert.equal(ch.payload.question, 'Record a $20 cash refund to Ana? No money moves.');
  assert.equal((await send(s, token, '/v1/actions/invoice/record-refund', { ...confirmed(ch), confirm_amount: '45.00' })).status, 409);
  assert.equal((await send(s, token, '/v1/actions/invoice/record-refund', { ...confirmed(ch), amount: '46.00', confirm_amount: '46.00' })).status, 400);
  const done = await send(s, token, '/v1/actions/invoice/record-refund', confirmed(ch));
  assert.equal(done.json.line, 'Refund recorded ✓');
  assert.equal(s.db.getInvoice(userId, cash)!.status, 'PARTIALLY_REFUNDED');
  const rest = (await suggest(s, token, 'record refund ana')).chips[0];
  assert.equal(rest.label, 'Record refund $25 · Ana');
  await send(s, token, '/v1/actions/invoice/record-refund', confirmed(rest));
  assert.equal(s.db.getInvoice(userId, cash)!.status, 'MARKED_AS_REFUNDED');
  assert.equal(s.calls.filter((c) => c.fn === 'record_refund').length, 2);
  assert.equal(s.calls.filter((c) => c.fn === 'refund').length, 0, 'no PayPal money moved');
});

test('invoices: two record-refund taps at once cannot record more than was paid; a failed call frees its hold', async () => {
  const s = setup();
  const { token, userId } = s.device();
  const id = await invoiceFor(s, token, 'Ana', 45);
  const [mark] = (await suggest(s, token, 'ana paid cash')).chips;
  await send(s, token, '/v1/actions/invoice/mark-paid', confirmed(mark));
  const body = (amount: string) => ({ invoice_id: id, amount, method: 'CASH', confirm_client: 'Ana', confirm_amount: amount, confirm_currency: 'USD' });
  const real = s.mockPayPal.recordRefund;
  s.mockPayPal.recordRefund = async (...a) => { await sleep(20); return real(...a); };
  const both = await Promise.all([
    send(s, token, '/v1/actions/invoice/record-refund', body('30.00'), 'refund-race-0001'),
    send(s, token, '/v1/actions/invoice/record-refund', body('30.00'), 'refund-race-0002'),
  ]);
  assert.deepEqual(both.map((r) => r.status).sort(), [200, 400]);
  assert.equal(s.calls.filter((c) => c.fn === 'record_refund').length, 1);

  s.mockPayPal.recordRefund = async () => { throw new PayPalError('PayPal down', 502, 503); };
  assert.equal((await send(s, token, '/v1/actions/invoice/record-refund', body('15.00'), 'refund-fail-0001')).status, 502);
  s.mockPayPal.recordRefund = real;
  assert.equal((await send(s, token, '/v1/actions/invoice/record-refund', body('15.00'), 'refund-ok-0001')).status, 200, 'the failed hold was freed');
  assert.equal(s.db.getInvoice(userId, id)!.status, 'MARKED_AS_REFUNDED');
});

// ---- step 3: balance

test('balance: one chip for the owner asking, none for a client message; the read never touches the chat', async () => {
  const s = setup({ cls: { intent: 'none' } });
  const { token } = s.device();
  for (const text of ['how much do I have', "what's my PayPal balance?", 'balance']) {
    const [ch] = (await suggest(s, token, text)).chips;
    assert.equal(ch.kind, 'balance', text);
    assert.equal(ch.label, 'Balance');
  }
  assert.equal(s.calls.some((c) => c.fn === 'balances'), false, 'suggest only offers it; the tap reads it');
  assert.equal(s.aiCalls.length, 0, 'no model call');
  assert.equal((await suggest(s, token, 'your balance is $45')).chips.some((c) => c.kind === 'balance'), false);

  const read = await (await s.call(token, 'GET', '/v1/balance')).json();
  assert.equal(read.line, 'PayPal balance $1,240.50');
  s.balance.reply = [{ currency: 'EUR', available: '0.00', primary: false }, { currency: 'USD', available: '12.00', primary: true }];
  assert.equal((await (await s.call(token, 'GET', '/v1/balance')).json()).line, 'PayPal balance $12', 'empty currencies are left out');
});

test('balance: a sandbox that refuses the read falls back to net this week', async () => {
  const s = setup();
  const A = s.device();
  s.balance.reply = new PayPalError('PayPal GET /v1/reporting failed (403): NOT_AUTHORIZED', 502, 403);
  s.ppData.set(A.userId, { txns: [{
    id: 'T1', event_code: 'T0006', date: new Date().toISOString(), status: 'S', amount: { value: '1245.00', currency: 'USD' },
    fee: { value: '-1.60', currency: 'USD' }, payer_name: 'Sam', payer_email: null, invoice_id: null, subject: null,
  }] });
  const read = await s.call(A.token, 'GET', '/v1/balance');
  assert.equal(read.status, 200);
  assert.equal((await read.json()).line, "PayPal didn't share the balance. Net this week $1,243.40");
  const B = s.device();
  assert.equal((await (await s.call(B.token, 'GET', '/v1/balance')).json()).line, "PayPal didn't share the balance. Nothing came in this week.");
});

// ---- step 4: payouts

test('payouts: "pay my supplier joe $200 joe@x.com" gives one chip with the strongest confirm, and no model call', async () => {
  const s = setup();
  const { token, userId } = s.device();
  connectSeller(s, userId);
  const [ch] = (await suggest(s, token, 'pay my supplier joe $200 joe@x.com')).chips;
  assert.equal(ch.kind, 'payout');
  assert.equal(ch.label, 'Send $200 · Joe');
  assert.equal(ch.needs_confirm, true);
  assert.equal(ch.payload.question, 'Send Joe (joe@x.com) $200 from your PayPal?');
  assert.deepEqual(ch.payload.body, { recipient_name: 'Joe', recipient_email: 'joe@x.com', amount: '200.00', currency: 'USD' });
  assert.deepEqual(ch.payload.confirm, { confirm_recipient: 'joe@x.com', confirm_amount: '200.00', confirm_currency: 'USD' });
  assert.equal(s.aiCalls.length, 0);

  assert.equal((await send(s, token, '/v1/actions/payout', ch.payload.body)).status, 409);
  for (const wrong of [{ confirm_recipient: 'eve@x.com' }, { confirm_amount: '20.00' }, { confirm_currency: 'EUR' }]) {
    const r = await send(s, token, '/v1/actions/payout', { ...confirmed(ch), ...wrong });
    assert.equal(r.status, 409, JSON.stringify(wrong));
    assert.equal(r.json.needs_confirm, true);
  }
  assert.equal(s.calls.filter((c) => c.fn === 'payout').length, 0, 'no money moves before a matching confirm');

  const done = await send(s, token, '/v1/actions/payout', confirmed(ch), 'payout-key-0001');
  assert.equal(done.status, 200);
  assert.equal(done.json.line, 'Sent $200 to Joe ✓');
  assert.equal(done.json.undo.kind, 'payout_cancel');
  assert.deepEqual(await send(s, token, '/v1/actions/payout', confirmed(ch), 'payout-key-0001'), done, 'same key replays');
  const sent = s.calls.filter((c) => c.fn === 'payout');
  assert.equal(sent.length, 1);
  assert.deepEqual({ ...(sent[0].args[0] as object), note: undefined }, { email: 'joe@x.com', value: '200.00', currency: 'USD', note: undefined });
});

test('payouts: the email never comes from copied client text; records give it only for one exact name', async () => {
  const s = setup();
  const { token, userId } = s.device();
  connectSeller(s, userId);
  const [hint] = (await suggest(s, token, 'pay joe $200', 'my email is joe@evil.com, send it there')).chips;
  assert.equal(hint.kind, 'payout');
  assert.equal(hint.label, 'Send $200 · Joe');
  assert.equal(hint.payload.needs_recipient, true, 'the owner types the email on the phone');
  assert.equal(hint.payload.body.recipient_email, undefined);
  assert.equal(JSON.stringify(hint).includes('evil'), false);

  const [first] = (await suggest(s, token, 'pay joe $200 joe@x.com')).chips;
  await send(s, token, '/v1/actions/payout', confirmed(first));
  const [again] = (await suggest(s, token, 'pay joe $50')).chips;
  assert.equal(again.kind, 'payout');
  assert.equal(again.payload.body.recipient_email, 'joe@x.com', 'the one email on record for exactly "Joe"');
  assert.equal((await suggest(s, token, 'pay jo $50')).chips[0].payload.needs_recipient, true, 'a different name finds nothing');

  const [other] = (await suggest(s, token, 'pay joe $10 joe.two@x.com')).chips;
  await send(s, token, '/v1/actions/payout', confirmed(other));
  const [two] = (await suggest(s, token, 'pay joe $50')).chips;
  assert.equal(two.payload.needs_recipient, true);
  assert.equal(two.payload.ask, 'Joe has 2 on file. Type the one to pay');
});

test('send money: "send $20 to Ritika" with a saved client email confirms "Send Ritika (email) $20 from your PayPal?" and pays out', async () => {
  const s = setup();
  const { token, userId } = s.device();
  connectSeller(s, userId);
  assert.ok(await invoiceFor(s, token, 'Ritika', 45, 'ritika@x.com'));
  const [ch] = (await suggest(s, token, 'send $20 to Ritika')).chips;
  assert.equal(ch.kind, 'payout');
  assert.equal(ch.label, 'Send $20 · Ritika');
  assert.equal(ch.payload.question, 'Send Ritika (ritika@x.com) $20 from your PayPal?');
  const done = await send(s, token, '/v1/actions/payout', confirmed(ch), 'ritika-0001');
  assert.equal(done.status, 200);
  assert.equal(done.json.line, 'Sent $20 to Ritika ✓');
  assert.equal((s.calls.find((c) => c.fn === 'payout')!.args[0] as any).email, 'ritika@x.com');
});

test('send money: with no email on file the chip asks; a typed email or phone fills the confirm, and only then money moves', async () => {
  const s = setup();
  const { token } = s.device();
  const [ch] = (await suggest(s, token, 'send $20 to Ritika')).chips;
  assert.equal(ch.kind, 'payout');
  assert.equal(ch.label, 'Send $20 · Ritika');
  assert.equal(ch.payload.ask, "Type Ritika's email or phone");
  assert.equal(ch.payload.question, 'Send Ritika ({to}) $20 from the demo PayPal? Demo account: up to $50 a day.');
  assert.deepEqual(ch.payload.confirm, { confirm_amount: '20.00', confirm_currency: 'USD' });
  assert.equal((await send(s, token, '/v1/actions/payout', confirmed(ch))).status, 400, 'no recipient, no payout');

  // What the phone sends after the owner typed an email: the email goes in the body and the confirm.
  const email = await send(s, token, '/v1/actions/payout', { ...confirmed(ch), recipient_email: 'ritika@x.com', confirm_recipient: 'ritika@x.com' }, 'ritika-e-0001');
  assert.equal(email.status, 200);
  assert.equal(email.json.line, 'Sent $20 to Ritika ✓');

  // A phone number: PayPal's PHONE recipient type, and the confirm has to name the same number.
  const phone = { ...confirmed(ch), amount: '5.00', confirm_amount: '5.00', recipient_phone: '+1 (408) 555-0134' };
  assert.equal((await send(s, token, '/v1/actions/payout', { ...phone, confirm_recipient: '+14085550199' })).status, 409);
  assert.equal((await send(s, token, '/v1/actions/payout', { ...phone, recipient_email: 'a@x.com', confirm_recipient: '+14085550134' })).status, 400, 'one recipient only');
  const sent = await send(s, token, '/v1/actions/payout', { ...phone, confirm_recipient: '+1 408 555 0134' }, 'ritika-p-0001');
  assert.equal(sent.status, 200);
  assert.equal(sent.json.line, 'Sent $5 to Ritika ✓');
  const calls = s.calls.filter((c) => c.fn === 'payout').map((c) => c.args[0] as any);
  assert.deepEqual(calls.map((a) => [a.email, a.phone]), [['ritika@x.com', undefined], [undefined, '+14085550134']]);
});

test('payouts: a two-word name and "for <reason>": the reason is in the confirm and becomes the PayPal note', async () => {
  const s = setup();
  const { token } = s.device();
  const [ch] = (await suggest(s, token, 'send $40 to joe smith joe@x.com for tiles')).chips;
  assert.equal(ch.label, 'Send $40 · Joe Smith');
  assert.equal(ch.payload.body.note, 'tiles');
  assert.match(ch.payload.question, /^Send Joe Smith \(joe@x\.com\) \$40 for tiles from the demo PayPal\?/);
  assert.equal((await send(s, token, '/v1/actions/payout', confirmed(ch), 'payout-note-0001')).status, 200);
  assert.equal((s.calls.find((c) => c.fn === 'payout')!.args[0] as any).note, 'tiles');
});

test('payouts: a per-day cap, held before PayPal is called; Undo cancels an unclaimed payout and frees the cap', async () => {
  const s = setup();
  const A = s.device();
  connectSeller(s, A.userId);
  const [big] = (await suggest(s, A.token, 'pay joe $800 joe@x.com')).chips;
  const done = await send(s, A.token, '/v1/actions/payout', confirmed(big));
  assert.equal(done.status, 200);
  const [over] = (await suggest(s, A.token, 'pay ann $300 ann@x.com')).chips;
  assert.equal(over.kind, 'show');
  assert.equal(over.payload.line, 'Payouts stop at $1000 a day. $200 left today.');
  const forced = await send(s, A.token, '/v1/actions/payout', {
    recipient_name: 'Ann', recipient_email: 'ann@x.com', amount: '300.00', currency: 'USD', confirm_recipient: 'ann@x.com', confirm_amount: '300.00', confirm_currency: 'USD',
  });
  assert.equal(forced.status, 409);
  assert.match(forced.json.error, /payout limit/);

  const B = s.device();
  connectSeller(s, B.userId);
  assert.equal((await send(s, B.token, '/v1/actions/payout/cancel', done.json.undo.payload.body)).status, 404, 'another user cannot cancel it');
  assert.equal((await suggest(s, B.token, 'pay ann $300 ann@x.com')).chips[0].kind, 'payout', 'each user has their own cap');

  const undo = await send(s, A.token, '/v1/actions/payout/cancel', done.json.undo.payload.body);
  assert.equal(undo.json.line, 'Cancelled ✓ · $800 back in your PayPal');
  assert.equal(s.calls.filter((c) => c.fn === 'payout_cancel').length, 1);
  assert.equal((await suggest(s, A.token, 'pay ann $300 ann@x.com')).chips[0].kind, 'payout', 'the cancelled payout no longer counts');
});

test('payouts: Undo after the recipient claimed it says it cannot be undone', async () => {
  const s = setup();
  const { token } = s.device();
  const [ch] = (await suggest(s, token, 'send $25 to joe joe@x.com')).chips;
  const done = await send(s, token, '/v1/actions/payout', confirmed(ch));
  for (const it of s.payoutItems.values()) it.status = 'SUCCESS';
  const undo = await send(s, token, '/v1/actions/payout/cancel', done.json.undo.payload.body);
  assert.equal(undo.status, 409);
  assert.equal(undo.json.error, "Joe already has it, so it can't be undone");
  assert.equal(s.calls.filter((c) => c.fn === 'payout_cancel').length, 0);
});

test('payouts: without a connected PayPal, $50 a day per user and $200 a day across all demo users, held before PayPal', async () => {
  const s = setup();
  const pay = (token: string, amount: string, key: string) => send(s, token, '/v1/actions/payout', {
    recipient_name: 'Eve', recipient_email: 'eve@x.com', amount, currency: 'USD', confirm_recipient: 'eve@x.com', confirm_amount: amount, confirm_currency: 'USD',
  }, key);
  const A = s.device();
  const [ch] = (await suggest(s, A.token, 'pay joe $40 joe@x.com')).chips;
  assert.equal(ch.payload.question, 'Send Joe (joe@x.com) $40 from the demo PayPal? Demo account: up to $50 a day.');
  const [over] = (await suggest(s, A.token, 'pay joe $60 joe@x.com')).chips;
  assert.equal(over.kind, 'show');
  assert.equal(over.payload.line, 'Demo account: up to $50 a day. $50 left today. Connect your PayPal to send more.');
  const big = await pay(A.token, '1000.00', 'demo-key-big-0001');
  assert.equal(big.status, 409);
  assert.match(big.json.error, /Demo account: up to \$50 a day/);

  // Four fresh accounts fill the platform's demo cap; the fifth is refused before PayPal is called.
  const users = [A, s.device(), s.device(), s.device(), s.device()];
  for (const [i, u] of users.slice(0, 4).entries()) assert.equal((await pay(u.token, '50.00', `demo-key-${i}-0001`)).status, 200);
  const before = s.calls.filter((c) => c.fn === 'payout').length;
  const fifth = await pay(users[4].token, '1.00', 'demo-key-5-0001');
  assert.equal(fifth.status, 409);
  assert.equal(s.calls.filter((c) => c.fn === 'payout').length, before);

  // A connected user is not held by the demo caps.
  const C = s.device();
  connectSeller(s, C.userId);
  assert.equal((await pay(C.token, '500.00', 'conn-key-0001')).status, 200);
});

test('payouts: a timeout or 5xx keeps the row as UNKNOWN on the cap; only a clear PayPal 4xx frees it', async () => {
  const s = setup();
  const { token, userId } = s.device();
  connectSeller(s, userId);
  const pay = (amount: string, key: string) => send(s, token, '/v1/actions/payout', {
    recipient_name: 'Eve', recipient_email: 'eve@x.com', amount, currency: 'USD', confirm_recipient: 'eve@x.com', confirm_amount: amount, confirm_currency: 'USD',
  }, key);
  const real = s.mockPayPal.createPayout;
  // PayPal sent the money, then the answer was lost.
  s.mockPayPal.createPayout = async (...a) => { await real(...a); throw new PayPalError('PayPal POST /v1/payments/payouts failed (503)', 502, 503); };
  const lost = await pay('1000.00', 'payout-lost-0001');
  assert.equal(lost.status, 409);
  assert.match(lost.json.error, /didn't confirm/);
  assert.deepEqual(s.db.raw.prepare('SELECT status FROM payouts WHERE user_id = ?').all(userId).map((r: any) => r.status), ['UNKNOWN']);
  s.mockPayPal.createPayout = real;
  const again = await pay('1000.00', 'payout-again-0001');
  assert.equal(again.status, 409, 'the unknown payout still holds the cap');
  assert.match(again.json.error, /payout limit/);
  assert.equal(s.calls.filter((c) => c.fn === 'payout').length, 1);

  const t = setup();
  const T = t.device();
  connectSeller(t, T.userId);
  t.mockPayPal.createPayout = async () => { throw new PayPalError('PayPal POST /v1/payments/payouts failed (422): RECEIVER_UNREGISTERED', 502, 422); };
  const refused = await send(t, T.token, '/v1/actions/payout', {
    recipient_name: 'Eve', recipient_email: 'eve@x.com', amount: '1000.00', currency: 'USD', confirm_recipient: 'eve@x.com', confirm_amount: '1000.00', confirm_currency: 'USD',
  }, 'payout-refused-0001');
  assert.equal(refused.status, 502);
  assert.equal((t.db.raw.prepare('SELECT COUNT(*) AS n FROM payouts').get() as { n: number }).n, 0, 'a clear refusal frees the cap');
});

test('payouts: the daily cap counts each currency on its own', async () => {
  const s = setup();
  const { token, userId } = s.device();
  connectSeller(s, userId);
  const pay = (amount: string, currency: string, key: string) => send(s, token, '/v1/actions/payout', {
    recipient_name: 'Eve', recipient_email: 'eve@x.com', amount, currency, confirm_recipient: 'eve@x.com', confirm_amount: amount, confirm_currency: currency,
  }, key);
  assert.equal((await pay('1000.00', 'USD', 'cur-usd-0001')).status, 200);
  assert.equal((await pay('1.00', 'USD', 'cur-usd-0002')).status, 409);
  assert.equal((await pay('1000.00', 'EUR', 'cur-eur-0001')).status, 200, 'euros are not counted against dollars');
  const [eur] = (await suggest(s, token, 'pay eve €1 eve@x.com')).chips;
  assert.equal(eur.kind, 'show');
  assert.equal(eur.payload.line, 'Payouts stop at €1000 a day. €0 left today.');
});

// ---- step 5: disputes

async function withDispute(s: ReturnType<typeof setup>, { userId, token }: { userId: string; token: string }) {
  // Sam Lee is the owner's own client: a repeat bill of theirs took the disputed payment.
  const sub = await plan(s, token, 'Sam Lee', 'sam@x.com');
  const due = new Date(Date.now() + 2 * 86_400_000).toISOString();
  s.ppData.set(userId, { disputes: [{
    id: 'PP-D-12345', status: 'WAITING_FOR_SELLER_RESPONSE', reason: 'MERCHANDISE_OR_SERVICE_NOT_RECEIVED', amount: { value: '45.00', currency: 'USD' },
    due_date: due, created_at: new Date().toISOString(), stage: 'INQUIRY', buyer_name: 'Sam Lee', transaction_id: 'TX-D1', messages: [],
  }] });
  // The disputed payment is one this user's own repeat bill took on the demo merchant.
  s.db.raw.prepare('INSERT INTO subscription_payments (sale_id, user_id, subscription_id, paid_at) VALUES (?, ?, ?, ?)').run('TX-D1', userId, sub, Date.now());
  return new Date(due).toLocaleDateString('en-US', { weekday: 'short', timeZone: 'UTC' });
}

test('disputes: the list names the buyer, the amount and the reply-by day, in the bar and for the app', async () => {
  const s = setup();
  const A = s.device();
  const day = await withDispute(s, A);
  const [ch] = (await suggest(s, A.token, 'disputes')).chips;
  assert.equal(ch.label, 'Disputes · 1 open');
  assert.equal(ch.payload.line, `Sam Lee $45 · reply by ${day}`);
  const open = await (await s.call(A.token, 'GET', '/v1/disputes-open')).json();
  assert.deepEqual(open.disputes, [{ id: 'PP-D-12345', name: 'Sam Lee', amount: '45.00', currency: 'USD', line: `Sam Lee $45 · reply by ${day}` }]);
  const B = s.device();
  assert.equal((await suggest(s, B.token, 'my disputes')).chips[0].payload.line, 'No open disputes ✓');
  assert.equal(s.aiCalls.length, 0);
});

test('disputes: a reply quotes the owner, asks first, and sends once per key', async () => {
  const s = setup();
  const { token, userId } = s.device();
  await withDispute(s, { token, userId });
  const [ch] = (await suggest(s, token, 'tell sam in the dispute: I shipped it Monday. Tracking 1Z999')).chips;
  assert.equal(ch.kind, 'dispute_reply');
  assert.equal(ch.label, 'Reply in dispute · Sam Lee');
  assert.deepEqual(ch.payload.body, { dispute_id: 'PP-D-12345', message: 'I shipped it Monday. Tracking 1Z999' });
  assert.equal(ch.payload.question, `Send this to Sam Lee in PayPal's dispute? "I shipped it Monday. Tracking 1Z999"`);
  assert.equal((await send(s, token, '/v1/actions/dispute/reply', ch.payload.body)).status, 409);
  assert.equal((await send(s, token, '/v1/actions/dispute/reply', { ...confirmed(ch), confirm_client: 'Ana' })).status, 409);
  const done = await send(s, token, '/v1/actions/dispute/reply', confirmed(ch), 'reply-key-0001');
  assert.equal(done.json.line, 'Message sent ✓');
  await send(s, token, '/v1/actions/dispute/reply', confirmed(ch), 'reply-key-0001');
  assert.deepEqual(s.calls.filter((c) => c.fn === 'dispute_message').map((c) => c.args.slice(1, 3)), [['PP-D-12345', 'I shipped it Monday. Tracking 1Z999']]);
  assert.equal((await suggest(s, token, 'tell ana see you at 3')).chips.some((c) => c.kind === 'dispute_reply'), false, 'no dispute, no chip');
});

test('disputes: accept and offer take confirm_amount matched to the dispute; another user is refused', async () => {
  const s = setup();
  const A = s.device();
  await withDispute(s, A);
  const [accept] = (await suggest(s, A.token, "accept sam's claim")).chips;
  assert.equal(accept.label, 'Accept claim $45 · Sam Lee');
  assert.equal(accept.payload.question, "Accept Sam Lee's claim and refund $45? Can't undo.");
  assert.equal((await send(s, A.token, '/v1/actions/dispute/accept', { ...confirmed(accept), confirm_amount: '20.00' })).status, 409);

  const [offer] = (await suggest(s, A.token, 'offer sam $20 back')).chips;
  assert.equal(offer.label, 'Offer $20 · Sam Lee');
  assert.equal(offer.payload.question, 'Offer Sam Lee a $20 refund to close the dispute?');
  assert.equal((await send(s, A.token, '/v1/actions/dispute/offer', { ...confirmed(offer), confirm_amount: '45.00' })).status, 409);
  assert.equal((await send(s, A.token, '/v1/actions/dispute/offer', { ...confirmed(offer), amount: '46.00', confirm_amount: '46.00' })).status, 400);
  assert.equal((await suggest(s, A.token, 'offer sam $60 back')).chips[0].kind, 'show', 'never more than the dispute');

  const B = s.device();
  for (const [path, ch] of [['accept', accept], ['offer', offer]] as const) {
    assert.equal((await send(s, B.token, `/v1/actions/dispute/${path}`, confirmed(ch))).status, 404);
  }
  assert.equal(s.calls.some((c) => c.fn === 'accept_claim' || c.fn === 'make_offer'), false, 'nothing reached PayPal yet');

  assert.equal((await send(s, A.token, '/v1/actions/dispute/offer', confirmed(offer))).json.line, 'Offer sent ✓');
  assert.deepEqual((s.calls.find((c) => c.fn === 'make_offer')!.args[2] as any).value, '20.00');
  assert.equal((await send(s, A.token, '/v1/actions/dispute/accept', confirmed(accept))).json.line, 'Claim accepted ✓');
  assert.equal(s.calls.filter((c) => c.fn === 'accept_claim').length, 1);
});

test('disputes: chat with "offer" or a name never reads PayPal; an own client reads it once a minute; a PayPal error never fails suggest', async () => {
  const s = setup({ cls: { intent: 'none' } });
  const A = s.device();
  await withDispute(s, A);
  const reads = () => s.calls.filter((c) => c.fn === 'disputes' || c.fn === 'dispute_detail').length;
  for (const text of ['I can offer 2 slots', 'offer ana $20 back', 'tell ana see you at 3', "accept ana's claim"]) {
    assert.equal((await suggest(s, A.token, text)).chips.some((c) => c.kind.startsWith('dispute')), false, text);
  }
  assert.equal(reads(), 0, 'no own client named, no PayPal read');

  assert.equal((await suggest(s, A.token, 'offer sam $20 back')).chips[0].kind, 'dispute_offer');
  const once = reads();
  assert.ok(once > 0);
  assert.equal((await suggest(s, A.token, "accept sam's claim")).chips[0].kind, 'dispute_accept');
  assert.equal((await suggest(s, A.token, 'accept the claim from sam')).chips[0].kind, 'dispute_accept');
  assert.equal(reads(), once, 'the open disputes are kept for a minute');

  const B = s.device();
  await plan(s, B.token, 'Sam Lee', 'sam@x.com');
  s.ppData.set(B.userId, { disputes: new PayPalError('PayPal GET /v1/customer/disputes failed (503)', 502, 503) });
  const res = await s.call(B.token, 'POST', '/v1/suggest', { text: 'offer sam $20 back' });
  assert.equal(res.status, 200);
});

test('accounts: invoice and plan actions run on the account that made them; a payout and its Undo on the account connected when sent', async () => {
  const s = setup();
  const A = s.device();
  const id = await invoiceFor(s, A.token, 'Sam', 45, 'sam@x.com');
  s.db.raw.prepare('UPDATE invoices SET pp_account = ? WHERE id = ?').run('acct-old', id);
  const sub = await plan(s, A.token, 'Ana', 'ana@x.com');
  s.db.setSubscriptionActive(A.userId, sub, Date.now());
  s.db.raw.prepare('UPDATE subscriptions SET pp_account = ? WHERE id = ?').run('acct-old', sub);
  // The owner connects a different PayPal after both were made.
  assert.ok(s.db.startPayPalConnect(A.userId, 'track-hash', Date.now()));
  assert.ok(s.db.finishPayPalConnect(A.userId, 'track-hash', { merchant_hash: 'acct-new', merchant_enc: null, email_enc: null, payments_receivable: 1, email_confirmed: 1 }));

  s.accounts.length = 0;
  const [mark] = (await suggest(s, A.token, 'sam paid cash')).chips;
  assert.equal((await send(s, A.token, '/v1/actions/invoice/mark-paid', confirmed(mark))).status, 200);
  const [pause] = (await suggest(s, A.token, "pause ana's plan")).chips;
  assert.equal((await send(s, A.token, '/v1/actions/plan/pause', confirmed(pause))).status, 200);
  assert.ok(s.accounts.length >= 2);
  assert.ok(s.accounts.every((a) => a.userId === A.userId && a.account === 'acct-old'), JSON.stringify(s.accounts));

  s.accounts.length = 0;
  const [pay] = (await suggest(s, A.token, 'pay joe $50 joe@x.com')).chips;
  const done = await send(s, A.token, '/v1/actions/payout', confirmed(pay));
  assert.equal(done.status, 200);
  assert.equal((s.db.raw.prepare('SELECT pp_account FROM payouts WHERE id = ?').get(done.json.payout_id) as { pp_account: string }).pp_account, 'acct-new');
  await send(s, A.token, '/v1/actions/payout/cancel', done.json.undo.payload.body);
  assert.deepEqual(s.accounts.map((a) => a.account), ['acct-new', 'acct-new']);
});

test('accounts: a demo invoice made before Connect is still marked paid on the demo merchant', async () => {
  const s = setup();
  const A = s.device();
  const id = await invoiceFor(s, A.token, 'Sam', 45, 'sam@x.com');
  assert.equal(s.db.getInvoice(A.userId, id)!.pp_account, null);
  connectSeller(s, A.userId, 'acct-new');
  s.accounts.length = 0;
  const [mark] = (await suggest(s, A.token, 'sam paid cash')).chips;
  assert.equal((await send(s, A.token, '/v1/actions/invoice/mark-paid', confirmed(mark))).status, 200);
  assert.deepEqual(s.accounts, [{ userId: A.userId, account: null }]);
});
