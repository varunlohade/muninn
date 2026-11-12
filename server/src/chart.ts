// Money in by month, with an estimate for the months ahead. The estimate is a straight line through the last
// full months (least squares), so the owner can check it by eye. It is always marked "estimate", never shown as fact.
import { centsToValue, valueToCents } from './money.ts';

const MONTH_NAMES = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** The trend uses at most this many full months, so an old season does not steer it. */
export const TREND_MONTHS = 6;
/** An estimate needs at least this many full months with sales history. */
export const MIN_HISTORY = 2;

/** `low` / `high`: only on an estimate month with enough history, the likely range around `value` (about 80%). */
export type ChartMonth = { month: string; label: string; value: string; kind: 'actual' | 'partial' | 'estimate'; low?: string; high?: string };
export type ChartData = {
  title: string; currency: string; months: ChartMonth[];
  /** `range`: present when the estimate months carry low / high (about 80%, from the fit's residual spread). */
  projection: { method: 'straight_line_trend'; based_on_months: number; range?: { level: number; method: 'residual_sd' } } | null;
  /** One plain line under the chart: how the estimate was made, or why there is none. */
  caption: string;
  enough_history: boolean;
};
/**
 * One payment or adjustment. `refund`: a PayPal T11xx adjustment (a refund, a hold, its release, a fee reversal) or a refund
 * Muninn ran. Its amount is signed as PayPal gives it: money out negative, money back positive. Status as in /v1/transactions.
 */
export type ChartRow = { date: string; amount: string; currency: string; status: string; refund: boolean };
/** A sale counts once it completed. A partly refunded sale was completed; its refund is its own row and comes off. */
const COUNTED = new Set(['COMPLETED', 'PARTIALLY_REFUNDED']);

/** The zone when it is a valid IANA name, else UTC. */
export function zoneOr(tz: string | undefined | null): string {
  if (!tz) return 'UTC';
  try {
    return new Intl.DateTimeFormat('en-US', { timeZone: tz }).resolvedOptions().timeZone;
  } catch {
    return 'UTC';
  }
}

/** The wall-clock date and time in `tz` at instant `t`. */
function wallClock(t: number, tz: string) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric',
  }).formatToParts(t).map((x) => [x.type, Number(x.value)]));
  return { y: p.year, m: p.month - 1, d: p.day, h: p.hour, min: p.minute, s: p.second };
}

/** How far the wall clock in `tz` is ahead of UTC at instant `t`, in ms. */
function offsetAt(t: number, tz: string) {
  const w = wallClock(t, tz);
  return Date.UTC(w.y, w.m, w.d, w.h, w.min, w.s) - Math.floor(t / 1000) * 1000;
}

/** The first instant of the month (in `tz`, UTC by default) `offset` months from the one holding `at`. */
export function monthStart(at: number, offset = 0, tz = 'UTC'): number {
  const w = wallClock(at, tz);
  const midnight = Date.UTC(w.y, w.m + offset, 1);
  // Two passes: across a DST change the offset at midnight can differ from the first guess's offset.
  return midnight - offsetAt(midnight - offsetAt(midnight, tz), tz);
}

/** One [start, end] per calendar month (in `tz`) from `since` to `at`. Each is under 31 days, the Transaction Search limit. */
export function monthWindows(since: number, at: number, tz = 'UTC'): [number, number][] {
  const out: [number, number][] = [];
  for (let s = monthStart(since, 0, tz); s < at; s = monthStart(s, 1, tz)) out.push([s, Math.min(monthStart(s, 1, tz), at) - 1000]);
  return out;
}

/**
 * The next `ahead` values of a straight line fitted by least squares to `history`, `gap` steps after the last point and on.
 * Null with fewer than MIN_HISTORY points. An estimate is never below zero. Values are whole cents.
 */
export function project(history: number[], ahead: number, gap = 1): number[] | null {
  const ys = history.slice(-TREND_MONTHS);
  const n = ys.length;
  if (n < MIN_HISTORY) return null;
  const mx = (n - 1) / 2;
  const my = ys.reduce((a, b) => a + b, 0) / n;
  let num = 0, den = 0;
  ys.forEach((y, x) => { num += (x - mx) * (y - my); den += (x - mx) ** 2; });
  const slope = num / den;
  return Array.from({ length: ahead }, (_, i) => Math.max(0, Math.round(my + slope * (n - 1 + gap + i - mx))));
}

/** The range needs at least this many full months: with 2 the line passes through both and the spread says nothing. */
export const MIN_RANGE_HISTORY = 3;
/** About an 80% range: 1.28 standard errors either side of the estimate. */
export const RANGE_Z = 1.28;

/**
 * A low and high for each value project() returns, in whole cents: the estimate ± RANGE_Z prediction standard errors of
 * the same least-squares fit. The error is the residual SD × √(1 + 1/n + (x − x̄)² / Σ(x − x̄)²), so it widens with each
 * month ahead. The range is around the line's own value; low is floored at 0. Null under MIN_RANGE_HISTORY months.
 */
