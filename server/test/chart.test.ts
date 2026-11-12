import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildChart, monthStart, monthWindows, project, projectRange, zoneOr } from '../src/chart.ts';
import { chartAsk } from '../src/quick.ts';
import type { PayPalTxn } from '../src/paypal.ts';
import { setup } from './helpers.ts';

// 2026-11-12 10:00 UTC: November is the month so far; October is the last full month.
const AT = Date.UTC(2026, 10, 12, 10);
const sale = (id: string, date: string, value: string, currency = 'USD', event_code = 'T0006'): PayPalTxn => ({
  id, event_code, date, status: 'S', amount: { value, currency }, fee: null, payer_name: null, payer_email: null, invoice_id: null, subject: null,
});

const STATUS: Record<string, string> = { S: 'COMPLETED', P: 'PENDING', V: 'REVERSED', D: 'DENIED', F: 'PARTIALLY_REFUNDED' };
const row = (t: PayPalTxn) => ({ date: t.date, amount: t.amount.value, currency: t.amount.currency, status: STATUS[t.status], refund: t.event_code.startsWith('T11') });
const withStatus = (t: PayPalTxn, status: string) => ({ ...t, status });

// ---- intent

test('chart intent: the asked phrasings get a chart, with months back and ahead read from the words', () => {
  assert.deepEqual(chartAsk('chart?'), { kind: 'bar', back: 6, ahead: 3 });
  assert.deepEqual(chartAsk('graph my projections'), { kind: 'bar', back: 6, ahead: 3 });
  assert.deepEqual(chartAsk('bar chart of last 6 months'), { kind: 'bar', back: 6, ahead: 3 });
  assert.deepEqual(chartAsk('bar chart of my sales'), { kind: 'bar', back: 6, ahead: 3 });
  assert.deepEqual(chartAsk('show revenue next 3 months'), { kind: 'bar', back: 6, ahead: 3 });
  assert.deepEqual(chartAsk('line graph of income for the past 4 months'), { kind: 'line', back: 4, ahead: 3 });
  assert.deepEqual(chartAsk('show my sales for the next two months'), { kind: 'bar', back: 6, ahead: 2 });
  for (const t of ['Graph', 'a chart please', 'sales forecast', 'projections?', 'how are sales trending', 'can you plot my earnings',
    'ok cool. chart of my revenue by month', 'Forecast revenue', 'plot last 3 months']) {
    assert.ok(chartAsk(t), t);
  }
  // Limits: at most 12 months back and 6 ahead, at least 2 back.
  assert.deepEqual(chartAsk('chart sales last 40 months, next 9 months'), { kind: 'bar', back: 12, ahead: 6 });
  assert.equal(chartAsk('bar chart of last 1 month')?.back, 2);
});

test('chart intent: chat about charts, graphs and sales is not a chart ask', () => {
  for (const t of ['I sent your chart this morning', 'the graph in your deck looks great', 'charting a course for the weekend',
    'we had a sale on haircuts', 'can you send me the plot of land address', 'invoice sam $45 for the haircut', 'hey how are you',
    'show me the blue one', 'is that on sale?', 'the logo chart colors are off']) {
    assert.equal(chartAsk(t), null, t);
  }
});

test('chart intent: /v1/suggest offers one chart chip with no model call; the Ask bar does not', async () => {
  const s = setup();
  const { token } = s.device();
  for (const text of ['chart?', 'graph my projections', 'bar chart of last 6 months', 'show revenue next 3 months']) {
    const out = await (await s.call(token, 'POST', '/v1/suggest', { text })).json();
    assert.equal(out.chips.length, 1, text);
    assert.equal(out.chips[0].kind, 'chart');
    assert.equal(out.chips[0].needs_confirm, false);
    assert.deepEqual(Object.keys(out.chips[0].payload).sort(), ['ahead', 'back', 'kind']);
  }
  assert.equal(s.aiCalls.length, 0);
  const ask = await (await s.call(token, 'POST', '/v1/ask', { text: 'chart?' })).json();
  assert.equal(JSON.stringify(ask).includes('"chart"'), false);
});

// ---- projection math

