// Every business in the matrix through the real /v1/suggest and the real createAi. Only the network is mocked:
// jev answers the intent a good model picks, and the LLM answers what a good extraction model reads.
// So the catalog match, units, quantities, "Add a price", routing and the no-chip cases are the server's own work.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkExtraction, createAi } from '../src/ai.ts';
import { INTENTS } from '../src/config.ts';
import { quick } from '../src/quick.ts';
import { catalogItemFor, vagueItem } from '../src/search.ts';
import { BUSINESSES, describe, fits, wantText, type Msg } from './business-matrix-data.ts';
import { openMatrix } from './business-matrix-harness.ts';

test('business matrix: size', () => {
  const msgs = BUSINESSES.flatMap((b) => b.msgs);
  assert.ok(BUSINESSES.length >= 20, `${BUSINESSES.length} businesses`);
  assert.ok(BUSINESSES.every((b) => b.msgs.length >= 6), 'each business has 6 or more messages');
  assert.ok(msgs.filter((m) => m.want[0].chip === 'none').length >= BUSINESSES.length, 'every business has chat that gives no chip');
  for (const chip of ['insert', 'add_price', 'reply', 'invoice', 'paylink', 'remind', 'refund', 'chart', 'none']) {
    assert.ok(msgs.some((m) => m.want[0].chip === chip), `some message wants ${chip}`);
  }
});

test('business matrix: every business, every message, through /v1/suggest', async (t) => {
  let current: Msg | null = null;
  const prompts: string[] = [];
  t.mock.method(globalThis, 'fetch', async (url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body));
    if (String(url).includes('typesafe')) {
      const q = body.questions.q;
      // Only the payment-action question has an answer here; a device or lookup question answers "none".
      const pick = q.instructions.question.includes('payment action') ? INTENTS.indexOf(current!.intent) + 1 : 0;
      return Response.json({ answers: { q: { choice: String(pick), confidence: pick ? 0.92 : 0 } } });
    }
    prompts.push(body.messages[0].content);
    const ext = { client_name: null, client_email: null, amount: null, currency: null, item: null, quantity: null, ...current!.model };
    return Response.json({ choices: [{ message: { content: JSON.stringify(ext) } }] });
  });
  const m = await openMatrix(createAi({ typesafeKey: 'k', openrouterKey: 'k' }));
  for (const b of BUSINESSES) {
    await m.open(b);
    for (const msg of b.msgs) {
      await t.test(`${b.id}: ${msg.say}`, { todo: msg.todo }, async () => {
        current = msg;
        prompts.length = 0;
        const chips = await m.ask(b, msg);
        assert.ok(fits(chips, msg.want), `want ${msg.want.map(wantText).join(' or ')}, got ${describe(chips)}`);
        // The owner's description reaches every extraction prompt.
        assert.ok(prompts.every((p) => p.includes(b.description)));
        // A price shown is a catalog price, never one the model said.
        for (const c of chips.filter((x) => x.kind === 'insert')) {
          const it = b.items.find((i) => i.name === c.payload.item);
          assert.ok(it, `insert names a catalog item: ${c.payload.item}`);
          assert.equal(Number(c.payload.amount), Math.round(it.price * 100 * c.payload.quantity) / 100);
        }
      });
    }
  }
});

