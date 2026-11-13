// Applies LifeLink Platform migrations + seeds to PGlite and runs RLS / workflow checks.
// Usage: node run.mjs <path-to-supabase-dir>
import { PGlite } from '@electric-sql/pglite';
import { citext } from '@electric-sql/pglite/contrib/citext';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const supa = process.argv[2];
const here = path.dirname(fileURLToPath(import.meta.url));
const db = new PGlite({ extensions: { citext, pgcrypto } });

const results = [];
const ok = (name) => { results.push(['PASS', name]); };
const bad = (name, why) => { results.push(['FAIL', name, why]); };

async function exec(label, sql) {
  try { await db.exec(sql); console.log('applied', label); }
  catch (e) { console.error('ERROR in', label, '\n ', e.message, e.position ? `(pos ${e.position})` : ''); throw e; }
}

// ── role switching ──────────────────────────────────────────────────────────
async function as(role, uid = null) {
  await db.exec('reset role');
  await db.query(`select set_config('request.jwt.claim.sub', $1, false)`, [uid ?? '']);
  if (role !== 'postgres') await db.exec(`set role ${role}`);
}
async function q(sql, params = []) { return (await db.query(sql, params)).rows; }
async function expectOk(name, fn) {
  try { const r = await fn(); ok(name); return r; } catch (e) { bad(name, e.message); }
}
async function expectErr(name, fn, re) {
  try { await fn(); bad(name, 'expected an error but succeeded'); }
  catch (e) { (!re || re.test(e.message)) ? ok(`${name} → "${e.message}"`) : bad(name, `wrong error: ${e.message}`); }
}
function check(name, cond, detail = '') { cond ? ok(name) : bad(name, detail); }

// ── apply ───────────────────────────────────────────────────────────────────
await exec('supabase_stub.sql', fs.readFileSync(path.join(here, 'supabase_stub.sql'), 'utf8'));
const migDir = path.join(supa, 'migrations');
for (const f of fs.readdirSync(migDir).filter((f) => f.endsWith('.sql')).sort()) {
  await exec(f, fs.readFileSync(path.join(migDir, f), 'utf8'));
}
await exec('seeds/reference.sql', fs.readFileSync(path.join(supa, 'seeds/reference.sql'), 'utf8'));
await exec('seeds/dev_demo.sql', fs.readFileSync(path.join(supa, 'seeds/dev_demo.sql'), 'utf8'));

// ── fixtures ────────────────────────────────────────────────────────────────
await as('postgres');
const uid = async (email) => (await q('select id from public.profiles where email = $1', [email]))[0]?.id;
const ADMIN = await uid('admin@lifelink.dev');
const UMER = await uid('umer.abdullah@email.com');
const KAMRAN = await uid('kamran.siddiqui@email.com');
const AHMED = await uid('ahmed.raza@email.com');
check('seed: 5 profiles created by auth trigger', (await q('select count(*)::int n from public.profiles'))[0].n === 5);
check('seed: Umer has donor row linked to profile', !!(await q('select 1 from public.donors where profile_id=$1', [UMER]))[0]);
check('seed: Regular Donor badge auto-awarded', !!(await q(`select 1 from public.user_badges where user_id=$1 and badge_id='regular-donor'`, [UMER]))[0]);
check('seed: 8 hospitals + 64 inventory rows',
  (await q('select (select count(*) from public.hospitals)::int h, (select count(*) from public.hospital_inventory)::int i'))[0].i === 64);
const fanout = (await q(`select count(*)::int n from public.notifications where type='request'`))[0].n;
check('seed: active requests fanned out to compatible donors', fanout > 0, `notifications=${fanout}`);

// ── 1. Website (anonymous) request ──────────────────────────────────────────
await as('anon');
const web = await expectOk('anon: website blood request accepted', () =>
  q(`select * from public.submit_blood_request($1)`, [JSON.stringify({
    patient_name: 'Test Patient', blood_group: 'O+', contact_phone: '+92 300 1112223',
    hospital_name: 'Indus Hospital', city: 'karachi', urgent: true })]));
check('anon: website request starts as pending', web?.[0]?.status === 'pending', JSON.stringify(web));
check('anon: reference code generated', /^BR-\d{4}-\d{6}$/.test(web?.[0]?.reference_code ?? ''));
await expectErr('anon: cannot read blood_requests table', () => q('select * from public.blood_requests'), /permission denied/);
const pub = await q(`select * from public.list_public_requests()`);
check('anon: public list hides pending requests', !pub.some((r) => r.id === web?.[0]?.id));
check('anon: public list has no contact fields', pub.length > 0 && !('contact_phone' in pub[0]));
await expectErr('anon: invalid blood group rejected', () =>
  q(`select * from public.submit_blood_request($1)`, [JSON.stringify({ patient_name: 'X Y', blood_group: 'Z+', contact_phone: '+923001112223', hospital_name: 'H', city: 'Karachi' })]),
  /valid blood group/);
