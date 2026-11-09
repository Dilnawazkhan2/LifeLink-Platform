// ============================================================================
// Post-deployment check for a REAL Supabase project (read-only, anonymous).
//
//   npm run verify:cloud -- https://YOUR-PROJECT-REF.supabase.co YOUR-PUBLISHABLE-OR-ANON-KEY
//
// Uses only the public key, writes nothing, creates no accounts. Confirms the
// schema is deployed, the public API works, and anonymous visitors are locked
// out of private data and admin functions (RLS + function grants).
// Optional: add an admin email + password as 3rd/4th args to also check that
// the admin account works (signs in, reads stats, signs out — still read-only).
// ============================================================================
import { createClient } from '@supabase/supabase-js';

const [url, key, adminEmail, adminPassword] = process.argv.slice(2);
if (!url || !key) {
  console.error('Usage: npm run verify:cloud -- <project-url> <publishable-or-anon-key> [admin-email admin-password]');
  process.exit(2);
}
if (/service_role|sb_secret_/.test(key) || (() => { try { return JSON.parse(Buffer.from(key.split('.')[1], 'base64url')).role === 'service_role'; } catch { return false; } })()) {
  console.error('✗ That is a SECRET (service_role) key. Use the publishable/anon key. Rotate the secret key if it was shared anywhere.');
  process.exit(2);
}

const sb = createClient(url, key, { auth: { persistSession: false } });
const results = [];
const check = (name, ok, detail = '') => { results.push(ok); console.log(`  ${ok ? '✓' : '✗'} ${name}${ok || !detail ? '' : `\n      ${detail}`}`); };

console.log(`\nVerifying ${url}\n`);
const h = await sb.rpc('list_hospitals');
check('schema deployed: list_hospitals works', !h.error && Array.isArray(h.data), h.error?.message);
check('reference data loaded (partner hospitals)', (h.data?.length ?? 0) > 0, 'No hospitals — run seeds/reference.sql or add hospitals in the dashboard');
const d = await sb.rpc('search_donors', { _limit: 5 });
check('public donor search works', !d.error, d.error?.message);
check('donor search exposes no phone/email', (d.data ?? []).every((x) => !('phone' in x) && !('email' in x)));
const p = await sb.rpc('list_public_requests', {});
check('public request list works (no contact details)', !p.error && (p.data ?? []).every((x) => !('contact_phone' in x)), p.error?.message);
const s = await sb.rpc('public_stats');
check('public_stats works', !s.error, s.error?.message);

const t = await sb.from('blood_requests').select('id').limit(1);
check('anonymous cannot read blood_requests table', !!t.error || (t.data ?? []).length === 0, 'rows were returned');
const pr = await sb.from('profiles').select('id').limit(1);
check('anonymous cannot read profiles', !!pr.error || (pr.data ?? []).length === 0, 'rows were returned');
const a = await sb.rpc('admin_dashboard_stats');
check('anonymous cannot call admin functions', !!a.error, 'admin_dashboard_stats succeeded');
const c = await sb.rpc('get_donor_contact', { _donor_id: '00000000-0000-0000-0000-000000000000' });
check('anonymous cannot reveal donor phone numbers', !!c.error, 'get_donor_contact succeeded');
const al = await sb.from('audit_logs').select('id').limit(1);
check('anonymous cannot read audit logs', !!al.error || (al.data ?? []).length === 0, 'rows were returned');

if (adminEmail && adminPassword) {
  const li = await sb.auth.signInWithPassword({ email: adminEmail, password: adminPassword });
  check('admin account signs in', !li.error, li.error?.message);
  const me = await sb.rpc('get_my_profile');
  check('admin account has the admin role', (me.data?.roles ?? []).includes('admin'), 'Run in SQL editor: select public.bootstrap_admin(\'' + adminEmail + '\');');
  const st = await sb.rpc('admin_dashboard_stats');
  check('admin can read dashboard stats', !st.error, st.error?.message);
  await sb.auth.signOut();
}

const passed = results.filter(Boolean).length;
console.log(`\n${passed}/${results.length} checks passed`);
process.exit(passed === results.length ? 0 : 1);