test('projection: a straight line through the history, continued with the gap', () => {
  // 100, 200, 300: slope 100. The next point is 400; two steps on is 500.
  assert.deepEqual(project([100, 200, 300], 3), [400, 500, 600]);
  assert.deepEqual(project([100, 200, 300], 2, 2), [500, 600]);
  // A flat history stays flat.
  assert.deepEqual(project([5000, 5000], 3), [5000, 5000, 5000]);
  // Least squares, not the last two points: 100, 300, 200 has slope 50 and mean 200 at x = 1.
  assert.deepEqual(project([100, 300, 200], 1), [300]);
});

test('projection: never below zero, only the last 6 months count, and under 2 months gives none', () => {
  assert.deepEqual(project([900, 600, 300], 3), [0, 0, 0]);
  // Old months beyond 6 do not count: the last six are flat at 100.
  assert.deepEqual(project([99999, 99999, 100, 100, 100, 100, 100, 100], 1), [100]);
  assert.equal(project([500], 3), null);
  assert.equal(project([], 3), null);
});

test('monthWindows: one window per calendar month, each under 31 days, the last ending now', () => {
  const w = monthWindows(Date.UTC(2026, 7, 1), AT);
  assert.equal(w.length, 4);
  assert.equal(new Date(w[0][0]).toISOString(), '2026-08-01T00:00:00.000Z');
  assert.equal(new Date(w[3][1]).toISOString(), '2026-11-12T09:59:59.000Z');
  for (const [a, b] of w) assert.ok(b - a < 31 * 86_400_000);
});

test('buildChart: monthly actuals, the month so far, and dashed estimates from the trend', () => {
  const txns = [
    sale('a', '2026-08-03T10:00:00Z', '100.00'), sale('b', '2026-09-10T10:00:00Z', '150.00'), sale('c', '2026-09-20T10:00:00Z', '50.00'),
    sale('d', '2026-10-05T10:00:00Z', '300.00'), sale('e', '2026-11-02T10:00:00Z', '45.00'),
    // Money out and other currencies do not count toward USD money in.
    sale('f', '2026-10-06T10:00:00Z', '-80.00'), sale('g', '2026-10-07T10:00:00Z', '20.00', 'EUR'),
  ].map(row);
  const c = buildChart(txns, { at: AT, back: 6, ahead: 3, currency: 'USD' });
  assert.equal(c.currency, 'USD');
  assert.deepEqual(c.months.map((m) => [m.label, m.value, m.kind]), [
    ['May', '0.00', 'actual'], ['Jun', '0.00', 'actual'], ['Jul', '0.00', 'actual'],
    ['Aug', '100.00', 'actual'], ['Sep', '200.00', 'actual'], ['Oct', '300.00', 'actual'],
    ['Nov', '45.00', 'partial'],
    // History is Aug..Oct (the empty months before the first sale are not history). Trend +100/month, Nov skipped.
    ['Dec', '500.00', 'estimate'], ['Jan', '600.00', 'estimate'], ['Feb', '700.00', 'estimate'],
  ]);
  assert.deepEqual(c.projection, { method: 'straight_line_trend', based_on_months: 3, range: { level: 0.8, method: 'residual_sd' } });
  // A perfect line has no spread: the range is the estimate itself.
  assert.deepEqual(c.months.filter((m) => m.kind === 'estimate').map((m) => [m.low, m.value, m.high]),
    [['500.00', '500.00', '500.00'], ['600.00', '600.00', '600.00'], ['700.00', '700.00', '700.00']]);
  assert.equal(c.enough_history, true);
  assert.match(c.caption, /estimate/i);
  assert.match(c.caption, /Not a promise/);
});

test('buildChart: only completed sales count, refunds come off their month, and a month never goes below 0', () => {
  const rows = [
    sale('a', '2026-09-03T10:00:00Z', '500.00'),
    withStatus(sale('b', '2026-09-04T10:00:00Z', '900.00'), 'P'), withStatus(sale('c', '2026-09-05T10:00:00Z', '900.00'), 'D'),
    withStatus(sale('d', '2026-09-06T10:00:00Z', '900.00'), 'V'),
    // A partly refunded sale was completed; its refund is its own row.
    withStatus(sale('e', '2026-10-03T10:00:00Z', '400.00'), 'F'), sale('f', '2026-10-09T10:00:00Z', '-150.00', 'USD', 'T1107'),
    // November: refunds bigger than sales.
    sale('g', '2026-11-02T10:00:00Z', '50.00'), sale('h', '2026-11-03T10:00:00Z', '-80.00', 'USD', 'T1107'),
  ].map(row);
  const c = buildChart(rows, { at: AT, back: 3, ahead: 1, currency: 'USD' });
  assert.deepEqual(c.months.map((m) => [m.label, m.value]), [['Aug', '0.00'], ['Sep', '500.00'], ['Oct', '250.00'], ['Nov', '0.00'], ['Dec', '0.00']]);
});