for (let i = 0; i < 2; i++) await q(`select * from public.submit_blood_request($1)`, [JSON.stringify({ patient_name: 'Spam Test', blood_group: 'A+', contact_phone: '+92 300 9999999', hospital_name: 'Some Hospital', city: 'Lahore' })]);
await q(`select * from public.submit_blood_request($1)`, [JSON.stringify({ patient_name: 'Spam Test', blood_group: 'A+', contact_phone: '+92 300 9999999', hospital_name: 'Some Hospital', city: 'Lahore' })]);
await expectErr('anon: rate limit per contact number', () =>
  q(`select * from public.submit_blood_request($1)`, [JSON.stringify({ patient_name: 'Spam Test', blood_group: 'A+', contact_phone: '+92 300 9999999', hospital_name: 'Some Hospital', city: 'Lahore' })]),
  /Too many requests/);

// ── 2. Donor discovery without contact data ─────────────────────────────────
const donorsPub = await q(`select * from public.search_donors(_city => 'karachi')`);
check('anon: search_donors returns Karachi donors', donorsPub.length >= 3, `rows=${donorsPub.length}`);
check('anon: search_donors exposes no phone/email', donorsPub.every((d) => !('phone' in d) && !('email' in d)));
await expectErr('anon: cannot read donors table', () => q('select phone from public.donors'), /permission denied/);
await expectErr('anon: cannot reveal donor contact', () => q(`select * from public.get_donor_contact($1)`, [donorsPub[0].id]), /sign in|permission denied/i);
await expectErr('anon: cannot call notify_user', () => q(`select public.notify_user($1,'system','x','y')`, [UMER]), /permission denied/);
await expectErr('anon: cannot call bootstrap_admin', () => q(`select public.bootstrap_admin('x@y.z')`), /permission denied/);

// ── 3. App users ─────────────────────────────────────────────────────────────
await as('authenticated', KAMRAN);
const kr = await q(`select * from public.submit_blood_request($1)`, [JSON.stringify({
  patient_name: 'Baby Noor', blood_group: 'O+', units: 2, urgency: 'critical', contact_phone: '+92-333-1239876',
  hospital_name: 'Aga Khan University Hospital', city: 'Karachi', source: 'android' })]);
check('unverified app user: request is pending', kr[0].status === 'pending');
await expectErr('requester cannot approve own request', () =>
  q(`select public.transition_request_status($1,'approved')`, [kr[0].id]), /Only admins/);
check('requester sees own pending request', (await q('select id from public.blood_requests where id=$1', [kr[0].id])).length === 1);
await expectErr('normal user cannot open admin stats', () => q('select public.admin_dashboard_stats()'), /Admin access required/);

await as('authenticated', UMER);
const ur = await q(`select * from public.submit_blood_request($1)`, [JSON.stringify({
  patient_name: 'Umer Relative', blood_group: 'A+', contact_phone: '+92-300-5551234', hospital_id:
    (await (async () => { const r = await q(`select id from public.hospitals where name='Liaquat National Hospital'`); return r[0].id; })()) })]);
check('verified app user: request goes live immediately', ur[0].status === 'active');
check('other users cannot see unapproved requests', (await q('select id from public.blood_requests where id=$1', [kr[0].id])).length === 0);
check('profiles: Umer cannot read Kamran profile', (await q('select id from public.profiles where id=$1', [KAMRAN])).length === 0);
await expectErr('profiles: user cannot self-verify', () => q('update public.profiles set is_verified=true where id=$1', [UMER]), /permission denied/);
await expectOk('profiles: user can update own phone', () => q(`update public.profiles set phone='+92-300-5550000' where id=$1`, [UMER]));
check('profiles: update of other user affects 0 rows',
  (await db.query(`update public.profiles set full_name='Hacked' where id=$1`, [KAMRAN])).affectedRows === 0);
await expectErr('inventory: normal user cannot change stock', () =>
  q(`select public.set_hospital_inventory((select id from public.hospitals limit 1),'O+',1)`), /Not allowed/);
check('audit: normal user reads 0 audit rows', (await q('select * from public.audit_logs')).length === 0);

// availability update reflected publicly
await expectOk('availability: Umer sets busy', () => q(`select public.set_my_availability('busy')`));
await as('anon');
const umerPub = (await q(`select * from public.search_donors(_query => 'Umer')`))[0];
check('availability: website (anon) sees Umer as busy', umerPub?.availability === 'busy', JSON.stringify(umerPub));

