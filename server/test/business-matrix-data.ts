// The business matrix: many kinds of business on PayPal, each with a real catalog and the messages its chats
// really carry. Shared by the mocked test (business-matrix.test.ts) and the live eval (scripts/eval-businesses.ts).
import type { Extraction } from '../src/ai.ts';
import type { Intent } from '../src/config.ts';

/** The chip a message should give first. `item` and `qty` are checked when set; `amount` is the payload amount. */
export type Want =
  | { chip: 'insert'; item: string; qty?: number; amount?: string }
  | { chip: 'add_price'; item?: string | null }
  | { chip: 'reply' | 'remind' | 'refund' | 'chart' | 'payments' | 'none' }
  | { chip: 'invoice' | 'paylink'; amount?: string };

export type Msg = {
  say: string;
  /** client: copied from the client's chat (sent as context). owner: typed by the owner. */
  from: 'client' | 'owner';
  /** Every outcome that is right. The first is the best one. */
  want: Want[];
  /** The intent a good model picks, for the mocked test. */
  intent: Intent;
  /** What a good extraction model answers, before the server checks it. Left out: nothing found. */
  model?: Partial<Extraction>;
  /** A known weakness outside the files this matrix may change: the mocked test reports it as a todo. */
  todo?: string;
};

export type Business = {
  id: string;
  description: string;
  currency: 'USD' | 'EUR';
  items: { name: string; price: number }[];
  /** A client with one unpaid invoice, and one with a paid one, so reminders and refunds have something to find. */
  unpaid: string;
  paid: string;
  msgs: Msg[];
};

const none = (say: string, from: Msg['from'] = 'client', intent: Intent = 'none'): Msg => ({ say, from, want: [{ chip: 'none' }], intent });
const item = (name: string, qty = 1): Partial<Extraction> => ({ item: name, quantity: qty > 1 ? qty : null });