test('buildChart: the profile currency wins over a bigger one, and the caption names what is left out', () => {
  const rows = [
    sale('a', '2026-09-03T10:00:00Z', '100.00'), sale('b', '2026-10-03T10:00:00Z', '200.00'),
    sale('c', '2026-09-03T10:00:00Z', '9000.00', 'EUR'), sale('d', '2026-10-03T10:00:00Z', '5.00', 'GBP'),
  ].map(row);
  const usd = buildChart(rows, { at: AT, back: 3, ahead: 1, currency: 'USD' });
  assert.equal(usd.currency, 'USD');
  assert.match(usd.caption, /Sales in EUR, GBP are left out\./);
  // No sales in the profile currency: the currency with the most sales (by count, not by size) is shown.
  const gbp = [...rows.slice(2), row(sale('e', '2026-08-03T10:00:00Z', '5.00', 'GBP'))];
  const c = buildChart(gbp, { at: AT, back: 3, ahead: 1, currency: 'CAD' });
  assert.equal(c.currency, 'GBP');
  assert.match(c.caption, /Sales in EUR are left out\./);
  assert.equal(buildChart(rows.slice(0, 2), { at: AT, back: 3, ahead: 1, currency: 'USD' }).caption.includes('left out'), false);
});

test('buildChart: under 2 full months of history says so and shows no estimate', () => {
  const only = [sale('a', '2026-10-05T10:00:00Z', '300.00'), sale('b', '2026-11-02T10:00:00Z', '45.00')].map(row);
  const c = buildChart(only, { at: AT, back: 6, ahead: 3, currency: 'USD' });
  assert.equal(c.projection, null);
  assert.equal(c.enough_history, false);
  assert.equal(c.months.some((m) => m.kind === 'estimate'), false);
  assert.match(c.caption, /Not enough history/);
  const none = buildChart([], { at: AT, back: 6, ahead: 3, currency: 'EUR' });
  assert.equal(none.currency, 'EUR');
  assert.equal(none.enough_history, false);
});

// ---- endpoint

test('/v1/chart: reads PayPal one month per query, drops repeats, and never moves money', async () => {
  const s = setup({ now: () => AT });
  const { userId, token } = s.device();
  s.ppData.set(userId, { txns: [sale('a', '2026-09-10T10:00:00Z', '200.00'), sale('b', '2026-10-05T10:00:00Z', '300.00')] });
  const r = await s.call(token, 'GET', '/v1/chart?back=3&ahead=2');
  assert.equal(r.status, 200);
  const c = await r.json();
  assert.equal(c.source, 'paypal');
  assert.deepEqual(c.months.map((m: any) => m.value), ['0.00', '200.00', '300.00', '0.00', '500.00', '600.00']);
  const searches = s.calls.filter((x) => x.fn === 'search');
  // Aug, Sep, Oct and November so far: four queries, each within one month.
  assert.equal(searches.length, 4);
  for (const x of searches) assert.ok((x.args[2] as Date).getTime() - (x.args[1] as Date).getTime() < 31 * 86_400_000);
  assert.deepEqual(s.calls.filter((x) => x.fn !== 'search'), []);
});

test('/v1/chart: a denied PayPal payment does not count, a PayPal refund comes off, money sent out is ignored', async () => {
  const s = setup({ now: () => AT });
  const { userId, token } = s.device();
  s.ppData.set(userId, { txns: [
    sale('a', '2026-10-05T10:00:00Z', '300.00'), withStatus(sale('b', '2026-10-06T10:00:00Z', '700.00'), 'D'),
    sale('c', '2026-10-07T10:00:00Z', '-100.00', 'USD', 'T1107'), sale('d', '2026-10-08T10:00:00Z', '-50.00', 'USD', 'T0000'),
    sale('e', '2026-10-09T10:00:00Z', '999.00', 'USD', 'T1900'),
  ] });
  const c = await (await s.call(token, 'GET', '/v1/chart?back=2&ahead=1')).json();
  assert.equal(c.months.find((m: any) => m.label === 'Oct').value, '200.00');
});