// ── 4. Admin approves → visible everywhere + notification + audit ───────────
await as('authenticated', ADMIN);
const stats = (await q('select public.admin_dashboard_stats() s'))[0].s;
check('admin: dashboard stats available', stats.requests_total >= 10, JSON.stringify(stats));
check('admin: sees website and app requests together', (await q('select distinct source from public.blood_requests')).length >= 2);
await expectErr('admin: reject requires reason', () => q(`select public.transition_request_status($1,'rejected')`, [web[0].id]), /reason is required/);
await expectOk('admin: approve website request', () => q(`select public.transition_request_status($1,'approved')`, [web[0].id]));
await expectOk('admin: activate website request', () => q(`select public.transition_request_status($1,'active')`, [web[0].id]));
await expectErr('admin: invalid transition blocked', () => q(`select public.transition_request_status($1,'pending')`, [web[0].id]), /Cannot change/);
check('history: 3 status rows for website request', (await q('select count(*)::int n from public.request_status_history where request_id=$1', [web[0].id]))[0].n === 3);
check('admin activity log written', (await q(`select count(*)::int n from public.admin_activity_logs where target_id=$1`, [web[0].id]))[0].n === 2);
check('audit log has request updates', (await q(`select count(*)::int n from public.audit_logs where table_name='blood_requests' and record_id=$1`, [web[0].id]))[0].n >= 2);
await expectOk('admin: approve Kamran request', () => q(`select public.transition_request_status($1,'approved')`, [kr[0].id]));
await as('authenticated', KAMRAN);
check('requester notified of approval', (await q(`select 1 from public.notifications where user_id=$1 and title='Request Approved'`, [KAMRAN])).length === 1);

await as('anon');
check('anon: approved website request now public', (await q(`select id from public.list_public_requests()`)).some((r) => r.id === web[0].id));
await as('authenticated', UMER);
check('app user: approved request visible in table', (await q('select id from public.blood_requests where id=$1', [web[0].id])).length === 1);

// ── 5. Response + donation flow ─────────────────────────────────────────────
await as('authenticated', UMER);
await expectOk('donor responds to active request', () => q(`select public.respond_to_request($1)`, [web[0].id]));
await expectErr('donor cannot respond twice', () => q(`select public.respond_to_request($1)`, [web[0].id]), /already responded/);
await expectOk('donor records donation for request', () => q(`select public.record_donation(_request_id => $1)`, [web[0].id]));
await expectErr('56-day rule enforced', () => q(`select public.record_donation(_hospital_name => 'X Hospital')`), /56 days/);
const sum = (await q('select public.get_my_summary() s'))[0].s;
check('summary: 8 donations, resting', sum.donations === 8 && sum.availability === 'resting', JSON.stringify(sum));

// ── 6. Donor application → approval → discoverable ──────────────────────────
await as('anon');
const app = await expectOk('anon: donor application submitted', () => q(`select * from public.submit_donor_application($1)`, [JSON.stringify({
  full_name: 'Web Donor', email: 'web.donor@example.com', phone: '+92 301 1234567', age: 30, gender: 'male', blood_group: 'B-', city: 'Multan' })]));
await expectErr('anon: duplicate pending application blocked', () => q(`select * from public.submit_donor_application($1)`, [JSON.stringify({
  full_name: 'Web Donor', email: 'WEB.DONOR@example.com', phone: '+92 301 1234567', age: 30, gender: 'male', blood_group: 'B-', city: 'Multan' })]), /pending request/);
await as('authenticated', UMER);
await expectErr('non-admin cannot approve application', () => q(`select public.admin_review_donor_application($1,true)`, [app[0].id]), /Admin access/);
await as('authenticated', ADMIN);
await expectOk('admin approves application', () => q(`select public.admin_review_donor_application($1,true)`, [app[0].id]));
await as('anon');
check('approved web donor is discoverable', (await q(`select * from public.search_donors(_blood_group => 'B-', _city => 'multan')`)).length === 1);

// later sign-up with same email links instead of duplicating
await as('postgres');
await q(`insert into auth.users (id, email, raw_user_meta_data, instance_id, aud, role) values (gen_random_uuid(), 'web.donor@example.com', '{"full_name":"Web Donor","account_type":"donor"}', '00000000-0000-0000-0000-000000000000','authenticated','authenticated')`);
check('signup links existing donor (no duplicate)', (await q(`select count(*)::int n from public.donors d left join public.profiles p on p.id=d.profile_id where coalesce(p.email, d.email)='web.donor@example.com'`))[0].n === 1);