export const BUSINESSES: Business[] = [
  {
    id: 'barber', description: 'Barber shop: cuts, fades and beard trims', currency: 'USD', unpaid: 'Jake', paid: 'Marco',
    items: [{ name: 'Haircut', price: 30 }, { name: 'Beard trim', price: 15 }, { name: 'Hot towel shave', price: 35 }],
    msgs: [
      { say: 'how much for a cut?', from: 'client', want: [{ chip: 'insert', item: 'Haircut' }], intent: 'catalog_reply', model: item('haircut') },
      { say: 'price for 3? me and my 2 boys need haircuts saturday', from: 'client', want: [{ chip: 'insert', item: 'Haircut', qty: 3, amount: '90.00' }], intent: 'catalog_reply', model: item('haircut', 3) },
      { say: 'do u do hair coloring? how much', from: 'client', want: [{ chip: 'add_price', item: 'hair coloring' }], intent: 'catalog_reply', model: item('hair coloring') },
      { say: 'hw much is a shave', from: 'client', want: [{ chip: 'insert', item: 'Hot towel shave' }], intent: 'catalog_reply', model: item('shave') },
      { say: 'remind Jake about the cut from last week', from: 'owner', want: [{ chip: 'remind' }], intent: 'send_reminder', model: { client_name: 'Jake' } },
      { say: 'show me a chart of my sales', from: 'owner', want: [{ chip: 'chart' }], intent: 'none' },
      none('running 10 min late sorry!!'),
      none('lol yeah the game was crazy last night', 'client'),
    ],
  },
  {
    id: 'salon', description: 'Hair and nail salon', currency: 'USD', unpaid: 'Tasha', paid: 'Kim',
    items: [{ name: 'Gel manicure', price: 40 }, { name: 'Pedicure', price: 45 }, { name: 'Blowout', price: 55 }, { name: 'Balayage', price: 180 }],
    msgs: [
      { say: 'hiii how much is gel mani?', from: 'client', want: [{ chip: 'insert', item: 'Gel manicure' }], intent: 'catalog_reply', model: item('gel manicure') },
      { say: 'price for 2 pedis? bringing my sister', from: 'client', want: [{ chip: 'insert', item: 'Pedicure', qty: 2, amount: '90.00' }], intent: 'catalog_reply', model: item('pedicure', 2) },
      { say: 'what do u charge for lash extensions', from: 'client', want: [{ chip: 'add_price', item: 'lash extensions' }], intent: 'catalog_reply', model: item('lash extensions') },
      { say: 'can u send me a paypal link for the balayage', from: 'client', want: [{ chip: 'paylink', amount: '180.00' }, { chip: 'invoice', amount: '180.00' }], intent: 'pay_link', model: { item: 'balayage', amount: 180 } },
      { say: 'refund Kim, she had a reaction to the polish', from: 'owner', want: [{ chip: 'refund' }], intent: 'refund', model: { client_name: 'Kim' } },
      none('omg i love it!! posting on insta rn'),
      none('can we do 3 instead of 2?', 'client'),
    ],
  },
  {
    id: 'app_dev', description: 'Freelance app developer: I design and build iPhone apps', currency: 'USD', unpaid: 'Dana', paid: 'Omar',
    items: [{ name: 'App screen', price: 400 }, { name: 'Logo design', price: 250 }, { name: 'Dev hour', price: 95 }],
    msgs: [
      { say: 'price for 5 screens?', from: 'client', want: [{ chip: 'insert', item: 'App screen', qty: 5, amount: '2000.00' }], intent: 'catalog_reply', model: item('app screen', 5) },
      { say: 'whats ur hourly rate', from: 'client', want: [{ chip: 'insert', item: 'Dev hour' }], intent: 'catalog_reply', model: item('dev hour') },
      { say: 'how much would an android version cost', from: 'client', want: [{ chip: 'add_price', item: 'android version' }], intent: 'catalog_reply', model: item('android version') },
      { say: 'invoice dana@startup.io $1,200 for the onboarding screens', from: 'owner', want: [{ chip: 'invoice', amount: '1200.00' }], intent: 'create_invoice', model: { client_email: 'dana@startup.io', amount: 1200, item: 'onboarding screens' } },
      { say: 'nudge Dana about the march invoice pls', from: 'owner', want: [{ chip: 'remind' }], intent: 'send_reminder', model: { client_name: 'Dana' } },
      none('pushed the new build to testflight, check it out'),
      none('can we hop on a call tmrw?', 'client'),
    ],
  },
  {
    id: 'bakery', description: 'Home bakery: custom cakes, cupcakes and cookies', currency: 'USD', unpaid: 'Linda', paid: 'Rosa',
    items: [{ name: 'Cupcakes (dozen)', price: 36 }, { name: 'Birthday cake (8 inch)', price: 65 }, { name: 'Sugar cookie', price: 3.5 }],
    msgs: [
      { say: 'how much for 2 dozen cupcakes?', from: 'client', want: [{ chip: 'insert', item: 'Cupcakes (dozen)', qty: 2, amount: '72.00' }], intent: 'catalog_reply', model: item('cupcakes', 2) },
      { say: 'price for 40 cookies for a baby shower?', from: 'client', want: [{ chip: 'insert', item: 'Sugar cookie', qty: 40, amount: '140.00' }], intent: 'catalog_reply', model: item('sugar cookies', 40) },
      { say: 'do you make wedding cakes? how much', from: 'client', want: [{ chip: 'add_price', item: 'wedding cake' }], intent: 'catalog_reply', model: item('wedding cake') },
      { say: 'how much is a birthday cake', from: 'client', want: [{ chip: 'insert', item: 'Birthday cake (8 inch)' }], intent: 'catalog_reply', model: item('birthday cake') },
      { say: 'can u send the bill for the cake', from: 'client', want: [{ chip: 'invoice', amount: '65.00' }, { chip: 'paylink', amount: '65.00' }], intent: 'create_invoice', model: { item: 'birthday cake', amount: 65 } },
      none('the cake was amazing, thank you!!'),
      none('what time can i pick up saturday?', 'client'),
    ],
  },
  {
    id: 'plumber', description: 'Plumber: repairs, drains and water heaters', currency: 'USD', unpaid: 'Greg', paid: 'Helen',
    items: [{ name: 'Service call', price: 89 }, { name: 'Labor (per hour)', price: 110 }, { name: 'Drain cleaning', price: 150 }, { name: 'Water heater install', price: 1200 }],
    msgs: [
      { say: 'how much to unclog a kitchen drain', from: 'client', want: [{ chip: 'insert', item: 'Drain cleaning' }], intent: 'catalog_reply', model: item('drain cleaning') },
      { say: 'whats ur call out fee', from: 'client', want: [{ chip: 'insert', item: 'Service call' }], intent: 'catalog_reply', model: item('service call') },
      { say: 'rate per hr?', from: 'client', want: [{ chip: 'insert', item: 'Labor (per hour)' }], intent: 'catalog_reply', model: item('labor') },
      { say: 'how much to replace a toilet', from: 'client', want: [{ chip: 'add_price', item: 'toilet replacement' }], intent: 'catalog_reply', model: item('toilet replacement') },
      { say: 'invoice helen@gmail.com $260 for the leak fix', from: 'owner', want: [{ chip: 'invoice', amount: '260.00' }], intent: 'create_invoice', model: { client_email: 'helen@gmail.com', amount: 260, item: 'leak fix' } },
      { say: 'remind Greg he still owes for the heater', from: 'owner', want: [{ chip: 'remind' }], intent: 'send_reminder', model: { client_name: 'Greg' } },
      none('water is still dripping under the sink', 'client'),
    ],
  },
  {
    id: 'tutor', description: 'Private math and SAT tutor', currency: 'USD', unpaid: 'Mrs Chen', paid: 'Alex',
    items: [{ name: 'Tutoring session (1 hr)', price: 60 }, { name: 'SAT prep package (10 sessions)', price: 550 }],
    msgs: [
      { say: 'how much per session?', from: 'client', want: [{ chip: 'insert', item: 'Tutoring session (1 hr)' }], intent: 'catalog_reply', model: item('tutoring session') },
      { say: 'price for 4 sessions this month?', from: 'client', want: [{ chip: 'insert', item: 'Tutoring session (1 hr)', qty: 4, amount: '240.00' }], intent: 'catalog_reply', model: item('tutoring session', 4) },
      { say: 'how much is the SAT package', from: 'client', want: [{ chip: 'insert', item: 'SAT prep package (10 sessions)' }], intent: 'catalog_reply', model: item('SAT prep package') },
      { say: 'do you do chemistry too? rates?', from: 'client', want: [{ chip: 'add_price', item: 'chemistry tutoring' }], intent: 'catalog_reply', model: item('chemistry tutoring') },
      { say: 'here is the link for this weeks 2 sessions $120', from: 'owner', want: [{ chip: 'paylink', amount: '120.00' }], intent: 'pay_link', model: { amount: 120, item: 'tutoring sessions', quantity: 2 } },
      none('Ava did great on her quiz today!', 'owner'),
      none('can we move tuesday to 5pm?', 'client'),
    ],
  },
  {
    id: 'photographer', description: 'Wedding photographer', currency: 'USD', unpaid: 'Maria', paid: 'Ben',
    items: [{ name: 'Wedding package (8 hrs)', price: 2800 }, { name: 'Engagement shoot', price: 450 }, { name: 'Extra hour', price: 250 }],
    msgs: [
      { say: 'how much for a wedding in june?', from: 'client', want: [{ chip: 'insert', item: 'Wedding package (8 hrs)' }], intent: 'catalog_reply', model: item('wedding photography') },
      { say: 'what about engagment photos, price?', from: 'client', want: [{ chip: 'insert', item: 'Engagement shoot' }], intent: 'catalog_reply', model: item('engagement shoot') },
      { say: 'if we need 2 more hours how much', from: 'client', want: [{ chip: 'insert', item: 'Extra hour', qty: 2, amount: '500.00' }], intent: 'catalog_reply', model: item('extra hour', 2) },
      { say: 'do you do drone shots? cost?', from: 'client', want: [{ chip: 'add_price', item: 'drone shots' }], intent: 'catalog_reply', model: item('drone shots') },
      { say: 'invoice maria@gmail.com $1400 deposit for the wedding', from: 'owner', want: [{ chip: 'invoice', amount: '1400.00' }], intent: 'create_invoice', model: { client_email: 'maria@gmail.com', amount: 1400, item: 'wedding deposit' } },
      { say: 'refund Ben the $450, we had to cancel the shoot', from: 'owner', want: [{ chip: 'refund' }], intent: 'refund', model: { client_name: 'Ben', amount: 450 } },
      none('the gallery is ready! check your email', 'owner'),
    ],
  },
  {
    id: 'etsy', description: 'Etsy shop: handmade silver jewelry', currency: 'USD', unpaid: 'Chloe', paid: 'Nadia',
    items: [{ name: 'Silver ring', price: 48 }, { name: 'Name necklace', price: 65 }, { name: 'Stud earrings', price: 32 }],
    msgs: [
      { say: 'how much is the name necklace?', from: 'client', want: [{ chip: 'insert', item: 'Name necklace' }], intent: 'catalog_reply', model: item('name necklace') },
      { say: 'price for 3 rings? bridesmaid gifts', from: 'client', want: [{ chip: 'insert', item: 'Silver ring', qty: 3, amount: '144.00' }], intent: 'catalog_reply', model: item('silver ring', 3) },
      { say: 'do u have gold bracelets? how much', from: 'client', want: [{ chip: 'add_price', item: 'gold bracelet' }], intent: 'catalog_reply', model: item('gold bracelet') },
      { say: 'can i just pay u on paypal for the earrings?', from: 'client', want: [{ chip: 'paylink', amount: '32.00' }, { chip: 'invoice', amount: '32.00' }], intent: 'pay_link', model: { item: 'stud earrings', amount: 32 } },
      { say: 'graph my revenue for the last 6 months', from: 'owner', want: [{ chip: 'chart' }], intent: 'none' },
      none('shipped! tracking is in your email', 'owner'),
      none('it came today, so pretty', 'client'),
    ],
  },
  {
    id: 'consultant', description: 'Management consultant, billed hourly', currency: 'USD', unpaid: 'Acme', paid: 'Vertex',
    items: [{ name: 'Consulting (per hour)', price: 225 }, { name: 'Strategy workshop (full day)', price: 3500 }],
    msgs: [
      { say: 'what is your hourly rate?', from: 'client', want: [{ chip: 'insert', item: 'Consulting (per hour)' }], intent: 'catalog_reply', model: item('consulting') },
      { say: 'quote for 10 hours of advisory?', from: 'client', want: [{ chip: 'insert', item: 'Consulting (per hour)', qty: 10, amount: '2250.00' }], intent: 'catalog_reply', model: item('consulting', 10) },
      { say: 'how much is a workshop day for our leadership team', from: 'client', want: [{ chip: 'insert', item: 'Strategy workshop (full day)' }], intent: 'catalog_reply', model: item('strategy workshop') },
      { say: 'bill Acme for 12 hrs this month', from: 'owner', want: [{ chip: 'invoice', amount: '2700.00' }], intent: 'create_invoice', model: { client_name: 'Acme', amount: 2700, item: 'consulting', quantity: 12 } },
      { say: 'chase Acme on the overdue invoice', from: 'owner', want: [{ chip: 'remind' }], intent: 'send_reminder', model: { client_name: 'Acme' } },
      { say: 'project my income next 3 months', from: 'owner', want: [{ chip: 'chart' }], intent: 'none' },
      none('Thanks for the deck, will review by Friday', 'client'),
    ],
  },
  {
    id: 'catering', description: 'Restaurant and catering: Mexican food, trays for events', currency: 'USD', unpaid: 'Lopez', paid: 'Erin',
    items: [{ name: 'Taco tray (serves 10)', price: 120 }, { name: 'Catering per person', price: 18 }, { name: 'Churros (dozen)', price: 15 }],
    msgs: [
      { say: 'how much to cater 50 people?', from: 'client', want: [{ chip: 'insert', item: 'Catering per person', qty: 50, amount: '900.00' }], intent: 'catalog_reply', model: item('catering', 50) },
      { say: 'price for 2 taco trays', from: 'client', want: [{ chip: 'insert', item: 'Taco tray (serves 10)', qty: 2, amount: '240.00' }], intent: 'catalog_reply', model: item('taco tray', 2) },
      { say: 'do u do a margarita bar? how much', from: 'client', want: [{ chip: 'add_price', item: 'margarita bar' }], intent: 'catalog_reply', model: item('margarita bar') },
      { say: 'send the invoice for the party to erin@events.co $540', from: 'owner', want: [{ chip: 'invoice', amount: '540.00' }], intent: 'create_invoice', model: { client_email: 'erin@events.co', amount: 540, item: 'party catering' } },
      { say: 'how are my sales trending', from: 'owner', want: [{ chip: 'chart' }], intent: 'none' },
      none('is there parking near the venue?', 'client'),
      none('food was a hit, everyone loved it', 'client'),
    ],
  },
  {
    id: 'trainer', description: 'Gym and personal trainer', currency: 'USD', unpaid: 'Mike', paid: 'Sara',
    items: [{ name: 'PT session', price: 70 }, { name: '10-session pack', price: 600 }, { name: 'Monthly membership', price: 49 }],
    msgs: [
      { say: 'how much is a session with you?', from: 'client', want: [{ chip: 'insert', item: 'PT session' }], intent: 'catalog_reply', model: item('PT session') },
      { say: 'whats the membership per month', from: 'client', want: [{ chip: 'insert', item: 'Monthly membership' }], intent: 'catalog_reply', model: item('monthly membership') },
      { say: 'price for the 10 pack?', from: 'client', want: [{ chip: 'insert', item: '10-session pack' }], intent: 'catalog_reply', model: item('10-session pack') },
      { say: 'do u do nutrition plans? cost?', from: 'client', want: [{ chip: 'add_price', item: 'nutrition plan' }], intent: 'catalog_reply', model: item('nutrition plan') },
      { say: 'remind Mike about this months membership', from: 'owner', want: [{ chip: 'remind' }], intent: 'send_reminder', model: { client_name: 'Mike' } },
      none('leg day tomorrow, dont skip 😤', 'owner'),
      none('my knee is sore from yesterday', 'client'),
    ],
  },
  {
    id: 'cleaner', description: 'House cleaning: regular cleans, deep cleans and move-out cleans', currency: 'USD', unpaid: 'Patel', paid: 'Joan',
    items: [{ name: 'Standard clean (2 bed)', price: 120 }, { name: 'Deep clean', price: 220 }, { name: 'Move-out clean', price: 300 }],
    msgs: [
      { say: 'how much for a deep clean', from: 'client', want: [{ chip: 'insert', item: 'Deep clean' }], intent: 'catalog_reply', model: item('deep clean') },
      { say: 'how much do u charge for cleaning?', from: 'client', want: [{ chip: 'reply' }], intent: 'catalog_reply', model: item('cleaning') },
      { say: 'do you clean windows too? price', from: 'client', want: [{ chip: 'add_price', item: 'window cleaning' }], intent: 'catalog_reply', model: item('window cleaning') },
      { say: 'can you send me the invoice for the move out clean', from: 'client', want: [{ chip: 'invoice', amount: '300.00' }, { chip: 'paylink', amount: '300.00' }], intent: 'create_invoice', model: { item: 'move-out clean', amount: 300 } },
      { say: 'refund Joan, we missed her appointment', from: 'owner', want: [{ chip: 'refund' }], intent: 'refund', model: { client_name: 'Joan' } },
      none('key is under the mat as usual', 'client'),
      none('all done! left the windows open to air out', 'owner'),
    ],
  },
  {
    id: 'saas', description: 'SaaS: scheduling software for clinics, monthly and yearly plans', currency: 'USD', unpaid: 'Northside Clinic', paid: 'BrightSmile',
    items: [{ name: 'Starter plan (monthly)', price: 29 }, { name: 'Pro plan (monthly)', price: 79 }, { name: 'Extra seat (monthly)', price: 10 }],
    msgs: [
      { say: 'how much is the pro plan?', from: 'client', want: [{ chip: 'insert', item: 'Pro plan (monthly)' }], intent: 'catalog_reply', model: item('pro plan') },
      { say: 'price for 5 extra seats?', from: 'client', want: [{ chip: 'insert', item: 'Extra seat (monthly)', qty: 5, amount: '50.00' }], intent: 'catalog_reply', model: item('extra seat', 5) },
      { say: 'do you have an enterprise tier? pricing?', from: 'client', want: [{ chip: 'add_price', item: 'enterprise tier' }], intent: 'catalog_reply', model: item('enterprise tier') },
      { say: 'refund BrightSmile, they cancelled in the trial', from: 'owner', want: [{ chip: 'refund' }], intent: 'refund', model: { client_name: 'BrightSmile' } },
      { say: 'chart my monthly revenue', from: 'owner', want: [{ chip: 'chart' }], intent: 'none' },
      none('the calendar sync is broken again', 'client'),
      none('shipped the fix, can you try now?', 'owner'),
    ],
  },
  {
    id: 'dog_walker', description: 'Dog walker and pet sitter', currency: 'USD', unpaid: 'Emma', paid: 'Tom',
    items: [{ name: 'Dog walk (30 min)', price: 20 }, { name: 'Pet sitting (per night)', price: 55 }],
    msgs: [
      { say: 'how much per walk?', from: 'client', want: [{ chip: 'insert', item: 'Dog walk (30 min)' }], intent: 'catalog_reply', model: item('dog walk') },
      { say: 'price for 5 walks next week?', from: 'client', want: [{ chip: 'insert', item: 'Dog walk (30 min)', qty: 5, amount: '100.00' }], intent: 'catalog_reply', model: item('dog walk', 5) },
      { say: 'we are away 3 nights, how much to sit max?', from: 'client', want: [{ chip: 'insert', item: 'Pet sitting (per night)', qty: 3, amount: '165.00' }], intent: 'catalog_reply', model: item('pet sitting', 3) },
      { say: 'do u do grooming? how much', from: 'client', want: [{ chip: 'add_price', item: 'grooming' }], intent: 'catalog_reply', model: item('grooming') },
      { say: 'remind Emma about last weeks walks', from: 'owner', want: [{ chip: 'remind' }], intent: 'send_reminder', model: { client_name: 'Emma' } },
      none('Max was such a good boy today 🐶', 'owner'),
      none('he ate something weird at the park', 'client'),
    ],
  },
  {
    id: 'music_teacher', description: 'Piano and guitar teacher', currency: 'USD', unpaid: 'Leo', paid: 'Grace',
    items: [{ name: 'Piano lesson (45 min)', price: 50 }, { name: 'Guitar lesson (45 min)', price: 45 }, { name: 'Monthly lessons (4 per month)', price: 180 }],
    msgs: [
      { say: 'how much are piano lessons?', from: 'client', want: [{ chip: 'insert', item: 'Piano lesson (45 min)' }], intent: 'catalog_reply', model: item('piano lesson') },
      { say: 'price for 4 guitar lessons', from: 'client', want: [{ chip: 'insert', item: 'Guitar lesson (45 min)', qty: 4, amount: '180.00' }], intent: 'catalog_reply', model: item('guitar lesson', 4) },
      { say: 'do you teach violin? rate?', from: 'client', want: [{ chip: 'add_price', item: 'violin lesson' }], intent: 'catalog_reply', model: item('violin lesson') },
      { say: 'here is the link for november $180', from: 'owner', want: [{ chip: 'paylink', amount: '180.00' }, { chip: 'invoice', amount: '180.00' }], intent: 'pay_link', model: { amount: 180, item: 'monthly lessons' } },
      none('Leo practiced so well this week!', 'owner'),
      none('can we skip thanksgiving week?', 'client'),
    ],
  },
  {
    id: 'landscaper', description: 'Landscaping and lawn care', currency: 'USD', unpaid: 'Mr Davis', paid: 'Karen',
    items: [{ name: 'Lawn mowing (per visit)', price: 45 }, { name: 'Hedge trimming', price: 120 }, { name: 'Mulch install (per yard)', price: 85 }],
    msgs: [
      { say: 'how much to mow every week?', from: 'client', want: [{ chip: 'insert', item: 'Lawn mowing (per visit)' }], intent: 'catalog_reply', model: item('lawn mowing') },
      { say: 'price for 6 yards of mulch', from: 'client', want: [{ chip: 'insert', item: 'Mulch install (per yard)', qty: 6, amount: '510.00' }], intent: 'catalog_reply', model: item('mulch install', 6) },
      { say: 'how much for tree removal', from: 'client', want: [{ chip: 'add_price', item: 'tree removal' }], intent: 'catalog_reply', model: item('tree removal') },
      { say: 'invoice karen@me.com $165 for hedges and mowing', from: 'owner', want: [{ chip: 'invoice', amount: '165.00' }], intent: 'create_invoice', model: { client_email: 'karen@me.com', amount: 165, item: 'hedges and mowing' } },
      none('rain tomorrow so pushing to thursday', 'owner'),
      none('the sprinkler head by the driveway is broken', 'client'),
    ],
  },
  {
    id: 'dj', description: 'Event DJ for weddings and parties', currency: 'USD', unpaid: 'Priya', paid: 'Josh',
    items: [{ name: 'DJ set (4 hrs)', price: 900 }, { name: 'Extra hour', price: 150 }, { name: 'Uplighting', price: 200 }],
    msgs: [
      { say: 'how much to dj a wedding saturday', from: 'client', want: [{ chip: 'insert', item: 'DJ set (4 hrs)' }], intent: 'catalog_reply', model: item('DJ set') },
      { say: 'and 2 extra hours?', from: 'client', want: [{ chip: 'insert', item: 'Extra hour', qty: 2, amount: '300.00' }], intent: 'catalog_reply', model: item('extra hour', 2) },
      { say: 'do you have a photo booth? how much', from: 'client', want: [{ chip: 'add_price', item: 'photo booth' }], intent: 'catalog_reply', model: item('photo booth') },
      { say: 'pay link for the uplighting deposit $200', from: 'owner', want: [{ chip: 'paylink', amount: '200.00' }], intent: 'pay_link', model: { amount: 200, item: 'uplighting deposit' } },
      { say: 'refund Josh, the party got cancelled', from: 'owner', want: [{ chip: 'refund' }], intent: 'refund', model: { client_name: 'Josh' } },
      none('can u play more 2000s hip hop?', 'client'),
    ],
  },
  {
    id: 'translator', description: 'Translator: English to Spanish, documents and websites', currency: 'USD', unpaid: 'Lena', paid: 'Carlos',
    items: [{ name: 'Translation (per word)', price: 0.12 }, { name: 'Certified translation (per page)', price: 35 }, { name: 'Proofreading (per hour)', price: 40 }],
    msgs: [
      { say: 'quote for 1200 words?', from: 'client', want: [{ chip: 'insert', item: 'Translation (per word)', qty: 1200, amount: '144.00' }], intent: 'catalog_reply', model: item('translation', 1200) },
      { say: 'how much per word', from: 'client', want: [{ chip: 'insert', item: 'Translation (per word)' }], intent: 'catalog_reply', model: item('translation') },
      { say: 'price for 3 pages certified (birth cert + diploma)', from: 'client', want: [{ chip: 'insert', item: 'Certified translation (per page)', qty: 3, amount: '105.00' }], intent: 'catalog_reply', model: item('certified translation', 3) },
      { say: 'quote for 1,500 words', from: 'client', want: [{ chip: 'insert', item: 'Translation (per word)', qty: 1500, amount: '180.00' }], intent: 'catalog_reply', model: item('translation', 1500) },
      { say: 'do you do french too? rate?', from: 'client', want: [{ chip: 'add_price', item: 'french translation' }], intent: 'catalog_reply', model: item('french translation') },
      { say: 'send Lena a reminder for the website job', from: 'owner', want: [{ chip: 'remind' }], intent: 'send_reminder', model: { client_name: 'Lena' } },
      none('attached the final file, let me know if anything looks off', 'owner'),
    ],
  },
  {
    id: 'detailer', description: 'Mobile car detailing', currency: 'USD', unpaid: 'Ray', paid: 'Mia',
    items: [{ name: 'Interior detail', price: 120 }, { name: 'Full detail', price: 220 }, { name: 'Ceramic coating', price: 650 }],
    msgs: [
      { say: 'how much for interior only?', from: 'client', want: [{ chip: 'insert', item: 'Interior detail' }], intent: 'catalog_reply', model: item('interior detail') },
      { say: 'price for 2 full details, my car and my wifes', from: 'client', want: [{ chip: 'insert', item: 'Full detail', qty: 2, amount: '440.00' }], intent: 'catalog_reply', model: item('full detail', 2) },
      { say: 'how much is ceramic coating on an suv', from: 'client', want: [{ chip: 'insert', item: 'Ceramic coating' }], intent: 'catalog_reply', model: item('ceramic coating') },
      { say: 'do u do headlight restoration? $?', from: 'client', want: [{ chip: 'add_price', item: 'headlight restoration' }], intent: 'catalog_reply', model: item('headlight restoration') },
      { say: 'remind Ray he owes for the full detail', from: 'owner', want: [{ chip: 'remind' }], intent: 'send_reminder', model: { client_name: 'Ray' } },
      none('on my way, 15 min out', 'owner'),
    ],
  },
  {
    id: 'therapist', description: 'Licensed therapist, private practice, paid per session', currency: 'USD', unpaid: 'Jordan', paid: 'Sam',
    items: [{ name: 'Therapy session (50 min)', price: 150 }, { name: 'Couples session', price: 190 }],
    msgs: [
      { say: 'how much is a session?', from: 'client', want: [{ chip: 'insert', item: 'Therapy session (50 min)' }, { chip: 'reply' }], intent: 'catalog_reply', model: item('therapy session') },
      { say: 'what do you charge for couples counseling', from: 'client', want: [{ chip: 'insert', item: 'Couples session' }], intent: 'catalog_reply', model: item('couples session') },
      { say: 'do you take insurance or is it cash only? how much', from: 'client', want: [{ chip: 'reply' }, { chip: 'insert', item: 'Therapy session (50 min)' }], intent: 'catalog_reply', model: { item: null } },
      { say: 'send me the invoice for 4 sessions for my HSA', from: 'client', want: [{ chip: 'invoice', amount: '600.00' }, { chip: 'paylink', amount: '600.00' }], intent: 'create_invoice', model: { item: 'therapy session', quantity: 4, amount: 600 } },
      { say: 'remind Jordan about the october balance', from: 'owner', want: [{ chip: 'remind' }], intent: 'send_reminder', model: { client_name: 'Jordan' } },
      none('I need to reschedule thursday, sorry', 'client'),
    ],
  },
  {
    id: 'print_shop', description: 'Print shop: flyers, posters, business cards', currency: 'USD', unpaid: 'Bella Cafe', paid: 'Tony',
    items: [{ name: 'Flyer (per unit)', price: 0.45 }, { name: 'Poster A2', price: 12 }, { name: 'Business cards (box of 250)', price: 35 }],
    msgs: [
      { say: 'price for 300 flyers?', from: 'client', want: [{ chip: 'insert', item: 'Flyer (per unit)', qty: 300, amount: '135.00' }], intent: 'catalog_reply', model: item('flyers', 300) },
      { say: 'how much for 10 posters', from: 'client', want: [{ chip: 'insert', item: 'Poster A2', qty: 10, amount: '120.00' }], intent: 'catalog_reply', model: item('poster', 10) },
      { say: '2 boxes of business cards how much', from: 'client', want: [{ chip: 'insert', item: 'Business cards (box of 250)', qty: 2, amount: '70.00' }], intent: 'catalog_reply', model: item('business cards', 2) },
      { say: 'do u print t-shirts? price per shirt', from: 'client', want: [{ chip: 'add_price', item: 't-shirt printing' }], intent: 'catalog_reply', model: item('t-shirt printing') },
      { say: 'invoice tony@pizza.com $135 for the flyers', from: 'owner', want: [{ chip: 'invoice', amount: '135.00' }], intent: 'create_invoice', model: { client_email: 'tony@pizza.com', amount: 135, item: 'flyers' } },
      none('the proof looks great, go ahead', 'client'),
    ],
  },
  {
    id: 'lawyer', description: 'Lawyer: small business and contracts, retainer plus hourly', currency: 'USD', unpaid: 'Kowalski', paid: 'Ortiz',
    items: [{ name: 'Retainer', price: 2500 }, { name: 'Legal work (per hour)', price: 300 }, { name: 'Contract review', price: 750 }],
    msgs: [
      { say: 'what is your retainer?', from: 'client', want: [{ chip: 'insert', item: 'Retainer' }], intent: 'catalog_reply', model: item('retainer') },
      { say: 'how much to review an NDA', from: 'client', want: [{ chip: 'insert', item: 'Contract review' }, { chip: 'add_price', item: 'NDA review' }], intent: 'catalog_reply', model: item('contract review') },
      { say: 'hourly rate for litigation?', from: 'client', want: [{ chip: 'add_price', item: 'litigation' }, { chip: 'insert', item: 'Legal work (per hour)' }], intent: 'catalog_reply', model: item('litigation') },
      { say: 'bill Kowalski the retainer kowalski@law.biz', from: 'owner', want: [{ chip: 'invoice', amount: '2500.00' }], intent: 'create_invoice', model: { client_name: 'Kowalski', client_email: 'kowalski@law.biz', item: 'retainer', amount: 2500 } },
      { say: 'remind Kowalski the retainer is overdue', from: 'owner', want: [{ chip: 'remind' }], intent: 'send_reminder', model: { client_name: 'Kowalski' } },
      none('Filed the motion this morning.', 'owner'),
    ],
  },
  {
    id: 'bike_berlin', description: 'Fahrradwerkstatt in Berlin: bike repair and service', currency: 'EUR', unpaid: 'Jonas', paid: 'Lea',
    items: [{ name: 'Platten flicken (flat tire)', price: 15 }, { name: 'Inspektion (full service)', price: 79 }, { name: 'Bremsen einstellen (brakes)', price: 25 }],
    msgs: [
      { say: 'Was kostet ein Platten flicken?', from: 'client', want: [{ chip: 'insert', item: 'Platten flicken (flat tire)' }], intent: 'catalog_reply', model: item('Platten flicken') },
      { say: 'how much is a full service?', from: 'client', want: [{ chip: 'insert', item: 'Inspektion (full service)' }], intent: 'catalog_reply', model: item('Inspektion') },
      { say: 'wie viel für 2x Bremsen einstellen?', from: 'client', want: [{ chip: 'insert', item: 'Bremsen einstellen (brakes)', qty: 2, amount: '50.00' }], intent: 'catalog_reply', model: item('Bremsen einstellen', 2) },
      { say: 'macht ihr auch E-Bike Akkus? Preis?', from: 'client', want: [{ chip: 'add_price', item: 'E-Bike Akku' }], intent: 'catalog_reply', model: item('E-Bike Akku') },
      { say: 'Rechnung an lea@posteo.de 79€ für die Inspektion', from: 'owner', want: [{ chip: 'invoice', amount: '79.00' }], intent: 'create_invoice', model: { client_email: 'lea@posteo.de', amount: 79, currency: 'EUR', item: 'Inspektion' } },
      none('Das Rad ist fertig, kannst du morgen abholen', 'owner'),
      none('danke, fährt wie neu!', 'client'),
    ],
  },
  {
    id: 'designer_india', description: 'Freelance UI designer in Bangalore, clients in India and abroad', currency: 'USD', unpaid: 'Rohan', paid: 'Neha',
    items: [{ name: 'Logo design', price: 150 }, { name: 'Website design (per page)', price: 120 }, { name: 'Social media post', price: 25 }],
    msgs: [
      { say: 'bhai logo ka kitna lagega?', from: 'client', want: [{ chip: 'insert', item: 'Logo design' }], intent: 'catalog_reply', model: item('logo design') },
      { say: '5 page website ka rate kya hai?', from: 'client', want: [{ chip: 'insert', item: 'Website design (per page)', qty: 5, amount: '600.00' }], intent: 'catalog_reply', model: item('website design', 5) },
      { say: '10 insta posts kitne ke padenge', from: 'client', want: [{ chip: 'insert', item: 'Social media post', qty: 10, amount: '250.00' }], intent: 'catalog_reply', model: item('social media post', 10) },
      { say: 'app ka UI bhi karte ho? kitna?', from: 'client', want: [{ chip: 'add_price', item: 'app UI design' }], intent: 'catalog_reply', model: item('app UI design') },
      { say: 'paise kaise bheju? paypal link bhej do logo ke liye', from: 'client', want: [{ chip: 'paylink', amount: '150.00' }, { chip: 'invoice', amount: '150.00' }], intent: 'pay_link', model: { item: 'logo design', amount: 150 } },
      { say: 'Rohan ko reminder bhejo invoice ka', from: 'owner', want: [{ chip: 'remind' }], intent: 'send_reminder', model: { client_name: 'Rohan' } },
      none('kal call karte hain, 11 baje theek hai?', 'client'),
      none('haan bhai done, files bhej di', 'owner'),
    ],
  },
];

