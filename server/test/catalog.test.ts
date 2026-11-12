import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deflateSync } from 'node:zlib';
import { setup } from './helpers.ts';

const seg = (marker: number, payload: Buffer) => {
  const h = Buffer.alloc(4);
  h[0] = 0xff; h[1] = marker; h.writeUInt16BE(payload.length + 2, 2);
  return Buffer.concat([h, payload]);
};
// A JPEG with a JFIF block, an EXIF block that holds a GPS note, and a scan.
const jpeg = (pad = 0) => Buffer.concat([
  Buffer.from([0xff, 0xd8]),
  seg(0xe0, Buffer.from('JFIF\0\x01\x01\0\0\x01\0\x01\0\0', 'latin1')),
  seg(0xe1, Buffer.from('Exif\0\0GPS 51.5N 0.12W', 'latin1')),
  seg(0xdb, Buffer.alloc(65, 1)),
  Buffer.from([0xff, 0xda]), Buffer.alloc(pad + 10, 7), Buffer.from([0xff, 0xd9]),
]);
const chunk = (type: string, data: Buffer) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  return Buffer.concat([len, Buffer.from(type, 'latin1'), data, Buffer.alloc(4)]);
};
const png = () => {
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(1, 0); ihdr.writeUInt32BE(1, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('tEXt', Buffer.from('Author\0Ana', 'latin1')),
    chunk('IDAT', deflateSync(Buffer.from([0, 255, 0, 0]))), chunk('IEND', Buffer.alloc(0)),
  ]);
};

function owner() {
  const s = setup();
  const A = s.device();
  const upload = (token: string, id: string, bytes: Buffer, type: string) =>
    s.app.request(`/v1/catalog/${id}/photo`, { method: 'PUT', headers: { Authorization: `Bearer ${token}`, 'Content-Type': type }, body: new Uint8Array(bytes) });
  const add = async (b: Record<string, unknown>) => (await (await s.call(A.token, 'POST', '/v1/catalog', b)).json()).item;
  return { s, A, upload, add };
}

test('catalog: add keeps every field, and defaults fill the rest', async () => {
  const { s, A, add } = owner();
  const full = await add({ name: 'Haircut', price: 45, description: 'Wash, cut and style', category: 'Hair', in_stock: false });
  assert.deepEqual({ ...full, id: undefined }, {
    id: undefined, name: 'Haircut', price: '45.00', currency: 'USD', description: 'Wash, cut and style', category: 'Hair', in_stock: false, sort_order: 0, photo_id: null,
  });
  const bare = await add({ name: 'Beard trim', price: '20' });
  assert.equal(bare.description, '');
  assert.equal(bare.in_stock, true);
  assert.equal(bare.sort_order, 1);
  const list = (await (await s.call(A.token, 'GET', '/v1/catalog')).json()).items;
  assert.deepEqual(list.map((i: { name: string }) => i.name), ['Haircut', 'Beard trim']);
});

test('catalog: validation refuses a long description, a bad price, an unknown field and a bad currency', async () => {
  const { s, A } = owner();
  const bad = [
    { name: 'Cut', price: 45, description: 'x'.repeat(141) },
    { name: 'Cut', price: 0 },
    { name: 'Cut', price: 45, photo: 'http://evil' },
    { name: 'Cut', price: 45, currency: 'XXX' },
    { name: '', price: 45 },
    { name: 'Cut', price: 45, in_stock: 'yes' },
    { name: 'Cut', price: 45, category: 'c'.repeat(41) },
  ];
  for (const b of bad) assert.equal((await s.call(A.token, 'POST', '/v1/catalog', b)).status, 400, JSON.stringify(b));
  assert.equal((await s.call(A.token, 'POST', '/v1/catalog', { name: 'Cut', price: 45, description: 'x'.repeat(140) })).status, 200);
});

test('catalog: an edit keeps details it leaves out, and cleans hidden characters', async () => {
  const { s, A, add } = owner();
  const it = await add({ name: 'Haircut', price: 45, description: 'Wash and cut', category: 'Hair' });
  const r = await s.call(A.token, 'PUT', `/v1/catalog/${it.id}`, { name: 'Haircut', price: 50, in_stock: false, description: 'Cut​ only' });
  const edited = (await r.json()).item;
  assert.equal(edited.price, '50.00');
  assert.equal(edited.in_stock, false);
  assert.equal(edited.description, 'Cut only');
  assert.equal(edited.category, 'Hair');
});