// ── 7. Roles, suspension, inventory ─────────────────────────────────────────
await as('authenticated', ADMIN);
await expectErr('admin cannot remove own admin role', () => q(`select public.admin_set_user_role($1,'admin',false)`, [ADMIN]), /own admin role/);
await expectOk('admin updates inventory', () => q(`select public.set_hospital_inventory((select id from public.hospitals where name='Civil Hospital Karachi'),'O-',12)`));
await expectOk('admin suspends Kamran', () => q(`select public.admin_set_account_status($1,'suspended','Spam test')`, [KAMRAN]));
await as('authenticated', KAMRAN);
await expectErr('suspended user cannot post', () => q(`select * from public.submit_blood_request($1)`, [JSON.stringify({ patient_name: 'Should Fail', blood_group: 'O+', contact_phone: '+923001112223', hospital_name: 'H Hospital', city: 'Karachi' })]), /suspended/);
await as('authenticated', AHMED);
await expectErr('non-admin cannot grant roles', () => q(`select public.admin_set_user_role($1,'admin',true)`, [AHMED]), /Admin access/);
check('roles: user cannot read others roles', (await q('select * from public.user_roles')).length === 0);
check('notifications: user only sees own', (await q('select distinct user_id from public.notifications')).every((r) => r.user_id === AHMED));

// ── 8. Client read models (migration 0007) ──────────────────────────────────
await as('anon');
const hosp = (await q('select public.list_hospitals() h'))[0].h;
check('client api: anon lists hospitals with inventory', hosp.length >= 8 && Object.keys(hosp[0].inventory).length === 8);
await expectErr('client api: anon cannot list request feed', () => q(`select public.list_requests()`), /sign in|permission denied/i);
await expectErr('client api: anon cannot call admin_list_requests', () => q(`select public.admin_list_requests()`), /permission denied|Admin/);
await as('authenticated', AHMED);
const feed = (await q(`select public.list_requests() f`))[0].f;
check('client api: feed hides other users pending requests', !feed.some((r) => r.status === 'pending' && !r.is_mine));
check('client api: feed includes contact for signed-in users', feed.length > 0 && 'contact_phone' in feed[0]);
const prof = (await q('select public.get_my_profile() p'))[0].p;
check('client api: get_my_profile returns own profile + donor', prof.email === 'ahmed.raza@email.com' && !!prof.donor);
await expectOk('client api: update_my_profile changes city by name', () => q(`select public.update_my_profile($1)`, [JSON.stringify({ city: 'Lahore', area: 'Gulberg' })]));
check('client api: donor city synced to profile city',
  (await q(`select (select public.get_my_profile())->>'city' c`))[0].c === 'Lahore');
await expectErr('client api: update_my_profile rejects bad phone', () => q(`select public.update_my_profile($1)`, [JSON.stringify({ phone: 'abc' })]), /valid phone/);
check('client api: badges list with progress', (await q('select jsonb_array_length(public.list_my_badges()) n'))[0].n === 6);
await expectErr('client api: user cannot list admin donors', () => q(`select public.admin_list_donors()`), /Admin access/);
await expectErr('client api: user cannot create hospital', () => q(`select public.admin_upsert_hospital($1)`, [JSON.stringify({ name: 'Fake Hospital', type: 'private', address: 'Somewhere 1', city: 'Karachi' })]), /Admin access/);
await expectErr('client api: user cannot broadcast', () => q(`select public.admin_send_notification('all','Hi','There')`), /Admin access/);
await as('authenticated', ADMIN);
const al = (await q(`select public.admin_list_requests(_source => 'website') r`))[0].r;
check('admin api: filter requests by source', al.total >= 1 && al.rows.every((r) => r.source === 'website'));
const det = (await q(`select public.admin_get_request($1) d`, [web[0].id]))[0].d;
check('admin api: request details include history + responses', det.history.length === 3 && det.responses.length === 1, JSON.stringify({ h: det.history.length, r: det.responses.length }));
const dl = (await q(`select public.admin_list_donors(_blood_group => 'O+') d`))[0].d;
check('admin api: donor list filtered by blood group', dl.total >= 2 && dl.rows.every((d) => d.blood_group === 'O+'));
const ul = (await q(`select public.admin_list_users(_role => 'admin') u`))[0].u;
check('admin api: users filtered by role', ul.total === 1 && ul.rows[0].roles.includes('admin'));
const newH = await expectOk('admin api: create hospital', async () => (await q(`select public.admin_upsert_hospital($1) id`, [JSON.stringify({ name: 'Test General Hospital', type: 'public', address: 'Main Road 12', city: 'Sukkur', has_blood_bank: true })]))[0].id);
check('admin api: new hospital gets 8 inventory rows', (await q('select count(*)::int n from public.hospital_inventory where hospital_id=$1', [newH]))[0].n === 8);
await expectOk('admin api: edit hospital', () => q(`select public.admin_upsert_hospital($1)`, [JSON.stringify({ id: newH, name: 'Test General Hospital', type: 'public', address: 'Main Road 14', city: 'Sukkur', beds: 120 })]));
const sent = (await q(`select public.admin_send_notification('donors','Drive','Blood drive Saturday', _city => 'Karachi') n`))[0].n;
check('admin api: broadcast reaches Karachi donors', sent >= 2, `sent=${sent}`);
check('admin api: activity log readable', (await q(`select jsonb_array_length(public.admin_list_logs('activity')) n`))[0].n > 0);
check('admin api: audit log readable', (await q(`select jsonb_array_length(public.admin_list_logs('audit', 'blood_requests')) n`))[0].n > 0);
await expectOk('admin api: delete request', () => q(`select public.admin_delete_request($1)`, [kr[0].id]));

