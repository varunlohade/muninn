import { test } from 'node:test';
import assert from 'node:assert/strict';
import { detectLookup, editDistance } from '../src/quick.ts';
import { importance, matchName, SHOW_AT } from '../src/search.ts';
import { BUSINESSES, NOW, daysAgo, seeded } from './search-fixtures.ts';

test('matchName: exact first, then a labelled prefix, then one typo; never a silent substring', () => {
  const both = ['Sam Lee', 'Samantha Cruz', 'Ana Lopez'];
  assert.deepEqual(matchName('sam', both), { match: 'exact', names: ['Sam Lee'] }, 'Sam never hits Samantha while Sam exists');
  assert.deepEqual(matchName('sam', ['Samantha Cruz', 'Ana Lopez']), { match: 'did_you_mean', names: ['Samantha Cruz'] });
  assert.deepEqual(matchName('samantha', both), { match: 'exact', names: ['Samantha Cruz'] });
  assert.deepEqual(matchName('lopez', both), { match: 'exact', names: ['Ana Lopez'] }, 'a whole last name is exact');
  assert.deepEqual(matchName('ana lopez', both), { match: 'exact', names: ['Ana Lopez'] });
  assert.deepEqual(matchName("sam's", both), { match: 'exact', names: ['Sam Lee'] });
  assert.deepEqual(matchName('sams', both), { match: 'exact', names: ['Sam Lee'] }, 'a possessive with no apostrophe');
  assert.deepEqual(matchName('am', both), { match: 'none', names: [] }, 'the middle of a name is no match');
  assert.deepEqual(matchName('mantha', both), { match: 'none', names: [] }, 'a cut-off start is no match');
  assert.deepEqual(matchName('samanta', both), { match: 'did_you_mean', names: ['Samantha Cruz'] }, 'one typo in a long name');
  assert.deepEqual(matchName('sma', both), { match: 'none', names: [] }, 'no typo match under 4 letters');
  assert.deepEqual(matchName('sam', ['Sam Lee', 'Sam Ortiz', 'Sam Wu', 'Sam Bo']), { match: 'ambiguous', names: ['Sam Lee', 'Sam Ortiz', 'Sam Wu'] }, 'at most 3');
  assert.deepEqual(matchName('sa', ['Samantha Cruz', 'Sarah Kay']), { match: 'ambiguous', names: ['Samantha Cruz', 'Sarah Kay'] });
  assert.deepEqual(matchName('jon', ['Joan Ray', 'John Fox']).match, 'none', 'a typo that fits two names is no match');
  assert.equal(editDistance('invocie', 'invoice'), 1);
});

test('detectLookup: business words map to kinds; plain chat and new-invoice commands are not lookups', () => {
  const kinds: [string, string, string | null][] = [
    ['invoice for sam', 'money', 'invoice'], ['bill for sam', 'money', 'bill'], ["sam's receipt", 'money', 'receipt'], ['did sam pay', 'money', null],
    ['what does sam owe', 'money', null], ['last order from ana', 'any', 'order'], ["ana's booking", 'any', 'booking'],
    ['latest appointment for ana', 'any', 'appointment'], ["dave's quote", 'any', 'quote'], ['last session with leo', 'any', 'session'],
    ["maria's table", 'any', 'table'], ['delivery for kenji', 'any', 'delivery'], ['price of balayage', 'catalog', null],
    ['how much is pad thai', 'catalog', null],
  ];
  for (const [t, kind, noun] of kinds) {
    const d = detectLookup(t, NOW);
    assert.ok(d?.sure, t);
    assert.deepEqual([d.kind, d.noun], [kind, noun], t);
  }
  assert.equal(detectLookup('what does sam owe', NOW)?.want, 'unpaid');
  assert.equal(detectLookup("sam's receipt", NOW)?.want, 'paid');
  assert.deepEqual(detectLookup("sam's invoice from last week", NOW)?.range, { from: daysAgo(9) - 12 * 3_600_000, to: daysAgo(2) - 12 * 3_600_000, words: 'last week' });
  assert.equal(detectLookup('the $120 one for sam', NOW)?.cents, 12000);
  assert.equal(detectLookup('invoice sam', NOW)?.sure, false, 'a command or a lookup: unsure');
  for (const t of ['sam is here', 'sam said hi', 'invoice template ideas', "i'll pay sam tomorrow", 'invoice sam $45 for a haircut', 'invoice for sam for $45',
    'send the invoice to sam', "sam's booking is at 3pm", 'did you pay sam', 'thanks for the payment sam', '']) {
    assert.equal(detectLookup(t, NOW)?.sure ?? false, false, t);
  }
});

