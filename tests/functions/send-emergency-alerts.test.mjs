// Unit tests for supabase/functions/send-emergency-alerts/core.ts with a mocked Expo Push API.
// Run: node tests/functions/send-emergency-alerts.test.mjs  (Node ≥ 23 strips the TypeScript types)
import { buildMessage, dispatch, handle, safeEqual, EXPO_PUSH_URL } from '../../supabase/functions/send-emergency-alerts/core.ts';

const results = [];
const check = (name, cond, detail = '') => results.push([cond ? 'PASS' : 'FAIL', name, cond ? '' : detail]);

const alert = (id, tokens, extra = {}) => ({
  alert_id: id, user_id: `user-${id}`, tokens, request_id: '11111111-2222-3333-4444-555555555555',
  blood_group: 'B+', units: 2, urgency: 'urgent', hospital_name: 'Civil Hospital', city: 'Karachi', distance_km: '3.24', ...extra,
});
const tok = (s) => `ExponentPushToken[${s}]`;

function fakeDb(claimed, secret = 's3cret') {
  const calls = { claim: [], complete: [] };
  return {
    calls,
    secret: async () => secret,
    claim: async (rid, limit) => { calls.claim.push([rid, limit]); return claimed; },
    complete: async (r) => { calls.complete.push(r); return r.length; },
  };
}
/** Expo mock: tokens containing "dead" are DeviceNotRegistered, "bad" → MessageRateExceeded. */
function fakeExpo({ status = 200, fail = false } = {}) {
  const requests = [];
  const fn = async (url, init) => {
    requests.push({ url, init, messages: JSON.parse(init.body) });
    if (fail) throw new Error('getaddrinfo ENOTFOUND exp.host');
    if (status !== 200) return { ok: false, status, json: async () => ({ errors: [{ code: 'INTERNAL', message: 'upstream down' }] }) };
    const data = JSON.parse(init.body).map((m, i) =>
      m.to.includes('dead') ? { status: 'error', message: `"${m.to}" is not a registered push notification recipient`, details: { error: 'DeviceNotRegistered' } }
      : m.to.includes('bad') ? { status: 'error', message: 'Too many', details: { error: 'MessageRateExceeded' } }
      : { status: 'ok', id: `ticket-${requests.length}-${i}` });
    return { ok: true, status: 200, json: async () => ({ data }) };
  };
  fn.requests = requests;
  return fn;
}

// message content
const m = buildMessage(alert(1, [tok('a')]), tok('a'));
check('message: urgent title with blood group', m.title === 'Urgent: B+ blood needed', m.title);
check('message: body has units, hospital, city and distance', m.body === '2 units · Civil Hospital, Karachi · 3.2 km away', m.body);
check('message: deep link data + high priority emergency channel', m.data.request_id && m.data.url === 'lifelink://requests/11111111-2222-3333-4444-555555555555' && m.priority === 'high' && m.channelId === 'emergency');
check('message: normal urgency wording, no distance when unknown',
  (() => { const n = buildMessage(alert(2, [tok('a')], { urgency: 'normal', units: 1, distance_km: null }), tok('a')); return n.title === 'B+ blood needed near you' && n.body === '1 unit · Civil Hospital, Karachi'; })());