test("catalog: another owner's item is a 404 on edit, delete, reorder and every photo route", async () => {
  const { s, A, upload, add } = owner();
  const B = s.device();
  const it = await add({ name: 'Haircut', price: 45 });
  assert.equal((await upload(A.token, it.id, jpeg(), 'image/jpeg')).status, 200);
  assert.equal((await s.call(B.token, 'PUT', `/v1/catalog/${it.id}`, { name: 'Mine', price: 1 })).status, 404);
  assert.equal((await s.call(B.token, 'DELETE', `/v1/catalog/${it.id}`)).status, 404);
  assert.equal((await s.call(B.token, 'POST', '/v1/catalog/reorder', { ids: [it.id] })).status, 404);
  assert.equal((await upload(B.token, it.id, jpeg(), 'image/jpeg')).status, 404);
  assert.equal((await s.call(B.token, 'GET', `/v1/catalog/${it.id}/photo`)).status, 404);
  assert.equal((await s.call(B.token, 'DELETE', `/v1/catalog/${it.id}/photo`)).status, 404);
  assert.equal((await s.call(A.token, 'GET', `/v1/catalog/${it.id}/photo`)).status, 200, "A's photo is still there");
});

test('catalog: reorder takes every item once, and the list follows it', async () => {
  const { s, A, add } = owner();
  const a = await add({ name: 'A', price: 1 });
  const b = await add({ name: 'B', price: 1 });
  const c = await add({ name: 'C', price: 1 });
  assert.equal((await s.call(A.token, 'POST', '/v1/catalog/reorder', { ids: [c.id, a.id] })).status, 400, 'one left out');
  assert.equal((await s.call(A.token, 'POST', '/v1/catalog/reorder', { ids: [c.id, a.id, a.id] })).status, 400, 'one twice');
  const r = await s.call(A.token, 'POST', '/v1/catalog/reorder', { ids: [c.id, a.id, b.id] });
  assert.deepEqual((await r.json()).items.map((i: { name: string }) => i.name), ['C', 'A', 'B']);
  assert.deepEqual((await (await s.call(A.token, 'GET', '/v1/catalog')).json()).items.map((i: { name: string }) => i.name), ['C', 'A', 'B']);
});

test('catalog photo: JPEG and PNG round trip without metadata, stored encrypted, new id each time', async () => {
  const { s, A, upload, add } = owner();
  const it = await add({ name: 'Haircut', price: 45 });
  const first = (await (await upload(A.token, it.id, jpeg(), 'image/jpeg')).json()).item;
  assert.match(first.photo_id, /^ph_[A-Za-z0-9_-]{40,}$/);
  const got = await s.call(A.token, 'GET', `/v1/catalog/${it.id}/photo`);
  assert.equal(got.headers.get('content-type'), 'image/jpeg');
  const bytes = Buffer.from(await got.arrayBuffer());
  assert.equal(bytes.subarray(0, 2).toString('hex'), 'ffd8');
  assert.ok(!bytes.includes(Buffer.from('GPS')), 'EXIF block is gone');
  assert.ok(bytes.includes(Buffer.from('JFIF')), 'JFIF block stays');
  const row = s.db.raw.prepare('SELECT data_enc FROM catalog_photos').get() as { data_enc: string };
  assert.match(row.data_enc, /^v1:/);
  assert.ok(!Buffer.from(row.data_enc).includes(Buffer.from('JFIF')));

  const second = (await (await upload(A.token, it.id, png(), 'image/png')).json()).item;
  assert.notEqual(second.photo_id, first.photo_id);
  const p = await s.call(A.token, 'GET', `/v1/catalog/${it.id}/photo`);
  assert.equal(p.headers.get('content-type'), 'image/png');
  const pb = Buffer.from(await p.arrayBuffer());
  assert.ok(!pb.includes(Buffer.from('tEXt')), 'text chunk is gone');
  assert.ok(pb.includes(Buffer.from('IDAT')));

  const removed = (await (await s.call(A.token, 'DELETE', `/v1/catalog/${it.id}/photo`)).json()).item;
  assert.equal(removed.photo_id, null);
  assert.equal((await s.call(A.token, 'GET', `/v1/catalog/${it.id}/photo`)).status, 404);
});

