// ============================================================================
// LifeLink cross-client end-to-end tests (the 12 required scenarios).
//
// Starts the local dev server (in-memory PGlite, same migrations/RLS/RPCs as
// Supabase) and drives it with the real @supabase/supabase-js client, making
// exactly the calls each client makes:
//   website  → LifeLinkDB (db.js):       anon RPCs, auth, search, realtime
//   android  → src/services/api.ts:      signed-in RPCs + table reads, realtime
//   admin    → admin.js:                 admin_* RPCs, transition_request_status
//
// Usage: npm run test:e2e        (or: node tests/e2e/run.mjs --url http://127.0.0.1:54321 to target a running server)
// ============================================================================
import { spawn } from 'node:child_process';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { dispatch as dispatchAlerts } from '../../supabase/functions/send-emergency-alerts/core.ts';

const ROOT = path.resolve(import.meta.dirname, '../..');
const argUrl = process.argv.includes('--url') ? process.argv[process.argv.indexOf('--url') + 1] : null;
const PORT = 54400 + Math.floor(Math.random() * 400);
const URL = argUrl ?? `http://127.0.0.1:${PORT}`;

let server = null;
if (!argUrl) {
  server = spawn(process.execPath, [path.join(ROOT, 'dev-server/server.mjs'), '--memory', '--no-web', '--quiet'], {
    env: { ...process.env, PORT: String(PORT), HOST: '127.0.0.1' },
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  process.on('exit', () => server?.kill());
}
for (let i = 0; i < 120; i++) {
  try { if ((await fetch(URL + '/')).ok) break; } catch { /* starting */ }
  await new Promise((r) => setTimeout(r, 500));
}
const INFO = await (await fetch(URL + '/')).json();
const KEY = INFO.anonKey;
const SERVICE_KEY = INFO.serviceRoleKeyDevOnly; // local dev server only
const client = () => createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } });

// ── tiny test harness ───────────────────────────────────────────────────────
const results = [];
let scenario = '';
const pass = (name) => results.push({ ok: true, scenario, name });
const fail = (name, why) => results.push({ ok: false, scenario, name, why });
const check = (name, cond, detail = '') => (cond ? pass(name) : fail(name, detail));
const S = (title) => { scenario = title; console.log(`\n▶ ${title}`); };
async function ok(name, p) {
  const { data, error } = await p;
  if (error) fail(name, error.message); else pass(name);
  return data;
}
async function denied(name, p, re) {
  const { error } = await p;
  if (!error) return fail(name, 'expected an error but the call succeeded');
  if (re && !re.test(error.message)) return fail(name, `unexpected error: ${error.message}`);
  pass(`${name} → "${error.message}"`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
/** Subscribe like the clients do; resolves when SUBSCRIBED. Returns collected events. */
async function listen(sb, table, filter) {
  const events = [];
  const opts = { event: '*', schema: 'public', table, ...(filter ? { filter } : {}) };
  const ch = sb.channel(`t-${table}-${Math.random()}`).on('postgres_changes', opts, (p) => events.push(p));
  await new Promise((res, rej) => ch.subscribe((st, err) => (st === 'SUBSCRIBED' ? res() : st === 'CHANNEL_ERROR' ? rej(err) : null)));
  return { events, close: () => sb.removeChannel(ch) };
}
async function waitFor(fn, ms = 4000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (fn()) return true; await sleep(100); }
  return false;
}

// ── actors ──────────────────────────────────────────────────────────────────
const website = client();                     // anonymous visitor on the website
const admin = client();
await admin.auth.signInWithPassword({ email: 'admin@lifelink.dev', password: 'LifeLinkAdmin#2026' });
const kamran = client();                      // unverified app user (recipient)
await kamran.auth.signInWithPassword({ email: 'kamran.siddiqui@email.com', password: 'lifelink123' });
const ahmed = client();                       // donor using the app
await ahmed.auth.signInWithPassword({ email: 'ahmed.raza@email.com', password: 'lifelink123' });
const zainab = client();                      // another donor
await zainab.auth.signInWithPassword({ email: 'zainab.farooq@email.com', password: 'lifelink123' });

// realtime listeners opened before the actions they should observe
const adminRt = await listen(admin, 'blood_requests');
const ahmedRt = await listen(ahmed, 'blood_requests');
const websiteAvailRt = await listen(website, 'donor_availability');

// ── 1–4: website request → database → dashboard → Android ───────────────────
S('1. Website creates a blood request');
const webReq = (await ok('website: submit_blood_request (anonymous, same payload as blood_request.html)',
  website.rpc('submit_blood_request', { p: { patient_name: 'E2E Website Patient', blood_group: 'B+', contact_phone: '+92 321 5550001',
    contact_name: 'E2E Website Patient', hospital_name: 'Indus Hospital', city: 'Karachi', urgent: true, units: 1, source: 'website' } })))?.[0];
check('website: gets a reference code', /^BR-\d{4}-\d{6}$/.test(webReq?.reference_code ?? ''), JSON.stringify(webReq));
check('website: anonymous request waits for review (pending)', webReq?.status === 'pending');
await denied('website: invalid phone rejected by the server', website.rpc('submit_blood_request', { p: { patient_name: 'Bad Phone', blood_group: 'B+', contact_phone: 'call me', hospital_name: 'Indus Hospital', city: 'Karachi' } }), /phone|contact number/i);

S('2. Request is stored in the shared database');
const stored = await ok('admin: admin_get_request returns the stored row', admin.rpc('admin_get_request', { _id: webReq.id }));
check('stored: source=website, urgency=urgent, city resolved', stored?.source === 'website' && stored?.urgency === 'urgent' && stored?.city === 'Karachi', JSON.stringify(stored));
check('stored: status history has the creation entry', stored?.history?.length === 1 && stored.history[0].to === 'pending');

S('3. Request appears in the admin dashboard');
const pendingList = await ok('admin: admin_list_requests(status=pending, source=website)', admin.rpc('admin_list_requests', { _status: 'pending', _source: 'website' }));
check('dashboard list contains the website request', pendingList?.rows?.some((r) => r.id === webReq.id));
check('dashboard received it in realtime (INSERT)', await waitFor(() => adminRt.events.some((e) => e.eventType === 'INSERT' && e.new?.id === webReq.id)));
const stats1 = await ok('admin: admin_dashboard_stats', admin.rpc('admin_dashboard_stats'));
check('dashboard stats count pending requests', (stats1?.requests_by_status?.pending ?? 0) >= 1, JSON.stringify(stats1?.requests_by_status));

S('4. Request appears in Android (after approval; pending requests are private)');
let feed = await ok('android: list_requests (feed)', ahmed.rpc('list_requests', { _scope: 'feed' }));
check('android: pending website request NOT yet visible to donors', !feed?.some((r) => r.id === webReq.id));
await ok('admin: approve website request', admin.rpc('transition_request_status', { _request_id: webReq.id, _to: 'approved' }));
feed = await ok('android: list_requests after approval', ahmed.rpc('list_requests', { _scope: 'feed' }));
const inApp = feed?.find((r) => r.id === webReq.id);
check('android: approved website request now in the app feed', !!inApp);
check('android: signed-in donor sees contact phone', inApp?.contact_phone === '+92 321 5550001');
check('android: received the change in realtime', await waitFor(() => ahmedRt.events.some((e) => e.new?.id === webReq.id && e.new?.status === 'approved')));
const pub = await ok('website: list_public_requests', website.rpc('list_public_requests', {}));
check('website (anonymous) listing shows it without contact details', pub?.some((r) => r.id === webReq.id) && !('contact_phone' in (pub?.[0] ?? {})));

// ── 5–6: Android request → website + dashboard ──────────────────────────────
S('5. Android creates a blood request');
const appReq = (await ok('android: submit_blood_request (source=android, same payload as api.createRequest)',
  kamran.rpc('submit_blood_request', { p: { patient_name: 'E2E App Patient', blood_group: 'O-', units: 2, urgency: 'critical',
    hospital_name: 'Aga Khan University Hospital', hospital_address: 'Stadium Road', city: 'Karachi', contact_name: 'Kamran Siddiqui',
    contact_phone: '+92-333-1239876', description: 'Created by the e2e test from the Android flow', source: 'android' } })))?.[0];
check('android: unverified user request is pending review', appReq?.status === 'pending');
const mine = await ok('android: requester sees own pending request (list_requests mine)', kamran.rpc('list_requests', { _scope: 'mine' }));
check('android: own request flagged is_mine', mine?.some((r) => r.id === appReq.id && r.is_mine));

S('6. Android request appears on the dashboard and website');
check('dashboard got the Android request in realtime', await waitFor(() => adminRt.events.some((e) => e.eventType === 'INSERT' && e.new?.id === appReq.id)));
const androidList = await ok('admin: admin_list_requests(source=android)', admin.rpc('admin_list_requests', { _source: 'android', _search: 'E2E App' }));
check('dashboard lists it with source=android', androidList?.rows?.[0]?.id === appReq.id && androidList.rows[0].source === 'android');
await ok('admin: approve + activate the Android request', admin.rpc('transition_request_status', { _request_id: appReq.id, _to: 'approved' }));
await admin.rpc('transition_request_status', { _request_id: appReq.id, _to: 'active' });
const pub2 = await ok('website: list_public_requests', website.rpc('list_public_requests', { _urgent_only: true }));
check('website public listing shows the Android request', pub2?.some((r) => r.id === appReq.id));

// ── 7–8: admin approval syncs everywhere ────────────────────────────────────
S('7. Admin approves a request');
const kamranNotifs = await ok('android: requester notifications', kamran.from('notifications').select('title,link').order('created_at', { ascending: false }));
check('requester notified "Request Approved"', kamranNotifs?.some((n) => n.title === 'Request Approved'));
await denied('reject without reason is refused', admin.rpc('transition_request_status', { _request_id: webReq.id, _to: 'rejected' }), /reason/i);
const det = await ok('admin: history after approve/activate', admin.rpc('admin_get_request', { _id: appReq.id }));
check('history: pending → approved → active', det?.history?.map((h) => h.to).join(',') === 'pending,approved,active', det?.history?.map((h) => h.to).join(','));

S('8. Both platforms display the updated status');
const appView = (await ok('android: list_requests(_id)', ahmed.rpc('list_requests', { _id: appReq.id })))?.[0];
check('android shows active', appView?.status === 'active');
const webView = (await website.rpc('list_public_requests', {})).data?.find((r) => r.id === appReq.id);
check('website shows active', webView?.status === 'active');
await ok('android: donor responds', ahmed.rpc('respond_to_request', { _request_id: appReq.id }));
await ok('android: requester marks fulfilled', kamran.rpc('transition_request_status', { _request_id: appReq.id, _to: 'fulfilled' }));
const adminAfter = await ok('admin: sees fulfilled + 1 response', admin.rpc('admin_get_request', { _id: appReq.id }));
check('dashboard shows fulfilled with the donor response', adminAfter?.status === 'fulfilled' && adminAfter?.responses?.length === 1);
const pubAfter = (await website.rpc('list_public_requests', {})).data ?? [];
check('website hides fulfilled requests from the open list', !pubAfter.some((r) => r.id === appReq.id));
await ok('admin: an approved (published, not yet activated) request can be fulfilled directly', admin.rpc('transition_request_status', { _request_id: webReq.id, _to: 'fulfilled' }));

// ── 9–10: availability ──────────────────────────────────────────────────────
S('9. Donor updates availability (Android)');
const before = (await website.rpc('search_donors', { _query: 'Zainab' })).data?.[0];
check('website sees Zainab available before', before?.availability === 'available', JSON.stringify(before));
await ok('android: set_my_availability(busy)', zainab.rpc('set_my_availability', { _status: 'busy' }));
const zProfile = await ok('android: get_my_profile reflects busy', zainab.rpc('get_my_profile'));
check('android profile shows busy', zProfile?.donor?.availability === 'busy');

S('10. Website reflects the new availability');
const after = (await website.rpc('search_donors', { _query: 'Zainab' })).data?.[0];
check('website search shows busy', after?.availability === 'busy');
const availOnly = (await website.rpc('search_donors', { _available_only: true, _blood_group: 'AB+' })).data ?? [];
check('website "available donors" list excludes her now', !availOnly.some((d) => d.full_name === 'Zainab Farooq'));
check('website received the availability change in realtime', await waitFor(() => websiteAvailRt.events.some((e) => e.new?.status === 'busy')));
check('realtime payload to anonymous visitors has no private columns', websiteAvailRt.events.every((e) => !('note' in (e.new ?? {})) && !('updated_by' in (e.new ?? {}))));
await ok('admin: admin_set_donor_availability → available', admin.rpc('admin_set_donor_availability', { _donor_id: after.id, _status: 'available' }));
check('website reflects the admin change', (await website.rpc('search_donors', { _query: 'Zainab' })).data?.[0]?.availability === 'available');

// ── 11: unauthorized admin operations ───────────────────────────────────────
S('11. Unauthorized users cannot perform admin operations');
await denied('anonymous: admin_dashboard_stats', website.rpc('admin_dashboard_stats'), /permission denied|sign in/i);
await denied('anonymous: approve request', website.rpc('transition_request_status', { _request_id: webReq.id, _to: 'approved' }), /permission denied|sign in/i);
await denied('anonymous: read blood_requests table directly', website.from('blood_requests').select('*'), /permission denied/);
await denied('donor: admin_list_users', ahmed.rpc('admin_list_users', {}), /Admin access/);
const openReq = (await website.rpc('submit_blood_request', { p: { patient_name: 'Open Request', blood_group: 'A+', contact_phone: '+92 300 4440001', hospital_name: 'Indus Hospital', city: 'Karachi' } })).data?.[0];
await denied('donor: approve someone else\'s pending request', ahmed.rpc('transition_request_status', { _request_id: openReq.id, _to: 'approved' }), /own requests|Only admins/);
await admin.rpc('transition_request_status', { _request_id: openReq.id, _to: 'approved' });
await denied('donor: cancel someone else\'s live request', ahmed.rpc('transition_request_status', { _request_id: openReq.id, _to: 'cancelled' }), /own requests/);
await denied('donor: grant self admin', ahmed.rpc('admin_set_user_role', { _user_id: zProfile.id, _role: 'admin', _grant: true }), /Admin access/);
await denied('donor: change hospital inventory', ahmed.rpc('set_hospital_inventory', { _hospital_id: (await website.rpc('list_hospitals')).data[0].id, _blood_group: 'O+', _units: 999 }), /Not allowed/);
await denied('donor: create hospital', ahmed.rpc('admin_upsert_hospital', { p: { name: 'Fake Hospital', type: 'private', address: 'Fake Road 1', city: 'Karachi' } }), /Admin access/);
await denied('donor: broadcast notification', ahmed.rpc('admin_send_notification', { _audience: 'all', _title: 'Spam', _body: 'Spam message' }), /Admin access/);
const selfVerify = await ahmed.from('profiles').update({ is_verified: true }).eq('id', (await ahmed.auth.getUser()).data.user.id);
check('donor: cannot self-verify via table update', !!selfVerify.error, 'update succeeded');
check('donor: audit logs return nothing', ((await ahmed.from('audit_logs').select('*')).data ?? []).length === 0);
await denied('donor: admin_list_logs', ahmed.rpc('admin_list_logs', {}), /Admin access/);

// ── 12: private data isolation ──────────────────────────────────────────────
S("12. Users cannot access another user's protected information");
const kamranId = (await kamran.auth.getUser()).data.user.id;
check("profiles: Ahmed cannot read Kamran's profile", ((await ahmed.from('profiles').select('*').eq('id', kamranId)).data ?? []).length === 0);
check("notifications: Ahmed cannot read Kamran's notifications", ((await ahmed.from('notifications').select('*').eq('user_id', kamranId)).data ?? []).length === 0);
const del = await ahmed.from('notifications').delete().eq('user_id', kamranId).select();
check("notifications: Ahmed cannot delete Kamran's notifications", (del.data ?? []).length === 0 && ((await kamran.from('notifications').select('id')).data ?? []).length > 0);
const upd = await ahmed.from('profiles').update({ full_name: 'Hacked' }).eq('id', kamranId).select();
check("profiles: Ahmed cannot edit Kamran's profile", (upd.data ?? []).length === 0);
const ahmedDonorId = (await ahmed.rpc('get_my_profile')).data?.donor?.id;
check("donations: Ahmed only sees his own donations", ((await ahmed.from('donations').select('donor_id')).data ?? []).every((d) => d.donor_id === ahmedDonorId));
const kamranPending = (await kamran.rpc('submit_blood_request', { p: { patient_name: 'Private Pending', blood_group: 'A+', contact_phone: '+92-333-1239876', hospital_name: 'Indus Hospital', city: 'Karachi', source: 'android' } })).data?.[0];
check("requests: Ahmed cannot see Kamran's pending request", !((await ahmed.rpc('list_requests', {})).data ?? []).some((r) => r.id === kamranPending?.id));
check('donor contact: anonymous search never returns phone/email', ((await website.rpc('search_donors', {})).data ?? []).every((d) => !('phone' in d) && !('email' in d)));
await denied('donor contact: anonymous cannot reveal phone', website.rpc('get_donor_contact', { _donor_id: after.id }), /sign in|permission denied/i);
const contact = await ok('donor contact: signed-in user can reveal (logged)', kamran.rpc('get_donor_contact', { _donor_id: after.id }));
check('contact reveal returns the phone', !!contact?.[0]?.phone);
const reveals = await ok('admin: contact reveal is in the audit log', admin.rpc('admin_list_logs', { _kind: 'audit', _table: 'contact_reveal', _limit: 5 }));
check('audit has the contact reveal entry', (reveals ?? []).length >= 1);
const upl = await ahmed.storage.from('avatars').upload(`${kamranId}/evil.png`, new Uint8Array([137, 80, 78, 71]), { contentType: 'image/png' });
check("storage: Ahmed cannot write into Kamran's avatar folder", !!upl.error, 'upload succeeded');

// ── extra: website account + app login share one auth system ───────────────
S('Extra. One account system for website and app');
const email = `e2e.${Date.now()}@example.com`;
const reg = await website.auth.signUp({ email, password: 'E2e-password-1', options: { data: { first_name: 'E2E', last_name: 'Donor', user_type: 'donor' } } });
check('website registration (register.html payload)', !reg.error, reg.error?.message);
const appLogin = client();
const li = await appLogin.auth.signInWithPassword({ email, password: 'E2e-password-1' });
check('same credentials sign in on the app', !li.error, li.error?.message);
const newProfile = (await appLogin.rpc('get_my_profile')).data;
check('profile created by the database trigger (name from website fields)', newProfile?.full_name === 'E2E Donor' && newProfile?.account_type === 'donor');
await ok('app: complete donor profile via update_my_profile', appLogin.rpc('update_my_profile', { p: { blood_group: 'A-', city: 'Lahore', phone: '+92 300 7777777', account_type: 'donor' } }));
check('donor record created → discoverable on the website', ((await website.rpc('search_donors', { _query: 'E2E Donor' })).data ?? []).length === 1);
const app2 = await website.rpc('submit_donor_application', { p: { full_name: 'E2E Applicant', email: `app.${Date.now()}@example.com`, phone: '+92 301 1234567', age: 30, gender: 'female', blood_group: 'B-', city: 'Multan' } });
check('website donor application submitted', !app2.error, app2.error?.message);
await ok('admin: approve application', admin.rpc('admin_review_donor_application', { _application_id: app2.data[0].id, _approve: true }));
check('approved applicant visible in the app donor list', ((await ahmed.rpc('search_donors', { _query: 'E2E Applicant' })).data ?? []).length === 1);
const msg = await website.rpc('submit_contact_message', { p: { first_name: 'E2E', email: 'contact@example.com', message: 'Hello from the e2e test' } });
check('website contact message stored', !msg.error, msg.error?.message);
check('admin reads contact messages', ((await admin.from('contact_messages').select('id').eq('id', msg.data)).data ?? []).length === 1);
const h = (await website.rpc('list_hospitals')).data[0];
const invRt = await listen(ahmed, 'hospital_inventory');
await ok('admin: update inventory', admin.rpc('set_hospital_inventory', { _hospital_id: h.id, _blood_group: 'AB-', _units: 17 }));
check('app sees new inventory', (await ahmed.rpc('list_hospitals', { _id: h.id })).data?.[0]?.inventory?.['AB-'] === 17);
check('app received inventory change in realtime', await waitFor(() => invRt.events.some((e) => e.new?.blood_group === 'AB-' && e.new?.units === 17)));

// ── extra: two brand-new app accounts (request visibility, donors, realtime) ─
S('Extra. Two new app accounts: request visibility, donor list, realtime');
const stamp = Date.now();
async function appSignup(label, meta) {
  const c = client();
  const em = `${label}.${stamp}@example.com`;
  const r = await c.auth.signUp({ email: em, password: 'Two-accounts-1', options: { data: meta } });
  if (!r.error && !r.data?.session) await c.auth.signInWithPassword({ email: em, password: 'Two-accounts-1' });
  return { c, error: r.error, id: (await c.auth.getUser()).data.user?.id };
}
// Same metadata as the app's Register screen (services/api.ts signUp).
const userA = await appSignup('usera', { full_name: 'Two Acc A', account_type: 'both', phone: '+92 300 1110001', blood_group: 'B+', city: 'Karachi', area: 'Clifton' });
const userB = await appSignup('userb', { full_name: 'Two Acc B', account_type: 'both', phone: '+92 300 1110002', blood_group: 'O-', city: 'Lahore', area: 'Gulberg' });
check('user A and user B signed up with the app payload', !userA.error && !userB.error && !!userA.id && !!userB.id, userA.error?.message ?? userB.error?.message);
const bRt = await listen(userB.c, 'blood_requests');
const feedOf = async (u, id) => ((await u.c.rpc('list_requests', { _scope: 'feed', _limit: 300 })).data ?? []).find((r) => r.id === id);
const mineOf = async (u, id) => ((await u.c.rpc('list_requests', { _scope: 'mine' })).data ?? []).find((r) => r.id === id);
const reqOf = (patient) => ({ p: { patient_name: patient, blood_group: 'B+', units: 1, urgency: 'urgent', hospital_name: 'Two Account Hospital', hospital_address: 'Clifton', city: 'Karachi', contact_name: 'Two Acc A', contact_phone: '+92 300 1110001', description: 'two-account test', source: 'android' } });

const rA = (await ok('A (unverified) creates a request (app payload)', userA.c.rpc('submit_blood_request', reqOf('Two Acc Patient One'))))?.[0];
check('A request starts pending (unverified account → admin review)', rA?.status === 'pending', rA?.status);
check('A sees it in the feed (is_mine) and in My Requests', (await feedOf(userA, rA.id))?.is_mine === true && !!(await mineOf(userA, rA.id)));
check('B does not see A pending request', !(await feedOf(userB, rA.id)));
await sleep(600);
check('B received no realtime event for the pending request', !bRt.events.some((e) => e.new?.id === rA.id));
await ok('admin approves A request', admin.rpc('transition_request_status', { _request_id: rA.id, _to: 'approved' }));
check('B received the approval in realtime', await waitFor(() => bRt.events.some((e) => e.new?.id === rA.id && e.new?.status === 'approved')));
const seenByB = await feedOf(userB, rA.id);
check('B now sees A request in the feed, not marked as B\'s', !!seenByB && seenByB.is_mine === false);
check('A request is not in B\'s My Requests', !(await mineOf(userB, rA.id)));
await denied('B cannot cancel A request', userB.c.rpc('transition_request_status', { _request_id: rA.id, _to: 'cancelled' }), /only update your own/);
await denied('B cannot delete A request', userB.c.rpc('admin_delete_request', { _request_id: rA.id }), /Admin access/);

await ok('admin verifies A', admin.rpc('admin_set_verified', { _user_id: userA.id, _verified: true }));
const rA2 = (await ok('A (verified) creates another request', userA.c.rpc('submit_blood_request', reqOf('Two Acc Patient Two'))))?.[0];
check('verified account request goes live immediately', rA2?.status === 'active', rA2?.status);
check('B received the new live request in realtime (INSERT)', await waitFor(() => bRt.events.some((e) => e.eventType === 'INSERT' && e.new?.id === rA2.id)));
check('B sees it in the feed without restarting', !!(await feedOf(userB, rA2.id)));

const donorNames = async (u) => ((await u.c.rpc('search_donors', { _limit: 100 })).data ?? []).map((d) => d.full_name);
check('B sees A in the donor list', (await donorNames(userB)).includes('Two Acc A'));
check('A sees B in the donor list', (await donorNames(userA)).includes('Two Acc B'));
// Website sign-up as "donor" (no blood group / city) → listed once the profile is completed (migration 0008).
const W = await appSignup('webdonor', { first_name: 'Twoacc', last_name: 'Webdonor', user_type: 'donor' });
check('website donor sign-up not listed before blood group + city', !W.error && !(await donorNames(userB)).includes('Twoacc Webdonor'), W.error?.message);
const availRt = await listen(userB.c, 'donor_availability');
await ok('website donor adds blood group + city (profile save without account_type)', W.c.rpc('update_my_profile', { p: { blood_group: 'AB+', city: 'Karachi' } }));
check('B notified in realtime (donor_availability INSERT → donor list refresh)', await waitFor(() => availRt.events.some((e) => e.eventType === 'INSERT')));
check('B now sees the website donor in the donor list', (await donorNames(userB)).includes('Twoacc Webdonor'));
bRt.close();
availRt.close();

// ── extra: GPS nearby donors + emergency push alerts (migration 0009 + Edge Function core) ─
S('Extra. GPS nearby donors, request locations and emergency alerts');
const geoTag = Date.now().toString(36);
const geoUser = async (label, meta) => appSignup(`${label}.${geoTag}`, { account_type: 'both', city: 'Karachi', ...meta });
const KHI = { lat: 24.8607, lng: 67.0011 };
const near = (dLat, dLng) => ({ lat: KHI.lat + dLat, lng: KHI.lng + dLng });
const optIn = async (u, p) => {
  const a = await u.c.rpc('set_nearby_discovery', { _enabled: true });
  const b = await u.c.rpc('set_my_location', { _lat: p.lat, _lng: p.lng, _accuracy_m: 20, _source: 'gps' });
  return a.error?.message ?? b.error?.message ?? null;
};
const token = (s) => `ExponentPushToken[e2e${s}${geoTag}xxxxxxxx]`;
// Test 1 donor: O- ≈3 km · incompatible A+ ≈2 km · O+ ≈60 km · O+ who never opted in
const gA = await geoUser('geoa', { full_name: 'Geo Donor A', blood_group: 'O-', phone: '+92 300 4440001' });
const gC = await geoUser('geoc', { full_name: 'Geo Donor C', blood_group: 'A+', phone: '+92 300 4440003' });
const gD = await geoUser('geod', { full_name: 'Geo Donor D', blood_group: 'O+', phone: '+92 300 4440004' });
const gE = await geoUser('geoe', { full_name: 'Geo Donor E', blood_group: 'O+', phone: '+92 300 4440005' });
const gB = await geoUser('geob', { full_name: 'Geo Requester B', blood_group: 'AB+', phone: '+92 300 4440002' });
check('test 1: donor A enables discovery and shares GPS location', (await optIn(gA, near(0.027, 0))) === null);
check('setup: incompatible donor C (2 km) and far donor D (60 km) share locations', (await optIn(gC, near(0.018, 0))) === null && (await optIn(gD, near(0.54, 0))) === null);
for (const [u, t] of [[gA, 'a'], [gC, 'c'], [gD, 'd'], [gE, 'e']]) await u.c.rpc('register_push_token', { _token: token(t), _platform: 'android' });
check('test 1: donor A device push token registered', !(await gA.c.from('device_push_tokens').select('token')).error);

// Test 5: request with a location picked on the map, from the app (unverified → pending)
const geoReq = (await ok('test 5: B creates an urgent B+ request with a picked location (app payload)', gB.c.rpc('submit_blood_request', { p: {
  patient_name: 'Geo E2E Patient', blood_group: 'B+', units: 2, urgency: 'urgent', hospital_name: 'Geo E2E Hospital', hospital_address: 'Clifton',
  city: 'Karachi', contact_name: 'Geo Requester B', contact_phone: '+92 300 4440002', description: 'e2e location test', source: 'android',
  latitude: KHI.lat, longitude: KHI.lng, location_label: 'Geo E2E Hospital, Clifton' } })))?.[0];
const geoMine = ((await gB.c.rpc('list_requests', { _scope: 'mine', _id: geoReq.id })).data ?? [])[0];
check('test 5: coordinates and label stored and returned to the app', Number(geoMine?.latitude) === KHI.lat && Number(geoMine?.longitude) === KHI.lng && geoMine?.location_label === 'Geo E2E Hospital, Clifton', JSON.stringify(geoMine));
check('pending request is not on the public map yet', !((await website.rpc('list_request_locations', {})).data ?? []).some((r) => r.id === geoReq.id));

// publish → matching
await ok('admin publishes the request', admin.rpc('transition_request_status', { _request_id: geoReq.id, _to: 'approved' }));
const svc = createClient(URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const alertsFor = async (u) => (await u.c.from('emergency_alerts').select('request_id,status,distance_km,radius_km,last_error').eq('request_id', geoReq.id)).data ?? [];
const aAlert = (await alertsFor(gA))[0];
check('test 1: compatible donor A within the radius is queued', aAlert?.status === 'queued' && Number(aAlert.distance_km) < 4, JSON.stringify(aAlert));
check('test 3: incompatible donor C (A+) is not alerted', (await alertsFor(gC)).length === 0);
check('test 2: donor D 60 km away (outside even the widest radius) is not alerted', (await alertsFor(gD)).length === 0);
check('donor E who never opted in to location is not alerted for a located request', (await alertsFor(gE)).length === 0);

// deliver with the Edge Function core against this server (Expo mocked)
const sentMessages = [];
const fakeExpo = async (url, init) => {
  const msgs = JSON.parse(init.body);
  sentMessages.push(...msgs);
  return { ok: true, status: 200, json: async () => ({ data: msgs.map((m, i) => ({ status: 'ok', id: `e2e-ticket-${i}` })) }) };
};
const alertDb = {
  secret: async () => 'unused',
  claim: async (rid, limit) => { const r = await svc.rpc('_claim_queued_alerts', { _request_id: rid, _limit: limit }); if (r.error) throw new Error(r.error.message); return r.data; },
  complete: async (results) => { const r = await svc.rpc('_complete_alerts', { _results: results }); if (r.error) throw new Error(r.error.message); return r.data; },
};
await denied('anonymous visitors cannot claim alerts', website.rpc('_claim_queued_alerts', {}), /permission denied/);
const summary = await dispatchAlerts({ db: alertDb, fetch: fakeExpo, requestId: geoReq.id });
const toA = sentMessages.find((m) => m.to === token('a'));
check('test 1: push message built for donor A (urgent, blood group, deep link)', !!toA && toA.title === 'Urgent: B+ blood needed' && toA.data.request_id === geoReq.id && toA.channelId === 'emergency', JSON.stringify(toA));
check('test 1/2/3: only donor A was sent a push', summary.sent === 1 && sentMessages.length === 1, JSON.stringify(summary));
check('delivery recorded as sent for donor A', (await alertsFor(gA))[0]?.status === 'sent');
await ok('admin activates the request (approved → active)', admin.rpc('transition_request_status', { _request_id: geoReq.id, _to: 'active' }));
check('no duplicate alert for the same request', (await alertsFor(gA)).length === 1);

// Test 4: disabling discovery removes the donor from nearby results
const nearbyNames = async (client) => ((await client.rpc('nearby_donors', { _lat: KHI.lat, _lng: KHI.lng, _radius_km: 10 })).data ?? []).map((d) => d.full_name);
check('donor A is listed nearby (website, anonymous)', (await nearbyNames(website)).includes('Geo Donor A'));
check('test 7: website (anonymous) and app (signed-in) get the same nearby donors', JSON.stringify((await nearbyNames(website)).sort()) === JSON.stringify((await nearbyNames(zainab)).sort()));
check('test 7: published request appears on the shared map data', ((await website.rpc('list_request_locations', { _lat: KHI.lat, _lng: KHI.lng, _radius_km: 10 })).data ?? []).some((r) => r.id === geoReq.id));
await ok('test 4: donor C turns discovery off', gC.c.rpc('set_nearby_discovery', { _enabled: false }));
check('test 4: donor C no longer appears nearby', !(await nearbyNames(website)).includes('Geo Donor C'));
const pubDonor = ((await website.rpc('nearby_donors', { _lat: KHI.lat, _lng: KHI.lng, _radius_km: 10 })).data ?? []).find((d) => d.full_name === 'Geo Donor A');
check('privacy: nearby results carry only rounded positions, no phone/email', pubDonor && Number(pubDonor.approx_lat) === 24.89 && !('phone' in pubDonor) && !('email' in pubDonor) && !('latitude' in pubDonor), JSON.stringify(pubDonor));

// ── report ──────────────────────────────────────────────────────────────────
for (const c of [adminRt, ahmedRt, websiteAvailRt, invRt]) c.close();
let current = '';
for (const r of results) {
  if (r.scenario !== current) { current = r.scenario; console.log(`\n${current}`); }
  console.log(`  ${r.ok ? '✓' : '✗'} ${r.name}${r.ok ? '' : `\n      ${r.why}`}`);
}
const passed = results.filter((r) => r.ok).length;
console.log(`\n${passed}/${results.length} end-to-end checks passed${argUrl ? '' : ' (local dev server, in-memory database)'}`);
server?.kill();
process.exit(passed === results.length ? 0 : 1);