// ── 9. Donor profile completion (migration 0008) ────────────────────────────
// A website sign-up as "donor" carries no blood group / city, so no donor record
// exists until the profile is completed. Completing it must list the donor, even
// when the save does not include account_type, and must never duplicate it.
await as('postgres');
const newAuthUser = async (email, meta) => (await q(
  `insert into auth.users (id, email, raw_user_meta_data, instance_id, aud, role)
   values (gen_random_uuid(), $1, $2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated') returning id`,
  [email, JSON.stringify(meta)]))[0].id;
const donorRows = async (id) => q('select blood_group from public.donors where profile_id = $1', [id]);
const WEBD = await newAuthUser('site.donor@example.com', { first_name: 'Site', last_name: 'Donorperson', user_type: 'donor' });
const RECP = await newAuthUser('site.recipient@example.com', { first_name: 'Site', last_name: 'Recipient', user_type: 'recipient' });
check('0008: website donor sign-up has no donor record yet', (await donorRows(WEBD)).length === 0);
await as('authenticated', WEBD);
await expectOk('0008: profile save without account_type adds blood group + city', () =>
  q(`select public.update_my_profile($1)`, [JSON.stringify({ blood_group: 'A-', city: 'Multan', area: 'Cantt' })]));
let wd = await donorRows(WEBD);
check('0008: donor record created once blood group + city are known', wd.length === 1 && wd[0].blood_group === 'A-', JSON.stringify(wd));
const listedW = await q(`select * from public.search_donors(_query => 'Donorperson')`);
check('0008: completed website donor appears in donor search', listedW.length === 1 && listedW[0].city === 'Multan', JSON.stringify(listedW));
await expectOk('0008: saving the profile again', () => q(`select public.update_my_profile($1)`, [JSON.stringify({ area: 'Cantt Bazaar', account_type: 'donor' })]));
check('0008: no duplicate donor record', (await donorRows(WEBD)).length === 1);
await as('authenticated', RECP);
await expectOk('0008: recipient saves blood group + city', () => q(`select public.update_my_profile($1)`, [JSON.stringify({ blood_group: 'B+', city: 'Quetta' })]));
check('0008: recipient accounts are not listed as donors', (await donorRows(RECP)).length === 0);
await as('anon');
await expectErr('0008: anon cannot call update_my_profile', () => q(`select public.update_my_profile('{}')`), /permission denied/);

// ── 10. GPS locations, nearby donors, emergency alerts (migration 0009) ─────
// Request point: Karachi city centre. D1 ≈3 km (O-), D2 ≈3 km (A+, incompatible
// with B+), D3 ≈40 km (B+), D4 ≈2 km (opts out again), D5 ≈2 km (O+, no device).
await as('postgres');
const appUser = (email, group) => newAuthUser(email, { full_name: email.split('@')[0].replace('.', ' '), account_type: 'both', blood_group: group, city: 'Karachi', area: 'Saddar' });
const D1 = await appUser('geo.one@example.com', 'O-');
const D2 = await appUser('geo.two@example.com', 'A+');
const D3 = await appUser('geo.three@example.com', 'B+');
const D4 = await appUser('geo.four@example.com', 'O+');
const D5 = await appUser('geo.five@example.com', 'O+');
const RQ = await appUser('geo.requester@example.com', 'AB+');
const REC = await newAuthUser('geo.recipient@example.com', { full_name: 'Geo Recipient', account_type: 'recipient', blood_group: 'A-', city: 'Karachi' });
const KHI = { lat: 24.8607, lng: 67.0011 };
const pref = async (id) => (await q('select nearby_discovery from public.notification_preferences where user_id = $1', [id]))[0].nearby_discovery;
check('0009: nearby discovery is off by default (explicit opt-in)', (await pref(D1)) === false);
await as('authenticated', D1);
await expectErr('0009: location cannot be shared before opting in', () => q('select public.set_my_location(24.87, 67.03)'), /Share Approximate Location/);
const optIn = async (id, lat, lng) => { await as('authenticated', id); await q('select public.set_nearby_discovery(true)'); await q('select public.set_my_location($1, $2, 25, $3)', [lat, lng, 'gps']); };
await expectOk('0009: opted-in donor shares GPS location', () => optIn(D1, 24.8700, 67.0300));
await optIn(D2, 24.8650, 67.0290);
await optIn(D3, 25.2100, 67.1000);
await optIn(D4, 24.8500, 67.0100);
await optIn(D5, 24.8550, 67.0150);
await as('authenticated', REC);
await q('select public.set_nearby_discovery(true)');
await expectErr('0009: recipient accounts cannot share a location', () => q('select public.set_my_location(24.86, 67.0)'), /Only donor accounts/);
await as('authenticated', D2);
check('0009: other users cannot read a donor location', (await q('select * from public.donor_locations')).length === 1, 'should only see own row');
await as('authenticated', D4);
await q('select public.set_nearby_discovery(false)');
await as('postgres');
check('0009: opting out deletes the stored location', (await q('select count(*)::int n from public.donor_locations dl join public.donors d on d.id = dl.donor_id where d.profile_id = $1', [D4]))[0].n === 0);