test('catalog photo: size and type limits', async () => {
  const { A, upload, add } = owner();
  const it = await add({ name: 'Haircut', price: 45 });
  assert.equal((await upload(A.token, it.id, jpeg(1024 * 1024), 'image/jpeg')).status, 413, 'over 1 MB');
  assert.equal((await upload(A.token, it.id, jpeg(1024 * 1024 - 200), 'image/jpeg')).status, 200, 'just under 1 MB');
  assert.equal((await upload(A.token, it.id, Buffer.from('GIF89a......'), 'image/gif')).status, 400, 'GIF');
  assert.equal((await upload(A.token, it.id, png(), 'image/jpeg')).status, 400, 'type header does not match the bytes');
  assert.equal((await upload(A.token, it.id, Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>'), 'image/png')).status, 400, 'SVG');
  assert.equal((await upload(A.token, it.id, jpeg().subarray(0, 30), 'image/jpeg')).status, 400, 'cut-off JPEG');
  assert.equal((await upload(A.token, it.id, png().subarray(0, 40), 'image/png')).status, 400, 'cut-off PNG');
  assert.equal((await upload(A.token, 'nope', jpeg(), 'image/jpeg')).status, 404);
});

test('catalog photo: deleting the item deletes its photo', async () => {
  const { s, A, upload, add } = owner();
  const it = await add({ name: 'Haircut', price: 45 });
  await upload(A.token, it.id, jpeg(), 'image/jpeg');
  assert.equal((await s.call(A.token, 'DELETE', `/v1/catalog/${it.id}`)).status, 200);
  assert.equal((s.db.raw.prepare('SELECT COUNT(*) AS n FROM catalog_photos').get() as { n: number }).n, 0);
});

test('catalog: a JSON body over the normal limit is still refused on other routes', async () => {
  const { s, A } = owner();
  const r = await s.call(A.token, 'POST', '/v1/catalog', { name: 'Cut', price: 45, description: 'x'.repeat(20_000) });
  assert.equal(r.status, 413);
});

test('catalog caps: 200 items, then a clear 400', async () => {
  const { s, A } = owner();
  for (let i = 0; i < 200; i++) s.db.addItem(A.userId, { name: `Item ${i}`, price_cents: 100, currency: 'USD' });
  const r = await s.call(A.token, 'POST', '/v1/catalog', { name: 'One more', price: 1 });
  assert.equal(r.status, 400);
  assert.equal((await r.json()).error, 'catalog is full: 200 items at most');
});

test('catalog caps: a photo over 1 MB and photos over 50 MB in all get a clear 413', async () => {
  const { s, A, upload, add } = owner();
  const big = await upload(A.token, (await add({ name: 'Big', price: 1 })).id, jpeg(1024 * 1024), 'image/jpeg');
  assert.equal(big.status, 413);
  assert.equal((await big.json()).error, 'photo is over 1 MB');
  // 49 items already hold just over 1 MB each.
  for (let i = 0; i < 49; i++) {
    const it = s.db.addItem(A.userId, { name: `P${i}`, price_cents: 100, currency: 'USD' });
    s.db.putItemPhoto(A.userId, it.id, { id: `ph_${i}`, mime: 'image/jpeg', data_enc: 'x', bytes: 1024 * 1024 + 1024 });
  }
  const it = await add({ name: 'Last', price: 1 });
  const full = await upload(A.token, it.id, jpeg(1024 * 1024 - 200), 'image/jpeg');
  assert.equal(full.status, 413);
  assert.equal((await full.json()).error, 'photo storage is full (50 MB). Remove a photo first.');
  assert.equal((await upload(A.token, it.id, jpeg(), 'image/jpeg')).status, 200, 'a small one still fits');
  // Replacing a photo does not count the old one.
  const p0 = s.db.listItems(A.userId).find((i) => i.name === 'P0')!;
  assert.equal((await upload(A.token, p0.id, jpeg(1024 * 1024 - 400), 'image/jpeg')).status, 200);
});