test('/v1/chart: needs the device token, checks its query, and falls back to local records when PayPal fails', async () => {
  const s = setup({ now: () => AT });
  const { userId, token } = s.device();
  assert.equal((await s.call(null, 'GET', '/v1/chart')).status, 401);
  assert.equal((await s.call(token, 'GET', '/v1/chart?back=99')).status, 400);
  s.ppData.set(userId, { txns: new Error('PayPal down') });
  const c = await (await s.call(token, 'GET', '/v1/chart')).json();
  assert.equal(c.source, 'local');
  assert.equal(c.note, 'paypal_error');
  assert.equal(c.enough_history, false);
});

// ---- audit fixes

test('buildChart: a T11 adjustment keeps its sign, so a hold and its release net to 0, and a fee reversal adds back', () => {
  const rows = [
    sale('a', '2026-10-03T10:00:00Z', '500.00'),
    sale('h', '2026-10-04T10:00:00Z', '-200.00', 'USD', 'T1110'), sale('r', '2026-10-09T10:00:00Z', '200.00', 'USD', 'T1111'),
    sale('f', '2026-10-10T10:00:00Z', '3.00', 'USD', 'T1108'),
  ].map(row);
  const c = buildChart(rows, { at: AT, back: 2, ahead: 1, currency: 'USD' });
  assert.equal(c.months.find((m) => m.label === 'Oct')?.value, '503.00');
});

test('/v1/chart: a reversed sale comes off once, not again through its T1106 row', async () => {
  const s = setup({ now: () => AT });
  const { userId, token } = s.device();
  s.ppData.set(userId, { txns: [
    sale('a', '2026-10-05T10:00:00Z', '500.00'), withStatus(sale('b', '2026-10-06T10:00:00Z', '300.00'), 'V'),
    sale('c', '2026-10-08T10:00:00Z', '-300.00', 'USD', 'T1106'),
  ] });
  const c = await (await s.call(token, 'GET', '/v1/chart?back=2&ahead=1')).json();
  assert.equal(c.months.find((m: any) => m.label === 'Oct').value, '500.00');
});

test('months follow the owner time zone: a sale late on Oct 31 in Los Angeles is October', () => {
  const late = [sale('a', '2026-11-01T03:00:00Z', '100.00')].map(row);
  const la = buildChart(late, { at: AT, back: 2, ahead: 1, currency: 'USD', tz: 'America/Los_Angeles' });
  assert.equal(la.months.find((m) => m.label === 'Oct')?.value, '100.00');
  assert.equal(la.months.find((m) => m.label === 'Nov')?.value, '0.00');
  const utc = buildChart(late, { at: AT, back: 2, ahead: 1, currency: 'USD' });
  assert.equal(utc.months.find((m) => m.label === 'Nov')?.value, '100.00');
  // Months start at local midnight: Aug 1 in Los Angeles is 07:00 UTC (PDT); Dec 1 is 08:00 UTC (PST).
  assert.equal(new Date(monthStart(AT, -3, 'America/Los_Angeles')).toISOString(), '2026-08-01T07:00:00.000Z');
  assert.equal(new Date(monthStart(AT, 1, 'America/Los_Angeles')).toISOString(), '2026-12-01T08:00:00.000Z');
  assert.equal(new Date(monthWindows(Date.UTC(2026, 9, 15), AT, 'Asia/Kolkata')[0][0]).toISOString(), '2026-09-30T18:30:00.000Z');
  assert.equal(zoneOr('Not/AZone'), 'UTC');
  assert.equal(zoneOr(undefined), 'UTC');
  assert.notEqual(zoneOr('Asia/Kolkata'), 'UTC');
});

test('/v1/chart: ?tz= groups by the owner zone; an unknown zone falls back to UTC', async () => {
  const s = setup({ now: () => AT });
  const { userId, token } = s.device();
  s.ppData.set(userId, { txns: [sale('a', '2026-11-01T03:00:00Z', '100.00')] });
  const la = await (await s.call(token, 'GET', '/v1/chart?back=2&ahead=1&tz=America%2FLos_Angeles')).json();
  assert.equal(la.months.find((m: any) => m.label === 'Oct').value, '100.00');
  const bad = await s.call(token, 'GET', '/v1/chart?back=2&ahead=1&tz=Not%2FAZone');
  assert.equal(bad.status, 200);
  assert.equal((await bad.json()).months.find((m: any) => m.label === 'Nov').value, '100.00');
});