export function projectRange(history: number[], ahead: number, gap = 1): { low: number; high: number }[] | null {
  const ys = history.slice(-TREND_MONTHS);
  const n = ys.length;
  if (n < MIN_RANGE_HISTORY) return null;
  const mx = (n - 1) / 2;
  const my = ys.reduce((a, b) => a + b, 0) / n;
  let num = 0, den = 0;
  ys.forEach((y, x) => { num += (x - mx) * (y - my); den += (x - mx) ** 2; });
  const slope = num / den;
  const fit = (x: number) => my + slope * (x - mx);
  const sd = Math.sqrt(ys.reduce((a, y, x) => a + (y - fit(x)) ** 2, 0) / (n - 2));
  return Array.from({ length: ahead }, (_, i) => {
    const x = n - 1 + gap + i;
    const half = RANGE_Z * sd * Math.sqrt(1 + 1 / n + (x - mx) ** 2 / den);
    return { low: Math.max(0, Math.round(fit(x) - half)), high: Math.max(0, Math.round(fit(x) + half)) };
  });
}

const keyIn = (t: number, tz: string) => { const w = wallClock(t, tz); return `${w.y}-${String(w.m + 1).padStart(2, '0')}`; };
const labelIn = (t: number, tz: string) => MONTH_NAMES[wallClock(t, tz).m];

/**
 * `back` full months, the month so far, and `ahead` estimated months, in the profile currency (or, when it has no rows,
 * the currency with the most rows). Money in is completed sales minus refunds, per month, never below zero.
 * Pending, denied and reversed payments and money sent out do not count.
 */
export function buildChart(rows: ChartRow[], o: { at: number; back: number; ahead: number; currency: string; tz?: string }): ChartData {
  // Months are the owner's calendar months, in their time zone (UTC when unknown).
  const tz = zoneOr(o.tz);
  const key = (t: number) => keyIn(t, tz);
  const label = (t: number) => labelIn(t, tz);
  const start = (at: number, offset = 0) => monthStart(at, offset, tz);
  const since = start(o.at, -o.back);
  const byCurrency = new Map<string, { n: number; months: Map<string, number> }>();
  for (const t of rows) {
    const when = Date.parse(t.date);
    const cents = valueToCents(t.amount);
    if (!(when >= since && when <= o.at) || cents === null || !COUNTED.has(t.status)) continue;
    // A sale counts when positive. An adjustment keeps its own sign: a refund or hold is negative, its release positive.
    if (!t.refund && cents <= 0) continue;
    const signed = cents;
    const c = byCurrency.get(t.currency) ?? { n: 0, months: new Map<string, number>() };
    c.n++;
    c.months.set(key(when), (c.months.get(key(when)) ?? 0) + signed);
    byCurrency.set(t.currency, c);
  }
  const currency = byCurrency.has(o.currency) || !byCurrency.size
    ? o.currency
    : [...byCurrency].reduce((best, cur) => (cur[1].n > best[1].n ? cur : best))[0];
  const months = byCurrency.get(currency)?.months ?? new Map<string, number>();
  const net = (t: number) => Math.max(0, months.get(key(t)) ?? 0);
  const left = [...byCurrency.keys()].filter((c) => c !== currency).sort();

  const full = Array.from({ length: o.back }, (_, i) => start(o.at, i - o.back));
  const fullCents = full.map(net);
  // History starts at the first full month with any money in; empty months before it are "not started", not zero sales.
  const first = fullCents.findIndex((c) => c > 0);
  const history = first < 0 ? [] : fullCents.slice(first);
  // The month so far sits between the last full month and the first estimate, so the line skips it.
  const est = project(history, o.ahead, 2);
  const range = est ? projectRange(history, o.ahead, 2) : null;
  const now = start(o.at);

  const shown: ChartMonth[] = [
    ...full.map((t, i) => ({ month: key(t), label: label(t), value: centsToValue(fullCents[i]), kind: 'actual' as const })),
    { month: key(now), label: label(now), value: centsToValue(net(now)), kind: 'partial' },
    ...(est ?? []).map((c, i) => ({
      month: key(start(o.at, i + 1)), label: label(start(o.at, i + 1)), value: centsToValue(c), kind: 'estimate' as const,
      ...(range ? { low: centsToValue(range[i].low), high: centsToValue(range[i].high) } : {}),
    })),
  ];
  const used = Math.min(history.length, TREND_MONTHS);
  return {
    title: `Money in by month (${currency})`,
    currency,
    months: shown,
    projection: est ? { method: 'straight_line_trend', based_on_months: used, ...(range ? { range: { level: 0.8, method: 'residual_sd' as const } } : {}) } : null,
    caption: (est
      ? `Dashed bars are an estimate: a straight-line trend of the last ${used} full months. Not a promise.`
      : `Not enough history for an estimate yet. It needs ${MIN_HISTORY} full months of sales.`)
      + (left.length ? ` Sales in ${left.join(', ')} are left out.` : ''),
    enough_history: !!est,
  };
}
