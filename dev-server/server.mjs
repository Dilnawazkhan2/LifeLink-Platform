// ============================================================================
// LifeLink LOCAL DEV SERVER — a Supabase-compatible API on top of PGlite.
//
//   npm run dev        → http://127.0.0.1:54321  (API: auth, rest, rpc, realtime, storage)
//                        http://127.0.0.1:5500   (LifeLink website + admin dashboard)
//
// It runs the SAME SQL migrations, RLS policies and RPC functions as the real
// Supabase project, so the website, the Android app and the admin dashboard can
// be developed and tested end-to-end without Docker or a cloud account.
//
// DEVELOPMENT ONLY. It implements just the subset of the Supabase HTTP API the
// LifeLink clients use. Production uses a real Supabase project (see SETUP_GUIDE.md).
// ============================================================================
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { WebSocketServer } from 'ws';
import { openDatabase, createQueue } from './db.mjs';

const ROOT = path.resolve(import.meta.dirname, '..');
const PORT = Number(process.env.PORT ?? 54321);
const WEB_PORT = Number(process.env.WEB_PORT ?? 5500);
const HOST = process.env.HOST ?? '0.0.0.0'; // reachable from a phone on the same Wi-Fi
const DATA_DIR = process.env.DATA_DIR ?? path.join(ROOT, 'dev-server/.data');
// The website folder was renamed from "demo test" to "LifeLink Web"; accept either.
const WEBSITE_DIR = process.env.WEBSITE_DIR
  ?? ['../LifeLink Website/LifeLink Web', '../LifeLink Website/demo test'].map((p) => path.resolve(ROOT, p)).find((p) => fs.existsSync(p))
  ?? path.resolve(ROOT, '../LifeLink Website/LifeLink Web');
const IN_MEMORY = process.argv.includes('--memory');
const QUIET = process.argv.includes('--quiet');
const log = (...a) => { if (!QUIET) console.log(...a); };

