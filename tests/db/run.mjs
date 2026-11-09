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

// ── report ──────────────────────────────────────────────────────────────────
await as('postgres');
const pass = results.filter((r) => r[0] === 'PASS').length;
for (const r of results) console.log(r[0] === 'PASS' ? '  ✓' : '  ✗', r[1], r[2] ? `\n      ${r[2]}` : '');
console.log(`\n${pass}/${results.length} checks passed`);
process.exit(pass === results.length ? 0 : 1);