// dispatch
{
  const db = fakeDb([alert(1, [tok('ok1')]), alert(2, [tok('dead2')]), alert(3, [])]);
  const expo = fakeExpo();
  const s = await dispatch({ db, fetch: expo, requestId: 'r1', expoAccessToken: 'expo-token' });
  const byId = Object.fromEntries(db.calls.complete[0].map((r) => [r.alert_id, r]));
  check('dispatch: claims for the given request', db.calls.claim[0][0] === 'r1');
  check('dispatch: one Expo request to the push endpoint with the access token', expo.requests.length === 1 && expo.requests[0].url === EXPO_PUSH_URL && expo.requests[0].init.headers.Authorization === 'Bearer expo-token');
  check('dispatch: delivered alert recorded as sent with ticket id', byId[1].status === 'sent' && byId[1].ticket_ids.length === 1);
  check('dispatch: DeviceNotRegistered → failed and token marked invalid', byId[2].status === 'failed' && byId[2].error === 'DeviceNotRegistered' && byId[2].invalid_tokens[0] === tok('dead2'));
  check('dispatch: alert without devices → no_device (nothing sent)', byId[3].status === 'no_device' && !expo.requests[0].messages.some((x) => x.to === undefined));
  check('dispatch: summary counts', s.claimed === 3 && s.sent === 1 && s.failed === 1 && s.no_device === 1 && s.invalid_tokens === 1, JSON.stringify(s));
}
{
  // one donor with two devices: one dead, one fine → sent, dead token still cleaned up
  const db = fakeDb([alert(7, [tok('dead7'), tok('ok7')])]);
  await dispatch({ db, fetch: fakeExpo() });
  const r = db.calls.complete[0][0];
  check('dispatch: any delivered device counts as sent; dead device token removed', r.status === 'sent' && r.invalid_tokens[0] === tok('dead7'), JSON.stringify(r));
}
{
  // 250 alerts → 3 chunks of ≤100
  const many = Array.from({ length: 250 }, (_, i) => alert(100 + i, [tok(`ok${i}`)]));
  const expo = fakeExpo();
  const s = await dispatch({ db: fakeDb(many), fetch: expo });
  check('dispatch: messages chunked to ≤100 per request', expo.requests.length === 3 && expo.requests.every((r) => r.messages.length <= 100) && s.sent === 250);
}
{
  const db = fakeDb([alert(1, [tok('ok1')])]);
  const s = await dispatch({ db, fetch: fakeExpo({ status: 500 }) });
  check('dispatch: Expo outage → failed with reason, never thrown', s.failed === 1 && /upstream down/.test(db.calls.complete[0][0].error));
  const db2 = fakeDb([alert(1, [tok('ok1')])]);
  const s2 = await dispatch({ db: db2, fetch: fakeExpo({ fail: true }) });
  check('dispatch: network error → failed with reason', s2.failed === 1 && /unreachable/.test(db2.calls.complete[0][0].error));
  const db3 = fakeDb([alert(1, [tok('bad1')])]);
  await dispatch({ db: db3, fetch: fakeExpo() });
  check('dispatch: other Expo errors recorded with their code', /^MessageRateExceeded/.test(db3.calls.complete[0][0].error) && db3.calls.complete[0][0].invalid_tokens.length === 0);
  const db4 = fakeDb([]);
  const s4 = await dispatch({ db: db4, fetch: fakeExpo() });
  check('dispatch: nothing queued → nothing sent, nothing recorded', s4.claimed === 0 && db4.calls.complete.length === 0);
}

// HTTP handler
const req = (secret, body = {}, method = 'POST') =>
  new Request('https://x/functions/v1/send-emergency-alerts', { method, headers: { 'x-dispatch-secret': secret, 'Content-Type': 'application/json' }, body: method === 'POST' ? JSON.stringify(body) : undefined });
{
  const db = fakeDb([alert(1, [tok('ok1')])]);
  check('handler: wrong secret → 401, nothing claimed', (await handle(req('nope'), { db, fetch: fakeExpo() })).status === 401 && db.calls.claim.length === 0);
  check('handler: missing secret in Vault → 401', (await handle(req(''), { db: fakeDb([], null), fetch: fakeExpo() })).status === 401);
  check('handler: GET rejected', (await handle(req('s3cret', {}, 'GET'), { db, fetch: fakeExpo() })).status === 405);
  const res = await handle(req('s3cret', { request_id: '11111111-2222-3333-4444-555555555555' }), { db, fetch: fakeExpo() });
  const out = await res.json();
  check('handler: correct secret → 200 with summary, request id passed on', res.status === 200 && out.sent === 1 && db.calls.claim[0][0] === '11111111-2222-3333-4444-555555555555', JSON.stringify(out));
  const db5 = fakeDb([]);
  await handle(req('s3cret', { request_id: "x'; drop table" }), { db: db5, fetch: fakeExpo() });
  check('handler: malformed request id ignored (sweep all queued)', db5.calls.claim[0][0] === null);
}
check('safeEqual', safeEqual('abc', 'abc') && !safeEqual('abc', 'abd') && !safeEqual('abc', 'ab') && !safeEqual('', 'a'));

const pass = results.filter((r) => r[0] === 'PASS').length;
for (const r of results) console.log(r[0] === 'PASS' ? '  ✓' : '  ✗', r[1], r[2] ? `\n      ${r[2]}` : '');
console.log(`\n${pass}/${results.length} edge function checks passed`);
process.exit(pass === results.length ? 0 : 1);