await as('anon');
const near10 = await q('select * from public.nearby_donors($1, $2, 10)', [KHI.lat, KHI.lng]);
const names10 = near10.map((d) => d.full_name);
check('0009: anonymous nearby search returns opted-in donors within 10 km', names10.includes('geo one') && names10.includes('geo two') && names10.includes('geo five'), JSON.stringify(names10));
check('0009: donor 40 km away is outside 10 km', !names10.includes('geo three'));
check('0009: opted-out donor never appears', !names10.includes('geo four'));
const one = near10.find((d) => d.full_name === 'geo one');
check('0009: positions are approximate (2 decimals), never exact', one && Number(one.approx_lat) === 24.87 && Number(one.approx_lng) === 67.03, JSON.stringify(one));
check('0009: no phone / email / exact coordinates in results', near10.every((d) => !('phone' in d) && !('email' in d) && !('latitude' in d) && !('longitude' in d)));
check('0009: distance computed from the rounded point', one && Math.abs(Number(one.distance_km) - 3.0) < 0.6, String(one?.distance_km));
check('0009: 50 km radius includes the far donor', (await q('select full_name from public.nearby_donors($1, $2, 50)', [KHI.lat, KHI.lng])).some((d) => d.full_name === 'geo three'));
check('0009: blood group filter', (await q("select blood_group from public.nearby_donors($1, $2, 10, 'O-')", [KHI.lat, KHI.lng])).every((d) => d.blood_group === 'O-'));
check('0009: unsupported radius falls back to 10 km', (await q('select full_name from public.nearby_donors($1, $2, 37)', [KHI.lat, KHI.lng])).every((d) => d.full_name !== 'geo three'));
await expectErr('0009: invalid coordinates rejected', () => q('select * from public.nearby_donors(200, 0, 10)'), /Invalid location/);

// push tokens: D1, D3 have devices; D5 has none
const tok = (s) => `ExponentPushToken[${s.padEnd(22, 'x')}]`;
await as('authenticated', D1);
await expectErr('0009: malformed push token rejected', () => q("select public.register_push_token('not-a-token', 'android')"), /Invalid push token/);
await expectOk('0009: donor registers an Expo push token', () => q('select public.register_push_token($1, $2)', [tok('d1dev'), 'android']));
await as('authenticated', D3);
await q('select public.register_push_token($1, $2)', [tok('d3dev'), 'android']);
await q('select public.register_push_token($1, $2)', [tok('shared'), 'android']);
await as('authenticated', D2);
await q('select public.register_push_token($1, $2)', [tok('shared'), 'android']);
await as('postgres');
check('0009: a token that moves to another account is reassigned, not duplicated', (await q('select user_id from public.device_push_tokens where token = $1', [tok('shared')]))[0]?.user_id === D2);
await q('delete from public.device_push_tokens where token = $1', [tok('shared')]);

// request with a picked location (unverified requester → pending)
await as('authenticated', RQ);
await expectErr('0009: request with invalid coordinates rejected', () => q('select * from public.submit_blood_request($1)', [JSON.stringify({ patient_name: 'Geo Patient', blood_group: 'B+', units: 2, urgency: 'urgent', hospital_name: 'Geo Hospital', city: 'Karachi', contact_phone: '+92 300 5550001', latitude: 95, longitude: 67 })]), /Invalid location/);
const gr = (await q('select * from public.submit_blood_request($1)', [JSON.stringify({ patient_name: 'Geo Patient', blood_group: 'B+', units: 2, urgency: 'urgent', hospital_name: 'Geo Hospital', hospital_address: 'Clifton', city: 'Karachi', contact_phone: '+92 300 5550001', latitude: KHI.lat, longitude: KHI.lng, location_label: 'Geo Hospital, Clifton' })]))[0];
const mineGeo = (await q('select public.list_requests($1, $2) f', ['mine', gr.id]))[0].f[0];
check('0009: picked coordinates and label are stored and returned', Number(mineGeo.latitude) === KHI.lat && Number(mineGeo.longitude) === KHI.lng && mineGeo.location_label === 'Geo Hospital, Clifton', JSON.stringify(mineGeo));
await as('postgres');
check('0009: pending request queues no alerts', (await q('select count(*)::int n from public.emergency_alerts where request_id = $1', [gr.id]))[0].n === 0);
await as('anon');
check('0009: pending request not on the public map', !(await q('select id from public.list_request_locations()')).some((r) => r.id === gr.id));