test('importance: a full phrase and a known name show; a bare name never does', () => {
  assert.ok(importance(true, 'exact') >= SHOW_AT);
  assert.ok(importance(true, 'did_you_mean') >= SHOW_AT);
  assert.ok(importance(false, 'exact') >= SHOW_AT, '"invoice sam" with one Sam shows');
  assert.ok(importance(false, 'exact', 2) < SHOW_AT);
  assert.ok(importance(false, 'did_you_mean') < SHOW_AT);
  assert.ok(importance(true, 'none') < SHOW_AT);
});

test('suggest: "invoice for sam" shows Sam\'s latest invoice and 2 older ones, with no paid call', async () => {
  const w = seeded(BUSINESSES.salon);
  const chip = await w.lookup('invoice for sam');
  assert.ok(chip);
  assert.equal(chip.label, "Sam Lee's invoice · $120 · unpaid · Nov 9");
  assert.equal(chip.trigger, 'invoice for sam');
  const c = chip.payload.candidates[0];
  assert.equal(c.name, 'Sam Lee');
  assert.deepEqual(c.records.map((r: any) => [r.amount, r.state]), [['120.00', 'unpaid'], ['45.00', 'paid'], ['60.00', 'paid']]);
  assert.match(c.records[0].line, /^Your invoice for \$120 \(Nov 9\) is here: https:\/\/paypal\.test\/inv\//);
  assert.equal(c.records[0].remind.kind, 'remind');
  assert.equal(c.records[0].remind.needs_confirm, true);
  assert.equal(c.records[1].remind, undefined, 'a paid invoice has no Remind');
  assert.deepEqual(w.s.aiCalls, [], 'regex path: no model call');
  assert.deepEqual(w.s.calls, [], 'a lookup calls no PayPal action and sends no mail');
});

test('suggest: Sam vs Samantha, ambiguity and unknown names', async () => {
  const salon = seeded(BUSINESSES.salon);
  assert.equal((await salon.lookup('did samantha pay'))?.payload.candidates[0].name, 'Samantha Cruz');
  const onlySamantha = seeded({ invoices: [{ client: 'Samantha Cruz', cents: 9000, item: 'Trial', at: daysAgo(5) }] });
  const dym = await onlySamantha.lookup('invoice for sam');
  assert.equal(dym?.payload.match, 'did_you_mean');
  assert.match(dym!.label, /^Did you mean Samantha Cruz\? · invoice \$90 · unpaid/);
  const two = seeded({ invoices: [
    { client: 'Sam Lee', cents: 12000, item: 'Color', at: daysAgo(2) }, { client: 'Sam Ortiz', cents: 3000, item: 'Trim', at: daysAgo(1) },
  ] });
  const amb = await two.lookup("sam's invoice");
  assert.equal(amb?.payload.match, 'ambiguous');
  assert.deepEqual(amb!.payload.candidates.map((c: any) => c.name).sort(), ['Sam Lee', 'Sam Ortiz']);
  assert.equal(amb!.label, '2 clients match "Sam" · pick one');
  assert.deepEqual(salon.s.aiCalls, []);
  // An unknown name is never a keyboard chip; the text goes on to the normal suggest.
  assert.equal(await salon.lookup('invoice for zed'), undefined);
});

test('suggest: kinds across a salon, a restaurant, a tutor and a contractor', async () => {
  const salon = seeded(BUSINESSES.salon);
  assert.equal((await salon.lookup("ana's booking"))?.label, "Ana Lopez's pay link · $35 · paid · Nov 4");
  assert.equal((await salon.lookup('price of balayage'))?.label, 'Balayage · $180');
  const rest = seeded(BUSINESSES.restaurant);
  assert.equal((await rest.lookup('last order from maria'))?.label, "Maria Gomez's pay link · $64 · paid · Nov 10");
  assert.equal((await rest.lookup('did theo pay'))?.label, "Theo Park's invoice · $850 · unpaid · Nov 8");
  const tutor = seeded(BUSINESSES.tutor);
  assert.equal((await tutor.lookup("priya's lessons"))?.label, "Priya Shah's repeat bill · $200 · active · Oct 22");
  tutor.s.db.raw.prepare("UPDATE subscriptions SET status = 'SUSPENDED' WHERE user_id = ?").run(tutor.userId);
  const paused = await tutor.lookup("priya's lessons");
  assert.equal(paused?.label, "Priya Shah's repeat bill · $200 · paused · Oct 22");
  assert.match(paused?.payload.candidates[0].records[0].line, /plan for \$200 is paused\.$/);
  tutor.s.db.raw.prepare("UPDATE subscriptions SET status = 'ACTIVE' WHERE user_id = ?").run(tutor.userId);
  assert.equal((await tutor.lookup('what does leo owe'))?.payload.candidates[0].records.length, 1, 'owe: unpaid only');
  const noor = await tutor.lookup('does noor owe me anything');
  assert.equal(noor?.label, 'Noor Haddad owes you nothing right now');
  const pro = seeded(BUSINESSES.contractor);
  assert.equal((await pro.lookup("dave's invoice from last week"))?.payload.candidates[0].records[0].amount, '2400.00');
  assert.equal((await pro.lookup("dave's $500 invoice"))?.payload.candidates[0].records[0].amount, '500.00');
  assert.equal((await pro.lookup('invoice for ellis'))?.payload.candidates[0].records[0].state, 'cancelled');
  for (const w of [salon, rest, tutor, pro]) assert.deepEqual(w.s.aiCalls, []);
});

test('suggest: plain chat stays free; an unsure lookup asks jev once', async () => {
  const salon = seeded(BUSINESSES.salon, { route: { route: 'lookup' } });
  for (const t of ['sam is here', 'sam said hi', 'sam said thanks']) {
    assert.deepEqual((await salon.suggest(t)).chips, [], t);
  }
  assert.equal(salon.s.aiCalls.length, 0, 'plain chat: 0 paid calls');
  // "invoice sam" with one client named Sam: the regex settles it, and the card also offers New invoice.
  const chip = await salon.lookup('invoice sam');
  assert.equal(chip?.label, "Sam Lee's invoice · $120 · unpaid · Nov 9");
  assert.equal(chip?.payload.new_invoice, true);
  assert.equal(salon.s.aiCalls.length, 0, 'an exact unique name: 0 paid calls');
  assert.equal((await salon.lookup('invoice for sam'))?.payload.new_invoice, false, 'a clear lookup phrase offers no New invoice');
  // A near name in an unsure phrase asks jev once.
  const near = await salon.lookup('invoice samanta');
  assert.equal(near?.payload.candidates[0].name, 'Samantha Cruz');
  assert.deepEqual(salon.s.aiCalls.map((c) => c.fn), ['askRoute']);
  const no = seeded(BUSINESSES.salon, { route: { route: 'who_paid' } });
  assert.equal(await no.lookup('invoice samanta'), undefined, 'jev says it is not a lookup: the normal suggest runs');
  const two = seeded({ invoices: [
    { client: 'Sam Lee', cents: 12000, item: 'Color', at: daysAgo(2) }, { client: 'Sam Ortiz', cents: 3000, item: 'Trim', at: daysAgo(1) },
  ] }, { route: { route: 'who_paid' } });
  assert.equal(await two.lookup('invoice sam'), undefined, 'two Sams: not settled by the regex');
});

test('ask: the same search, an empty result, and the remind chip keeps its confirm', async () => {
  const w = seeded(BUSINESSES.salon);
  const r = await w.ask('invoice for sam');
  assert.equal(r.route, 'lookup');
  assert.equal(r.result.candidates[0].records[0].amount, '120.00');
  assert.deepEqual(w.s.aiCalls, [], 'a clear lookup skips the router');
  const empty = await w.ask('invoice for zed');
  assert.equal(empty.result.match, 'none');
  assert.equal(empty.result.candidates[0].empty_line, 'No invoices yet');
  const none = await w.ask("ana's invoice");
  assert.equal(none.result.candidates[0].empty_line, 'No invoices yet', 'Ana has a pay link, not an invoice');
  assert.equal((await w.lookup("ana's invoice"))?.label, 'No invoices for Ana Lopez yet', 'the chip still names who');
  // The Remind chip in a result goes through /v1/actions/remind, which still asks for the confirm.
  const remind = r.result.candidates[0].records[0].remind;
  assert.equal(remind.label, `Nudge ${r.result.candidates[0].name} · $${Number(remind.payload.amount)} owed`);
  const first = await w.s.call(w.token, 'POST', '/v1/actions/remind', { invoice_id: remind.payload.invoice_id });
  assert.equal(first.status, 409);
  assert.equal((await first.json()).needs_confirm, true);
  assert.deepEqual(w.s.calls, [], 'no reminder without the confirm');
});

test('ask: a router "lookup" answers from the regex reading, or asks for a name', async () => {
  const w = seeded(BUSINESSES.salon, { group: { group: 'info' }, route: { route: 'lookup' } });
  assert.equal((await w.ask('invoice sam')).result.candidates[0].name, 'Sam Lee');
  const vague = await w.ask('find that thing');
  assert.equal(vague.route, 'none');
  assert.match(vague.result.line, /Say whose record/);
});