// ── Keys (fixed so client configs can hard-code them for local dev) ─────────
const JWT_SECRET = 'lifelink-local-dev-jwt-secret-NOT-FOR-PRODUCTION-0001';
const b64u = (v) => Buffer.from(typeof v === 'string' ? v : JSON.stringify(v)).toString('base64url');
function signJwt(payload) {
  const head = b64u({ alg: 'HS256', typ: 'JWT' });
  const body = b64u(payload);
  const sig = crypto.createHmac('sha256', JWT_SECRET).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${sig}`;
}
function verifyJwt(token) {
  const parts = String(token ?? '').split('.');
  if (parts.length !== 3) return null;
  const expected = crypto.createHmac('sha256', JWT_SECRET).update(`${parts[0]}.${parts[1]}`).digest();
  const given = Buffer.from(parts[2], 'base64url');
  if (given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) return null;
  try {
    const p = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
    if (p.exp && p.exp * 1000 < Date.now()) return null;
    return p;
  } catch { return null; }
}
export const ANON_KEY = signJwt({ iss: 'lifelink-dev', role: 'anon', iat: 1762646400, exp: 2077920000 });
// Dev-only service-role key (bypasses RLS), used by tests to run the Edge Function's delivery logic
// against this server. Like the anon key it only works here: the secret is a public dev constant.
export const SERVICE_ROLE_KEY = signJwt({ iss: 'lifelink-dev', role: 'service_role', iat: 1762646400, exp: 2077920000 });
const ACCESS_TTL = 3600;

// ── Database ─────────────────────────────────────────────────────────────────
const db = await openDatabase({ dataDir: IN_MEMORY ? undefined : path.join(DATA_DIR, 'pg'), supabaseDir: path.join(ROOT, 'supabase'), log });
const queue = createQueue();

/** Run fn inside a transaction as the caller (same as PostgREST: role + JWT claims, local to the tx). */
function asCaller(ctx, fn) {
  return queue(() => db.transaction(async (tx) => {
    await tx.query(
      `select set_config('request.jwt.claims', $1, true), set_config('request.jwt.claim.sub', $2, true), set_config('role', $3, true)`,
      [JSON.stringify(ctx.claims), ctx.sub ?? '', ctx.role],
    );
    return fn(tx);
  }));
}
const asAdmin = (fn) => queue(() => db.transaction(fn));

// function + table metadata (cached)
const meta = { fns: new Map(), tables: new Set() };
async function loadMeta() {
  const fns = await db.query(`
    select p.proname as name, p.proretset as retset, t.typtype, format_type(p.prorettype, null) as rettype,
           coalesce(p.proargnames, '{}') as argnames, coalesce(p.proargmodes::text[], '{}') as argmodes,
           array(select format_type(x, null) from unnest(p.proargtypes::oid[]) x) as argtypes
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_type t on t.oid = p.prorettype
    where n.nspname = 'public'`);
  meta.fns.clear();
  for (const f of fns.rows) {
    const inputNames = f.argmodes.length ? f.argnames.filter((_, i) => ['i', 'b', 'v'].includes(f.argmodes[i])) : f.argnames;
    meta.fns.set(f.name, { ...f, args: inputNames.map((n, i) => ({ name: n, type: f.argtypes[i] })) });
  }
  meta.tables = new Set((await db.query(`select tablename from pg_tables where schemaname = 'public'
                                          union select viewname from pg_views where schemaname = 'public'`)).rows.map((r) => r.tablename));
}
await loadMeta();

// ── HTTP helpers ─────────────────────────────────────────────────────────────
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, prefer, range, accept-profile, content-profile, x-supabase-api-version, x-upsert, cache-control, x-retry-count',
  'Access-Control-Expose-Headers': 'content-range, content-location, x-supabase-api-version',
  'Access-Control-Max-Age': '86400',
};
function send(res, status, body, headers = {}) {
  const isBuf = Buffer.isBuffer(body);
  const payload = body === undefined || body === null ? '' : isBuf ? body : typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, { ...CORS, ...(payload && !isBuf && !headers['Content-Type'] ? { 'Content-Type': 'application/json; charset=utf-8' } : {}), ...headers });
  res.end(payload);
}
async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks);
}
async function readJson(req) {
  const buf = await readBody(req);
  if (!buf.length) return {};
  try { return JSON.parse(buf.toString('utf8')); } catch { throw Object.assign(new Error('Invalid JSON body'), { status: 400, code: 'PGRST102' }); }
}
const ident = (s) => {
  if (!/^[a-z_][a-z0-9_]*$/.test(s)) throw Object.assign(new Error(`Invalid identifier: ${s}`), { status: 400, code: 'PGRST100' });
  return `"${s}"`;
};
function pgError(res, e, ctx) {
  const code = e.code ?? 'XX000';
  let status = e.status ?? 400;
  if (!e.status) {
    if (code === '42501') status = ctx?.role === 'anon' ? 401 : 403;
    else if (code === 'P0002' || code === '42883' || code === '42P01') status = 404;
    else if (code === '23505' || code === '23503') status = 409;
    else if (/^(XX|58)/.test(code)) status = 500;
  }
  send(res, status, { code, message: e.message, details: e.detail ?? null, hint: e.hint ?? null });
}

// ── Caller context from headers ──────────────────────────────────────────────
function callerContext(req, { requireKey = true } = {}) {
  const apikey = req.headers.apikey ?? new URL(req.url, 'http://x').searchParams.get('apikey');
  const bearer = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
  const claims = verifyJwt(bearer);
  if (claims?.role === 'service_role' && apikey === SERVICE_ROLE_KEY) return { role: 'service_role', sub: null, claims };
  if (requireKey && apikey !== ANON_KEY && !(claims?.role === 'anon')) {
    throw Object.assign(new Error('Invalid API key'), { status: 401, code: 'PGRST301' });
  }
  if (claims?.role === 'authenticated' && claims.sub) return { role: 'authenticated', sub: claims.sub, claims };
  return { role: 'anon', sub: null, claims: { role: 'anon' } };
}

// ── PostgREST subset ─────────────────────────────────────────────────────────
const RESERVED = new Set(['select', 'order', 'limit', 'offset', 'on_conflict', 'columns', 'apikey']);
function buildWhere(params, values) {
  const clauses = [];
  for (const [key, raw] of params) {
    if (RESERVED.has(key)) continue;
    if (key === 'or' || key === 'and') throw Object.assign(new Error('or/and filters are not supported by the dev server'), { status: 400, code: 'PGRST100' });
    const col = ident(key);
    let v = raw, neg = false;
    if (v.startsWith('not.')) { neg = true; v = v.slice(4); }
    const dot = v.indexOf('.');
    const op = v.slice(0, dot), val = v.slice(dot + 1);
    const p = () => { values.push(val); return `$${values.length}`; };
    let c;
    switch (op) {
      case 'eq': c = `${col} = ${p()}`; break;
      case 'neq': c = `${col} <> ${p()}`; break;
      case 'gt': c = `${col} > ${p()}`; break;
      case 'gte': c = `${col} >= ${p()}`; break;
      case 'lt': c = `${col} < ${p()}`; break;
      case 'lte': c = `${col} <= ${p()}`; break;
      case 'like': values.push(val.replaceAll('*', '%')); c = `${col}::text like $${values.length}`; break;
      case 'ilike': values.push(val.replaceAll('*', '%')); c = `${col}::text ilike $${values.length}`; break;
      case 'is': c = `${col} is ${({ null: 'null', true: 'true', false: 'false' })[val] ?? 'null'}`; break;
      case 'in': {
        const items = val.replace(/^\(|\)$/g, '').split(',').map((s) => s.trim().replace(/^"|"$/g, '')).filter(Boolean);
        if (!items.length) { c = 'false'; break; }
        c = `${col}::text in (${items.map((it) => { values.push(it); return `$${values.length}::text`; }).join(', ')})`;
        break;
      }
      default: throw Object.assign(new Error(`Unsupported filter operator: ${op}`), { status: 400, code: 'PGRST100' });
    }
    clauses.push(neg ? `not (${c})` : c);
  }
  return clauses.length ? ` where ${clauses.join(' and ')}` : '';
}
function buildSelect(sel) {
  if (!sel || sel === '*') return '*';
  if (sel.includes('(')) throw Object.assign(new Error('Embedded resources are not supported by the dev server — use an RPC.'), { status: 400, code: 'PGRST100' });
  return sel.split(',').map((s) => s.trim()).filter(Boolean).map((s) => {
    const [alias, col] = s.includes(':') ? s.split(':') : [null, s];
    return alias ? `${ident(col)} as ${ident(alias)}` : ident(col);
  }).join(', ');
}
function buildOrder(order) {
  if (!order) return '';
  return ' order by ' + order.split(',').map((part) => {
    const [col, ...mods] = part.split('.');
    let s = ident(col);
    if (mods.includes('desc')) s += ' desc';
    if (mods.includes('nullsfirst')) s += ' nulls first';
    if (mods.includes('nullslast')) s += ' nulls last';
    return s;
  }).join(', ');
}
function prefer(req) {
  const p = {};
  for (const part of String(req.headers.prefer ?? '').split(',')) {
    const [k, v] = part.trim().split('=');
    if (k) p[k] = v ?? true;
  }
  return p;
}
function wantsObject(req) { return String(req.headers.accept ?? '').includes('vnd.pgrst.object'); }
function sendRows(req, res, rows, extraHeaders = {}) {
  if (wantsObject(req)) {
    if (rows.length !== 1) return send(res, 406, { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned', details: `The result contains ${rows.length} rows`, hint: null });
    return send(res, 200, rows[0], extraHeaders);
  }
  send(res, 200, rows, extraHeaders);
}

async function handleRest(req, res, url) {
  const ctx = callerContext(req);
  const rest = url.pathname.slice('/rest/v1/'.length);

  // RPC ----------------------------------------------------------------------
  if (rest.startsWith('rpc/')) {
    const name = rest.slice(4);
    const fn = meta.fns.get(name);
    if (!fn) return send(res, 404, { code: 'PGRST202', message: `Could not find the function public.${name}`, details: null, hint: null });
    let args = {};
    if (req.method === 'GET' || req.method === 'HEAD') {
      for (const [k, v] of url.searchParams) if (!RESERVED.has(k)) args[k] = v;
    } else args = await readJson(req);
    const values = [];
    const parts = [];
    for (const [k, v] of Object.entries(args ?? {})) {
      const a = fn.args.find((x) => x.name === k);
      if (!a) return send(res, 404, { code: 'PGRST202', message: `Could not find the function public.${name}(${Object.keys(args).join(', ')}) in the schema cache`, details: null, hint: null });
      values.push(v === null || v === undefined ? null : /^jsonb?$/.test(a.type) ? JSON.stringify(v) : typeof v === 'object' ? JSON.stringify(v) : String(v));
      parts.push(`${ident(k)} => $${values.length}::${a.type}`);
    }
    const call = `public.${ident(name)}(${parts.join(', ')})`;
    const isRows = fn.retset || fn.typtype === 'c';
    const sql = isRows
      ? `select coalesce(json_agg(t), '[]'::json) as v from ${call} t`
      : `select to_json(${call}) as v`;
    try {
      const out = await asCaller(ctx, async (tx) => (await tx.query(sql, values)).rows[0].v);
      if (fn.rettype === 'void') return send(res, 204, null);
      if (isRows && fn.typtype === 'c' && !fn.retset) return send(res, 200, out[0] ?? null);
      return isRows ? sendRows(req, res, out) : send(res, 200, JSON.stringify(out ?? null), { 'Content-Type': 'application/json; charset=utf-8' });
    } catch (e) { return pgError(res, e, ctx); }
  }

  // Tables -------------------------------------------------------------------
  const table = decodeURIComponent(rest);
  if (!meta.tables.has(table)) return send(res, 404, { code: '42P01', message: `relation "public.${table}" does not exist`, details: null, hint: null });
  const t = `public.${ident(table)}`;
  const pref = prefer(req);
  const values = [];
  try {
    if (req.method === 'GET' || req.method === 'HEAD') {
      const where = buildWhere(url.searchParams, values);
      const cols = buildSelect(url.searchParams.get('select'));
      const order = buildOrder(url.searchParams.get('order'));
      const limit = url.searchParams.get('limit') ? ` limit ${Math.max(0, parseInt(url.searchParams.get('limit'), 10) || 0)}` : '';
      const offset = url.searchParams.get('offset') ? ` offset ${Math.max(0, parseInt(url.searchParams.get('offset'), 10) || 0)}` : '';
      const { rows, count } = await asCaller(ctx, async (tx) => {
        const rows = req.method === 'HEAD' ? [] :
          (await tx.query(`select coalesce(json_agg(t), '[]'::json) as v from (select ${cols} from ${t}${where}${order}${limit}${offset}) t`, values)).rows[0].v;
        const count = pref.count ? Number((await tx.query(`select count(*)::int as n from ${t}${where}`, values)).rows[0].n) : null;
        return { rows, count };
      });
      const start = Number(url.searchParams.get('offset') ?? 0);
      const range = count !== null ? `${rows.length ? `${start}-${start + rows.length - 1}` : '*'}/${count}` : `${rows.length ? `0-${rows.length - 1}` : '*'}/*`;
      if (req.method === 'HEAD') return send(res, 200, null, { 'Content-Range': range });
      return sendRows(req, res, rows, { 'Content-Range': range });
    }
    if (req.method === 'POST') {
      const body = await readJson(req);
      const rowsIn = Array.isArray(body) ? body : [body];
      const cols = url.searchParams.get('columns')?.split(',') ?? [...new Set(rowsIn.flatMap((r) => Object.keys(r)))];
      const colSql = cols.map(ident).join(', ');
      values.push(JSON.stringify(rowsIn));
      let conflict = '';
      if (pref.resolution === 'merge-duplicates' || pref.resolution === 'ignore-duplicates') {
        const on = (url.searchParams.get('on_conflict') ?? '').split(',').filter(Boolean).map(ident).join(', ');
        if (!on) throw Object.assign(new Error('on_conflict is required for upserts on the dev server'), { status: 400, code: 'PGRST100' });
        conflict = pref.resolution === 'ignore-duplicates' ? ` on conflict (${on}) do nothing`
          : ` on conflict (${on}) do update set ${cols.map((c) => `${ident(c)} = excluded.${ident(c)}`).join(', ')}`;
      }
      const sql = `with t as (insert into ${t} (${colSql}) select ${colSql} from json_populate_recordset(null::${t}, $1::json)${conflict} returning *)
                   select coalesce(json_agg(t), '[]'::json) as v from t`;
      const rows = await asCaller(ctx, async (tx) => (await tx.query(sql, values)).rows[0].v);
      return pref.return === 'representation' ? sendRows(req, res, rows) : send(res, 201, null);
    }
    if (req.method === 'PATCH') {
      const body = await readJson(req);
      const cols = Object.keys(body);
      if (!cols.length) return send(res, 400, { code: 'PGRST100', message: 'Empty update', details: null, hint: null });
      values.push(JSON.stringify(body));
      const where = buildWhere(url.searchParams, values);
      if (!where) return send(res, 400, { code: '21000', message: 'UPDATE requires a WHERE clause', details: null, hint: null });
      const colSql = cols.map(ident).join(', ');
      const sql = `with t as (update ${t} set (${colSql}) = (select ${colSql} from json_populate_record(null::${t}, $1::json))${where} returning *)
                   select coalesce(json_agg(t), '[]'::json) as v from t`;
      const rows = await asCaller(ctx, async (tx) => (await tx.query(sql, values)).rows[0].v);
      return pref.return === 'representation' ? sendRows(req, res, rows) : send(res, 204, null);
    }
    if (req.method === 'DELETE') {
      const where = buildWhere(url.searchParams, values);
      if (!where) return send(res, 400, { code: '21000', message: 'DELETE requires a WHERE clause', details: null, hint: null });
      const rows = await asCaller(ctx, async (tx) =>
        (await tx.query(`with t as (delete from ${t}${where} returning *) select coalesce(json_agg(t), '[]'::json) as v from t`, values)).rows[0].v);
      return pref.return === 'representation' ? sendRows(req, res, rows) : send(res, 204, null);
    }
    send(res, 405, { message: 'Method not allowed' });
  } catch (e) { pgError(res, e, ctx); }
}

// ── Auth (GoTrue subset) ─────────────────────────────────────────────────────
const mailbox = [];
const userJson = (u) => ({
  id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email, phone: '',
  email_confirmed_at: u.email_confirmed_at, confirmed_at: u.email_confirmed_at, last_sign_in_at: new Date().toISOString(),
  app_metadata: u.raw_app_meta_data ?? { provider: 'email', providers: ['email'] }, user_metadata: u.raw_user_meta_data ?? {},
  identities: [], created_at: u.created_at, updated_at: u.updated_at, is_anonymous: false,
});
function session(u) {
  const now = Math.floor(Date.now() / 1000);
  const sid = crypto.randomUUID();
  const access_token = signJwt({
    aud: 'authenticated', iss: `http://127.0.0.1:${PORT}/auth/v1`, sub: u.id, email: u.email, role: 'authenticated',
    app_metadata: u.raw_app_meta_data ?? {}, user_metadata: u.raw_user_meta_data ?? {}, session_id: sid, is_anonymous: false,
    iat: now, exp: now + ACCESS_TTL,
  });
  const refresh_token = signJwt({ typ: 'refresh', sub: u.id, sid, iat: now, exp: now + 60 * 60 * 24 * 30 });
  return { access_token, token_type: 'bearer', expires_in: ACCESS_TTL, expires_at: now + ACCESS_TTL, refresh_token, user: userJson(u) };
}
const authErr = (res, status, code, msg) => send(res, status, { code: status, error_code: code, msg, error: code, error_description: msg });
const getUser = async (where, params) => (await queue(() => db.query(
  `select id, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at from auth.users where ${where}`, params))).rows[0];

async function handleAuth(req, res, url) {
  const route = url.pathname.slice('/auth/v1'.length);
  if (route === '/health') return send(res, 200, { name: 'lifelink-dev-auth', version: 'dev' });
  if (route === '/settings') return send(res, 200, { external: { email: true }, disable_signup: false, mailer_autoconfirm: true });

  if (route === '/verify' && req.method === 'GET') {
    const claims = verifyJwt(url.searchParams.get('token'));
    const redirect = url.searchParams.get('redirect_to') || `http://127.0.0.1:${WEB_PORT}/login.html`;
    if (!claims || claims.typ !== 'recovery') return send(res, 302, null, { Location: `${redirect}#error=access_denied&error_description=Link+expired` });
    const u = await getUser('id = $1', [claims.sub]);
    const s = session(u);
    return send(res, 302, null, { Location: `${redirect}#access_token=${s.access_token}&refresh_token=${s.refresh_token}&expires_in=${s.expires_in}&expires_at=${s.expires_at}&token_type=bearer&type=recovery` });
  }

  callerContext(req); // require the API key on every other auth route
  if (route === '/signup' && req.method === 'POST') {
    const { email, password, data } = await readJson(req);
    const em = String(email ?? '').trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(em)) return authErr(res, 400, 'validation_failed', 'Unable to validate email address: invalid format');
    if (String(password ?? '').length < 8) return authErr(res, 422, 'weak_password', 'Password should be at least 8 characters.');
    if (await getUser('lower(email) = $1', [em])) return authErr(res, 422, 'user_already_exists', 'User already registered');
    try {
      const id = crypto.randomUUID();
      await asAdmin(async (tx) => {
        await tx.query(`insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
                        values ('00000000-0000-0000-0000-000000000000', $1, 'authenticated', 'authenticated', $2,
                          extensions.crypt($3, extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', $4::jsonb, now(), now())`,
        [id, em, password, JSON.stringify(data ?? {})]);
      });
      return send(res, 200, session(await getUser('id = $1', [id])));
    } catch (e) { return authErr(res, 500, 'unexpected_failure', `Database error saving new user: ${e.message}`); }
  }
  if (route === '/token' && req.method === 'POST') {
    const grant = url.searchParams.get('grant_type');
    const body = await readJson(req);
    if (grant === 'password') {
      const u = await getUser(`lower(email) = $1 and encrypted_password = extensions.crypt($2, encrypted_password)`,
        [String(body.email ?? '').trim().toLowerCase(), String(body.password ?? '')]);
      if (!u) return authErr(res, 400, 'invalid_credentials', 'Invalid login credentials');
      return send(res, 200, session(u));
    }
    if (grant === 'refresh_token') {
      const c = verifyJwt(body.refresh_token);
      if (!c || c.typ !== 'refresh') return authErr(res, 400, 'refresh_token_not_found', 'Invalid Refresh Token: Refresh Token Not Found');
      const u = await getUser('id = $1', [c.sub]);
      if (!u) return authErr(res, 400, 'user_not_found', 'User not found');
      return send(res, 200, session(u));
    }
    return authErr(res, 400, 'unsupported_grant_type', 'Unsupported grant type');
  }
  if (route === '/recover' && req.method === 'POST') {
    const { email } = await readJson(req);
    const redirect = url.searchParams.get('redirect_to') ?? '';
    const u = await getUser('lower(email) = $1', [String(email ?? '').trim().toLowerCase()]);
    if (u) {
      const token = signJwt({ typ: 'recovery', sub: u.id, exp: Math.floor(Date.now() / 1000) + 3600 });
      const link = `http://127.0.0.1:${PORT}/auth/v1/verify?type=recovery&token=${token}&redirect_to=${encodeURIComponent(redirect)}`;
      mailbox.unshift({ to: u.email, subject: 'Reset your LifeLink password', link, at: new Date().toISOString() });
      log(`✉  Password reset for ${u.email}: ${link}`);
    }
    return send(res, 200, {});
  }
  if (route === '/user') {
    const ctx = callerContext(req);
    if (ctx.role !== 'authenticated') return authErr(res, 401, 'no_authorization', 'This endpoint requires a valid Bearer token');
    if (req.method === 'PUT') {
      const body = await readJson(req);
      if (body.password !== undefined && String(body.password).length < 8) return authErr(res, 422, 'weak_password', 'Password should be at least 8 characters.');
      await asAdmin(async (tx) => {
        if (body.password) await tx.query(`update auth.users set encrypted_password = extensions.crypt($2, extensions.gen_salt('bf')), updated_at = now() where id = $1`, [ctx.sub, body.password]);
        if (body.email) await tx.query(`update auth.users set email = lower($2), updated_at = now() where id = $1`, [ctx.sub, body.email]);
        if (body.data) await tx.query(`update auth.users set raw_user_meta_data = coalesce(raw_user_meta_data, '{}') || $2::jsonb, updated_at = now() where id = $1`, [ctx.sub, JSON.stringify(body.data)]);
      });
    }
    const u = await getUser('id = $1', [ctx.sub]);
    return u ? send(res, 200, userJson(u)) : authErr(res, 404, 'user_not_found', 'User not found');
  }
  if (route === '/logout') return send(res, 204, null);
  return authErr(res, 404, 'not_found', `Auth route ${route} is not available on the dev server`);
}

// ── Storage (avatars) ────────────────────────────────────────────────────────
const STORAGE_DIR = path.join(DATA_DIR, 'storage');
function parseMultipart(buf, contentType) {
  const boundary = /boundary=(?:"([^"]+)"|([^;]+))/.exec(contentType ?? '');
  if (!boundary) return { data: buf, type: contentType };
  const sep = Buffer.from(`--${boundary[1] ?? boundary[2]}`);
  let idx = buf.indexOf(sep);
  while (idx !== -1) {
    const next = buf.indexOf(sep, idx + sep.length);
    if (next === -1) break;
    const part = buf.subarray(idx + sep.length + 2, next - 2);
    const headEnd = part.indexOf('\r\n\r\n');
    const head = part.subarray(0, headEnd).toString();
    if (/filename=|Content-Type:/i.test(head) && !/name="cacheControl"/.test(head)) {
      return { data: part.subarray(headEnd + 4), type: /Content-Type:\s*([^\r\n]+)/i.exec(head)?.[1] ?? 'application/octet-stream' };
    }
    idx = next;
  }
  return { data: buf, type: contentType };
}
async function handleStorage(req, res, url) {
  const route = decodeURIComponent(url.pathname.slice('/storage/v1/'.length));
  const pub = /^object\/public\/([^/]+)\/(.+)$/.exec(route);
  if (pub && (req.method === 'GET' || req.method === 'HEAD')) {
    const file = path.join(STORAGE_DIR, pub[1], pub[2]);
    if (!file.startsWith(STORAGE_DIR) || !fs.existsSync(file)) return send(res, 404, { statusCode: '404', error: 'not_found', message: 'Object not found' });
    const type = fs.existsSync(`${file}.meta`) ? JSON.parse(fs.readFileSync(`${file}.meta`, 'utf8')).type : 'application/octet-stream';
    return send(res, 200, fs.readFileSync(file), { 'Content-Type': type, 'Cache-Control': 'no-cache' });
  }
  const ctx = callerContext(req);
  const obj = /^object\/([^/]+)\/(.+)$/.exec(route);
  if (obj && (req.method === 'POST' || req.method === 'PUT')) {
    const [, bucket, objectPath] = obj;
    if (bucket !== 'avatars') return send(res, 404, { statusCode: '404', error: 'Bucket not found', message: 'Bucket not found' });
    if (ctx.role !== 'authenticated' || objectPath.split('/')[0] !== ctx.sub) {
      return send(res, 403, { statusCode: '403', error: 'Unauthorized', message: 'new row violates row-level security policy' });
    }
    const { data, type } = parseMultipart(await readBody(req), req.headers['content-type']);
    if (data.length > 2 * 1024 * 1024) return send(res, 413, { statusCode: '413', error: 'Payload too large', message: 'The object exceeded the maximum allowed size' });
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(type)) return send(res, 415, { statusCode: '415', error: 'invalid_mime_type', message: `mime type ${type} is not supported` });
    const file = path.join(STORAGE_DIR, bucket, objectPath);
    if (!file.startsWith(STORAGE_DIR)) return send(res, 400, { message: 'Invalid path' });
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, data);
    fs.writeFileSync(`${file}.meta`, JSON.stringify({ type }));
    return send(res, 200, { Key: `${bucket}/${objectPath}`, Id: crypto.randomUUID(), path: objectPath, fullPath: `${bucket}/${objectPath}` });
  }
  return send(res, 404, { statusCode: '404', error: 'not_found', message: 'Storage route not available on the dev server' });
}

// ── API server ───────────────────────────────────────────────────────────────
const api = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? 'localhost'}`);
  if (req.method === 'OPTIONS') return send(res, 204, null);
  try {
    if (url.pathname.startsWith('/rest/v1/')) return await handleRest(req, res, url);
    if (url.pathname.startsWith('/auth/v1')) return await handleAuth(req, res, url);
    if (url.pathname.startsWith('/storage/v1/')) return await handleStorage(req, res, url);
    if (url.pathname === '/dev/mailbox') return send(res, 200, mailbox.slice(0, 20));
    if (url.pathname === '/' || url.pathname === '/dev') {
      return send(res, 200, { name: 'LifeLink local dev server', supabaseUrl: `http://127.0.0.1:${PORT}`, anonKey: ANON_KEY, serviceRoleKeyDevOnly: SERVICE_ROLE_KEY, website: `http://127.0.0.1:${WEB_PORT}` });
    }
    send(res, 404, { message: 'Not found' });
  } catch (e) {
    if (!res.headersSent) pgError(res, e);
  }
});

// ── Realtime (Phoenix channel protocol subset: postgres_changes) ────────────
const wss = new WebSocketServer({ noServer: true });
const sockets = new Set();
let bindingSeq = 1;
api.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, 'http://x');
  if (!url.pathname.startsWith('/realtime/v1/websocket') || url.searchParams.get('apikey') !== ANON_KEY) return socket.destroy();
  wss.handleUpgrade(req, socket, head, (ws) => {
    const client = { ws, vsn: url.searchParams.get('vsn') ?? '2.0.0', channels: new Map() };
    sockets.add(client);
    ws.on('close', () => sockets.delete(client));
    ws.on('message', (raw) => {
      let m;
      try {
        const j = JSON.parse(raw.toString());
        m = Array.isArray(j) ? { join_ref: j[0], ref: j[1], topic: j[2], event: j[3], payload: j[4] } : j;
      } catch { return; }
      const reply = (status = 'ok', response = {}) => push(client, { join_ref: m.join_ref, ref: m.ref, topic: m.topic, event: 'phx_reply', payload: { status, response } });
      if (m.topic === 'phoenix' && m.event === 'heartbeat') return reply();
      if (m.event === 'phx_join') {
        const cfg = m.payload?.config ?? {};
        const bindings = (cfg.postgres_changes ?? []).map((b) => ({ ...b, id: bindingSeq++ }));
        client.channels.set(m.topic, { joinRef: m.join_ref, token: m.payload?.access_token, bindings });
        reply('ok', { postgres_changes: bindings.map((b) => ({ id: b.id, event: b.event, schema: b.schema, table: b.table, ...(b.filter !== undefined ? { filter: b.filter } : {}) })) });
        if (bindings.length) push(client, { join_ref: m.join_ref, ref: null, topic: m.topic, event: 'system', payload: { message: 'Subscribed to PostgreSQL', status: 'ok', extension: 'postgres_changes', channel: m.topic.replace(/^realtime:/, '') } });
        return;
      }
      if (m.event === 'access_token') { const ch = client.channels.get(m.topic); if (ch) ch.token = m.payload?.access_token; return; }
      if (m.event === 'phx_leave') { client.channels.delete(m.topic); return reply(); }
      reply(); // broadcast / presence: accepted, ignored
    });
  });
});
function push(client, msg) {
  if (client.ws.readyState !== 1) return;
  client.ws.send(JSON.stringify(client.vsn === '1.0.0' ? msg : [msg.join_ref ?? null, msg.ref ?? null, msg.topic, msg.event, msg.payload]));
}

const PK = { blood_requests: ['id'], request_responses: ['id'], donor_availability: ['donor_id'], hospital_inventory: ['hospital_id', 'blood_group'],
  notifications: ['id'], donor_applications: ['id'], contact_messages: ['id'] };
const colCache = new Map();
async function selectableColumns(tx, role, table) {
  const key = `${role}:${table}`;
  if (!colCache.has(key)) {
    const r = await tx.query(`select column_name from information_schema.columns c where table_schema = 'public' and table_name = $1
                               and has_column_privilege($2, format('public.%I', table_name), column_name, 'SELECT') order by ordinal_position`, [table, role]);
    colCache.set(key, r.rows.map((x) => x.column_name));
  }
  return colCache.get(key);
}
function filterMatches(filter, rec) {
  if (!filter) return true;
  const m = /^([a-z_0-9]+)=eq\.(.+)$/.exec(filter);
  return m ? String(rec?.[m[1]]) === m[2] : true;
}
await db.listen('dev_realtime', async (raw) => {
  const change = JSON.parse(raw);
  const rec = change.record ?? change.old_record;
  const pk = PK[change.table] ?? ['id'];
  for (const client of sockets) {
    for (const [topic, ch] of client.channels) {
      const matching = ch.bindings.filter((b) =>
        (b.schema === '*' || b.schema === 'public') && (!b.table || b.table === '*' || b.table === change.table) &&
        (b.event === '*' || String(b.event).toUpperCase() === change.type) && filterMatches(b.filter, rec));
      if (!matching.length) continue;
      const claims = verifyJwt(ch.token);
      const ctx = claims?.role === 'authenticated' ? { role: 'authenticated', sub: claims.sub, claims } : { role: 'anon', sub: null, claims: { role: 'anon' } };
      let record = null, old_record = null;
      try {
        if (change.type === 'DELETE') {
          old_record = Object.fromEntries(pk.map((k) => [k, change.old_record[k]]));
        } else {
          record = await asCaller(ctx, async (tx) => {
            const cols = await selectableColumns(tx, ctx.role, change.table);
            if (!cols.length) return null;
            const where = pk.map((k, i) => `${ident(k)}::text = $${i + 1}`).join(' and ');
            const r = await tx.query(`select json_build_object(${cols.map((c) => `'${c}', ${ident(c)}`).join(', ')}) as v from public.${ident(change.table)} where ${where}`,
              pk.map((k) => String(change.record[k])));
            return r.rows[0]?.v ?? null;
          });
          if (!record) continue; // RLS: this subscriber may not see the row
          if (change.type === 'UPDATE') old_record = Object.fromEntries(pk.map((k) => [k, change.old_record[k]]));
        }
      } catch { continue; }
      push(client, { join_ref: null, ref: null, topic, event: 'postgres_changes', payload: {
        ids: matching.map((b) => b.id),
        data: { schema: 'public', table: change.table, commit_timestamp: change.ts, type: change.type, columns: [], record, old_record, errors: null },
      } });
    }
  }
});

// ── Static website server (LifeLink website + admin.html) ───────────────────────
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.webp': 'image/webp', '.woff2': 'font/woff2' };
const web = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  let file = path.normalize(path.join(WEBSITE_DIR, decodeURIComponent(url.pathname)));
  if (!file.startsWith(path.normalize(WEBSITE_DIR))) { res.writeHead(403); return res.end(); }
  if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
  if (!fs.existsSync(file)) { res.writeHead(404, { 'Content-Type': 'text/plain' }); return res.end('Not found'); }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file).toLowerCase()] ?? 'application/octet-stream', 'Cache-Control': 'no-cache' });
  // Pages served by THIS dev server talk to this dev server; everywhere else config.js uses Supabase.
  if (file === path.join(WEBSITE_DIR, 'config.js')) return res.end('window.LIFELINK_DEV_SERVER = true;\n' + fs.readFileSync(file, 'utf8'));
  fs.createReadStream(file).pipe(res);
});

api.listen(PORT, HOST, () => {
  log(`\n✔ LifeLink dev API      http://127.0.0.1:${PORT}`);
  log(`  anon (publishable) key  ${ANON_KEY}`);
  if (!process.argv.includes('--no-web') && fs.existsSync(WEBSITE_DIR)) {
    web.listen(WEB_PORT, HOST, () => {
      log(`✔ LifeLink website       http://127.0.0.1:${WEB_PORT}`);
      log(`✔ Admin dashboard        http://127.0.0.1:${WEB_PORT}/admin.html`);
      log('\n  Demo logins (dev data only): admin@lifelink.dev / LifeLinkAdmin#2026 · umer.abdullah@email.com / lifelink123\n');
    });
  }
});