test('/v1/chart: history is cached for 10 minutes and forgotten on a PayPal disconnect', async () => {
  let t = AT;
  const s = setup({ now: () => t });
  const { userId, token } = s.device();
  s.ppData.set(userId, { txns: [sale('a', '2026-10-05T10:00:00Z', '300.00')] });
  const searches = () => s.calls.filter((x) => x.fn === 'search').length;
  await s.call(token, 'GET', '/v1/chart?back=2&ahead=1');
  const first = searches();
  assert.ok(first > 0);
  t += 5 * 60_000;
  await s.call(token, 'GET', '/v1/chart?back=2&ahead=1');
  assert.equal(searches(), first, 'cached within 10 minutes');
  t += 6 * 60_000;
  await s.call(token, 'GET', '/v1/chart?back=2&ahead=1');
  assert.equal(searches(), 2 * first, 'read again after 10 minutes');
  await s.call(token, 'POST', '/v1/paypal/disconnect');
  await s.call(token, 'GET', '/v1/chart?back=2&ahead=1');
  assert.equal(searches(), 3 * first, 'a disconnect drops the cached months');
});

// ---- uncertainty range

test('projectRange: brackets the estimate, widens with each month ahead, and never goes below 0', () => {
  const history = [100_000, 160_000, 120_000, 190_000, 150_000, 210_000];
  const est = project(history, 3, 2)!;
  const r = projectRange(history, 3, 2)!;
  assert.equal(r.length, 3);
  const widths = r.map((x) => x.high - x.low);
  for (let i = 0; i < 3; i++) assert.ok(r[i].low <= est[i] && est[i] <= r[i].high, `month ${i}`);
  assert.ok(widths[0] > 0 && widths[0] < widths[1] && widths[1] < widths[2], `widths ${widths}`);
  // A falling, noisy trend near 0: low is floored at 0.
  const falling = projectRange([90_000, 40_000, 60_000, 10_000], 3, 2)!;
  for (const x of falling) assert.ok(x.low >= 0 && x.high >= x.low);
  assert.equal(falling[2].low, 0);
});

test('projectRange: none under 3 full months, and no range fields then', () => {
  assert.equal(projectRange([100, 200], 3), null);
  assert.equal(projectRange([], 3), null);
  const two = [sale('a', '2026-09-03T10:00:00Z', '100.00'), sale('b', '2026-10-03T10:00:00Z', '300.00')].map(row);
  const c = buildChart(two, { at: AT, back: 6, ahead: 3, currency: 'USD' });
  assert.equal(c.enough_history, true, 'two months still give an estimate');
  assert.equal(c.projection?.range, undefined);
  for (const m of c.months) assert.ok(!('low' in m) && !('high' in m), m.label);
});

test('/v1/chart: estimate months carry low and high strings; actual months do not', async () => {
  const s = setup({ now: () => AT });
  const { userId, token } = s.device();
  s.ppData.set(userId, { txns: [
    sale('a', '2026-07-05T10:00:00Z', '1000.00'), sale('b', '2026-08-05T10:00:00Z', '1600.00'),
    sale('c', '2026-09-05T10:00:00Z', '1200.00'), sale('d', '2026-10-05T10:00:00Z', '1900.00'),
  ] });
  const c = await (await s.call(token, 'GET', '/v1/chart?back=4&ahead=2')).json();
  const est = c.months.filter((m: any) => m.kind === 'estimate');
  assert.equal(est.length, 2);
  for (const m of est) assert.ok(Number(m.low) <= Number(m.value) && Number(m.value) <= Number(m.high) && Number(m.low) >= 0, JSON.stringify(m));
  assert.ok(Number(est[1].high) - Number(est[1].low) > Number(est[0].high) - Number(est[0].low));
  for (const m of c.months.filter((m: any) => m.kind !== 'estimate')) assert.equal(m.low, undefined);
  assert.deepEqual(c.projection.range, { level: 0.8, method: 'residual_sd' });
});