// admin publishes → matching
await as('authenticated', ADMIN);
await q("select public.transition_request_status($1, 'approved')", [gr.id]);
await as('postgres');
const alerts = await q('select a.user_id, a.status, a.radius_km, a.distance_km, a.last_error from public.emergency_alerts a where a.request_id = $1', [gr.id]);
const byUser = Object.fromEntries(alerts.map((a) => [a.user_id, a]));
check('0009: compatible donor in radius is alerted (queued)', byUser[D1]?.status === 'queued', JSON.stringify(byUser[D1]));
check('0009: incompatible blood group excluded', !byUser[D2]);
check('0009: opted-out donor excluded', !byUser[D4]);
check('0009: requester never alerted', !byUser[RQ]);
check('0009: escalation widened to 50 km to reach the minimum donors', byUser[D3]?.status === 'queued' && byUser[D3]?.radius_km === 50, JSON.stringify(byUser[D3]));
check('0009: donor without a device recorded as no_device', byUser[D5]?.status === 'no_device', JSON.stringify(byUser[D5]));
await as('anon');
const pubLoc = (await q('select * from public.list_request_locations($1, $2, 25)', [KHI.lat, KHI.lng])).find((r) => r.id === gr.id);
check('0009: published request on the public map (rounded, no contact)', pubLoc && Number(pubLoc.latitude) === 24.861 && !('contact_phone' in pubLoc), JSON.stringify(pubLoc));
await as('authenticated', ADMIN);
await q("select public.transition_request_status($1, 'active')", [gr.id]);
await as('postgres');
check('0009: approved → active does not alert anyone twice', (await q('select count(*)::int n from public.emergency_alerts where request_id = $1', [gr.id]))[0].n === alerts.length);

// Edge Function helpers (service_role only)
await as('anon');
await expectErr('0009: anon cannot claim alerts', () => q('select * from public._claim_queued_alerts()'), /permission denied/);
await as('authenticated', D1);
await expectErr('0009: users cannot claim alerts', () => q('select * from public._claim_queued_alerts()'), /permission denied/);
await as('service_role');
const claimed = await q('select * from public._claim_queued_alerts($1, 100)', [gr.id]);
check('0009: service role claims queued alerts with tokens and request details', claimed.length === 2 && claimed.every((c) => c.tokens.length === 1 && c.blood_group === 'B+'), JSON.stringify(claimed.map((c) => c.tokens)));
check('0009: claimed alerts are not claimed twice', (await q('select * from public._claim_queued_alerts($1, 100)', [gr.id])).length === 0);
const c1 = claimed.find((c) => c.user_id === D1);
const c3 = claimed.find((c) => c.user_id === D3);
await q('select public._complete_alerts($1)', [JSON.stringify([
  { alert_id: c1.alert_id, status: 'sent', ticket_ids: ['ticket-1'] },
  { alert_id: c3.alert_id, status: 'failed', error: 'DeviceNotRegistered', invalid_tokens: [tok('d3dev')] },
])]);
await as('postgres');
const done = Object.fromEntries((await q('select user_id, status, sent_at, last_error from public.emergency_alerts where request_id = $1', [gr.id])).map((a) => [a.user_id, a]));
check('0009: delivery results recorded (sent / failed with reason)', done[D1].status === 'sent' && done[D1].sent_at && done[D3].status === 'failed' && done[D3].last_error === 'DeviceNotRegistered');
check('0009: tokens Expo reports as unregistered are deleted', (await q('select count(*)::int n from public.device_push_tokens where token = $1', [tok('d3dev')]))[0].n === 0);
await as('authenticated', D3);
check('0009: donors read only their own alerts', (await q('select user_id from public.emergency_alerts')).every((a) => a.user_id === D3));