test('catalogItemFor: the model\'s words find the one catalog item, or none', () => {
  const photo = ['Wedding package (8 hrs)', 'Engagement shoot', 'Extra hour'];
  assert.equal(catalogItemFor('wedding photography', photo, 'Wedding photographer'), 'Wedding package (8 hrs)');
  assert.equal(catalogItemFor('engagment photos', photo, 'Wedding photographer'), null, 'photos is not a word of the item or the business');
  assert.equal(catalogItemFor('engagment shoot', photo), 'Engagement shoot', 'one typo');
  assert.equal(catalogItemFor('family portraits', photo, 'Wedding photographer'), null);
  const clean = ['Standard clean (2 bed)', 'Deep clean', 'Move-out clean'];
  assert.equal(catalogItemFor('window cleaning', clean, 'House cleaning'), null, 'another service keeps its own name');
  assert.equal(catalogItemFor('deep cleaning', clean, 'House cleaning'), 'Deep clean');
  assert.equal(catalogItemFor('cleaning', clean, 'House cleaning'), null, 'three items fit');
  assert.equal(catalogItemFor('shave', ['Haircut', 'Hot towel shave']), 'Hot towel shave', 'the one item with that word');
  assert.equal(catalogItemFor('kids haircut', ['Haircut', 'Kids haircut']), 'Kids haircut');
  assert.equal(catalogItemFor('beard trim', ['Haircut']), null);
  assert.equal(catalogItemFor('translation', ['Translation (per word)', 'Proofreading (per hour)']), 'Translation (per word)');
  assert.equal(catalogItemFor('Platten flicken', ['Platten flicken (flat tire)']), 'Platten flicken (flat tire)');
  assert.equal(catalogItemFor('flat tire', ['Platten flicken (flat tire)', 'Inspektion (full service)']), 'Platten flicken (flat tire)');
  assert.equal(catalogItemFor('per hour', ['Consulting (per hour)']), null, 'a unit alone names nothing');
  assert.equal(catalogItemFor(null, ['Haircut']), null);
});

test('vagueItem: a word for the whole business asks for the catalog, a new thing asks for a price', () => {
  const clean = ['Standard clean (2 bed)', 'Deep clean', 'Move-out clean'];
  assert.equal(vagueItem('cleaning', clean, 'House cleaning'), true);
  assert.equal(vagueItem('house cleaning', clean, 'House cleaning'), true);
  assert.equal(vagueItem('window cleaning', clean, 'House cleaning'), false);
  assert.equal(vagueItem('violin lesson', ['Piano lesson', 'Guitar lesson'], 'Piano and guitar teacher'), false);
  assert.equal(vagueItem('lessons', ['Piano lesson', 'Guitar lesson'], 'Piano and guitar teacher'), true);
  assert.equal(vagueItem('beard trim', ['Haircut'], 'Barber shop: cuts and beard trims'), false);
});

test('checkExtraction: no made-up price, catalog names, totals for a quantity', () => {
  const cat = 'Haircut $30; Beard trim $15; Cupcakes (dozen) $36';
  const ext = (e: object) => ({ client_name: null, client_email: null, amount: null, currency: null, item: null, quantity: null, ...e });
  // No number in the text: only a catalog price, or a catalog price times the quantity, stands.
  assert.equal(checkExtraction(ext({ amount: 45, item: 'haircut' }), 'Client said: can u send the bill', cat).amount, null);
  assert.equal(checkExtraction(ext({ amount: 30, item: 'haircut' }), 'Client said: can u send the bill', cat).amount, 30);
  assert.equal(checkExtraction(ext({ amount: 72, item: 'cupcakes', quantity: 2 }), 'Client said: two dozen cupcakes, how much', cat).amount, 72);
  // A number in the text: the model's reading of it stands, and the route checks it against the regex.
  assert.equal(checkExtraction(ext({ amount: 45 }), 'invoice sam 45', cat).amount, 45);
  assert.equal(checkExtraction(ext({ item: 'cupcakes' }), 'x', cat).item, 'Cupcakes (dozen)');
  assert.equal(checkExtraction(ext({ item: 'wedding cake' }), 'x', cat).item, 'wedding cake');
});

test('quick: price questions in shorthand, typos, Hinglish and German reach the model; chat does not', () => {
  for (const t of ['bhai logo ka kitna lagega?', 'hw much for 2 walks', 'how mutch', 'can u send the invoce', 'wat r ur prises', 'Was kostet ein Platten flicken?', '10 insta posts kitne ke padenge']) {
    assert.equal(quick('', t).none, false, t);
  }
  for (const t of ['lol see you tmrw', 'thanks so much!!', 'how many people are coming?', "I'm at 42 elm st", 'kal call karte hain, 11 baje theek hai?']) {
    assert.equal(quick('', t).none, true, t);
  }
});
