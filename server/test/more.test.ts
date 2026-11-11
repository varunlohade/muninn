import { test } from 'node:test';
import assert from 'node:assert/strict';
import { payoutAsk } from '../src/quick.ts';
import { PayPalError } from '../src/paypal.ts';
import { paidEvent, setup, webhookHeaders } from './helpers.ts';

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
  assert.deepEqual(payoutAsk('pay my supplier joe $200 joe@x.com'), { name: 'Joe', amount: 200, currency: null, email: 'joe@x.com' });
  assert.deepEqual(payoutAsk('send $200 to joe'), { name: 'Joe', amount: 200, currency: null, email: null });
  for (const t of ['pay me $45', 'send sam a $45 invoice', 'send you the $45 link', 'pay joe', 'can you pay $45 by friday']) assert.equal(payoutAsk(t), null, t);
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
  const two = (await suggest(s, token, "cancel ana's invoice")).chips[0];
  assert.equal(two.kind, 'show');
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