// admin settings
await as('authenticated', D1);
await expectErr('0009: non-admin cannot change alert settings', () => q(`select public.admin_update_alert_settings('{"emergency_radius_km": 25}')`), /Admin access/);
await as('anon');
await expectErr('0009: anon cannot read alert settings', () => q('select public.admin_get_alert_settings()'), /permission denied/);
await as('authenticated', ADMIN);
await expectErr('0009: out-of-range radius refused', () => q(`select public.admin_update_alert_settings('{"emergency_radius_km": 500}')`), /allowed range/);
const st = (await q(`select public.admin_update_alert_settings('{"min_donors_before_escalation": 1, "escalation_radii_km": [50, 25]}') s`))[0].s;
check('0009: admin updates settings (escalation sorted)', st.min_donors_before_escalation === 1 && JSON.stringify(st.escalation_radii_km) === '[25,50]' && st.emergency_radius_km === 10, JSON.stringify(st));

// cooldown + no escalation when the minimum is met + city fallback
await as('authenticated', RQ);
const gr2 = (await q('select * from public.submit_blood_request($1)', [JSON.stringify({ patient_name: 'Geo Patient Two', blood_group: 'B+', units: 1, urgency: 'critical', hospital_name: 'Geo Hospital', city: 'Karachi', contact_phone: '+92 300 5550001', latitude: KHI.lat, longitude: KHI.lng })]))[0];
await as('authenticated', ADMIN);
await q("select public.transition_request_status($1, 'approved')", [gr2.id]);
await as('postgres');
const a2 = Object.fromEntries((await q('select user_id, status, radius_km from public.emergency_alerts where request_id = $1', [gr2.id])).map((a) => [a.user_id, a]));
check('0009: donor alerted minutes ago is throttled (skipped, cooldown)', a2[D1]?.status === 'skipped', JSON.stringify(a2[D1]));
check('0009: no escalation once the minimum is met (10 km, far donor not alerted)', a2[D1]?.radius_km === 10 && !a2[D3], JSON.stringify(a2));
await as('authenticated', RQ);
const gr3 = (await q('select * from public.submit_blood_request($1)', [JSON.stringify({ patient_name: 'Geo Patient Three', blood_group: 'O+', units: 1, urgency: 'normal', hospital_name: 'City Hospital', city: 'Karachi', contact_phone: '+92 300 5550001' })]))[0];
await as('authenticated', ADMIN);
await q("select public.transition_request_status($1, 'approved')", [gr3.id]);
await as('postgres');
const a3 = await q('select user_id, radius_km, distance_km from public.emergency_alerts where request_id = $1', [gr3.id]);
check('0009: request without coordinates falls back to same-city donors', a3.length > 0 && a3.every((a) => a.radius_km === null && a.distance_km === null), JSON.stringify(a3.slice(0, 3)));
await as('authenticated', ADMIN);
const stats9 = (await q('select public.admin_alert_stats(7) s'))[0].s;
check('0009: admin alert stats by status', stats9.by_status.sent >= 1 && stats9.by_status.failed >= 1 && stats9.donors_sharing_location >= 4, JSON.stringify(stats9));
check('0009: admin sees failed alerts', (await q('select jsonb_array_length(public.admin_list_alert_failures(50)) n'))[0].n >= 1);
check('0009: admin monitors live requests with alert counts', (await q('select public.admin_list_live_requests_with_alerts() l'))[0].l.some((r) => r.id === gr.id && r.alerts.sent === 1));
const hosp9 = (await q(`select id, name, address from public.hospitals where name like 'Aga Khan%'`))[0];
await expectOk('0009: admin sets coordinates when editing a hospital', () => q('select public.admin_upsert_hospital($1)', [JSON.stringify({ id: hosp9.id, name: hosp9.name, type: 'private', address: hosp9.address, city: 'Karachi', latitude: 24.892, longitude: 67.0749 })]));
check('0009: edited hospital coordinates are stored', (await q(`select (public.list_hospitals(_id => $1::uuid)) -> 0 h`, [hosp9.id]))[0].h.latitude == 24.892);
await as('authenticated', RQ);
const atHosp = (await q('select * from public.submit_blood_request($1)', [JSON.stringify({ patient_name: 'Hospital Coords', blood_group: 'A+', hospital_id: hosp9.id, contact_phone: '+92 300 5550001', urgency: 'normal' })]))[0];
check('0009: request at a known hospital inherits its coordinates', Number((await q('select public.list_requests($1, $2) f', ['mine', atHosp.id]))[0].f[0].latitude) === 24.892);

// ── report ──────────────────────────────────────────────────────────────────
await as('postgres');
const pass = results.filter((r) => r[0] === 'PASS').length;
for (const r of results) console.log(r[0] === 'PASS' ? '  ✓' : '  ✗', r[1], r[2] ? `\n      ${r[2]}` : '');
console.log(`\n${pass}/${results.length} checks passed`);
process.exit(pass === results.length ? 0 : 1);