const hash = (s: string) => {
  let h = 2166136261;
  for (const ch of s) h = Math.imul(h ^ ch.charCodeAt(0), 16777619) >>> 0;
  return h;
};

/** A stable 70/30 split: in each business, the 30% of messages with the lowest hash of their words are held out. */
export function heldOut(b: Business, m: Msg): boolean {
  const order = [...b.msgs].sort((x, y) => hash(x.say) - hash(y.say));
  return order.slice(0, Math.round(b.msgs.length * 0.3)).includes(m);
}

type ChipOut = { kind: string; payload: Record<string, any> };

/** The first chip in plain words: "insert Haircut ×3 90.00", "add_price hair coloring", "none". */
export function describe(chips: ChipOut[]): string {
  const c = chips[0];
  if (!c) return 'none';
  const p = c.payload ?? {};
  if (c.kind === 'insert') return `insert ${p.item}${p.quantity > 1 ? ` ×${p.quantity}` : ''} ${p.amount}`;
  if (c.kind === 'add_price') return `add_price ${p.item ?? '(no item)'}`;
  if (c.kind === 'invoice' || c.kind === 'paylink') return `${c.kind} ${p.amount}`;
  return c.kind;
}

export function wantText(w: Want): string {
  if (w.chip === 'insert') return `insert ${w.item}${(w.qty ?? 1) > 1 ? ` ×${w.qty}` : ''}${w.amount ? ` ${w.amount}` : ''}`;
  if (w.chip === 'add_price') return `add_price ${w.item ?? ''}`.trim();
  if (w.chip === 'invoice' || w.chip === 'paylink') return `${w.chip}${w.amount ? ` ${w.amount}` : ''}`;
  return w.chip;
}

const loose = (s: unknown) => String(s ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').replace(/(?<=\w)s\b/g, '').trim();

/** True when the first chip is one of the right outcomes. An "Add a price" item may be worded a little differently. */
export function fits(chips: ChipOut[], want: Want[]): boolean {
  const c = chips[0];
  return want.some((w) => {
    if (w.chip === 'none') return chips.length === 0;
    if (!c || c.kind !== w.chip) return false;
    const p = c.payload ?? {};
    if (w.chip === 'insert') return p.item === w.item && (p.quantity ?? 1) === (w.qty ?? 1) && (!w.amount || p.amount === w.amount);
    if (w.chip === 'add_price') {
      if (!w.item) return true;
      // The model may say "t-shirt" or "t-shirt printing": the two share a main word.
      const main = (v: unknown) => loose(v).split(' ').filter((x) => x.length > 2).map((x) => x.slice(0, 4));
      const got = main(p.item);
      return main(w.item).some((x) => got.includes(x));
    }
    if (w.chip === 'invoice' || w.chip === 'paylink') return !w.amount || p.amount === w.amount;
    return true;
  });
}
