/**
 * send-emergency-alerts — delivery logic (no Deno / Node specifics).
 *
 * Called by Postgres (pg_net, from the blood_requests trigger) and by a pg_cron
 * sweep. Claims queued rows from public.emergency_alerts, sends them through the
 * Expo Push Service (which delivers via FCM on Android), and records the result.
 *
 * Kept free of runtime imports so it runs both in the Edge Function (Deno) and in
 * the Node test suite with a mocked Expo endpoint. Only erasable TypeScript syntax.
 */

export const EXPO_PUSH_URL = 'https://exp.host/--/api/v2/push/send';
const CHUNK = 100; // Expo accepts at most 100 messages per request

export interface ClaimedAlert {
  alert_id: number;
  user_id: string;
  tokens: string[];
  request_id: string;
  blood_group: string;
  units: number;
  urgency: 'critical' | 'urgent' | 'normal';
  hospital_name: string;
  city: string;
  distance_km: number | string | null;
}

export interface AlertResult {
  alert_id: number;
  status: 'sent' | 'failed' | 'no_device';
  error?: string;
  ticket_ids?: string[];
  invalid_tokens?: string[];
}

export interface AlertDb {
  /** Shared secret stored in Vault (public._alert_dispatch_secret). */
  secret(): Promise<string | null>;
  /** public._claim_queued_alerts(request_id, limit) */
  claim(requestId: string | null, limit: number): Promise<ClaimedAlert[]>;
  /** public._complete_alerts(results) */
  complete(results: AlertResult[]): Promise<number>;
}

export interface ExpoMessage {
  to: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
  sound: 'default';
  priority: 'high';
  channelId: string;
  ttl: number;
}

type Fetch = (url: string, init: { method: string; headers: Record<string, string>; body: string }) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<any>;
}>;

export function buildMessage(alert: ClaimedAlert, token: string): ExpoMessage {
  const dist = alert.distance_km == null ? null : Number(alert.distance_km);
  const where = [alert.hospital_name, alert.city].filter(Boolean).join(', ');
  const units = `${alert.units} unit${Number(alert.units) === 1 ? '' : 's'}`;
  const title =
    alert.urgency === 'normal' ? `${alert.blood_group} blood needed near you` : `Urgent: ${alert.blood_group} blood needed`;
  const body = [units, where, dist != null && Number.isFinite(dist) ? `${dist < 10 ? dist.toFixed(1) : Math.round(dist)} km away` : null]
    .filter(Boolean)
    .join(' · ');
  return {
    to: token,
    title,
    body,
    data: { type: 'emergency_request', request_id: alert.request_id, url: `lifelink://requests/${alert.request_id}` },
    sound: 'default',
    priority: 'high',
    channelId: 'emergency',
    ttl: 6 * 3600, // a stale emergency is not worth delivering after 6 h
  };
}

/** Constant-time string comparison for the shared secret. */
export function safeEqual(a: string, b: string): boolean {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

export interface DispatchSummary {
  claimed: number;
  sent: number;
  failed: number;
  no_device: number;
  invalid_tokens: number;
}

/** Claim → send → record. Never throws for per-message problems; they are recorded. */
export async function dispatch(opts: {
  db: AlertDb;
  fetch: Fetch;
  requestId?: string | null;
  limit?: number;
  expoAccessToken?: string;
}): Promise<DispatchSummary> {
  const alerts = await opts.db.claim(opts.requestId ?? null, opts.limit ?? 500);
  const results = new Map<number, AlertResult>();
  const outgoing: { alertId: number; token: string; message: ExpoMessage }[] = [];

  for (const a of alerts) {
    const tokens = (a.tokens ?? []).filter(Boolean);
    if (!tokens.length) {
      results.set(a.alert_id, { alert_id: a.alert_id, status: 'no_device', error: 'no registered device' });
      continue;
    }
    for (const t of tokens) outgoing.push({ alertId: a.alert_id, token: t, message: buildMessage(a, t) });
  }

  const headers: Record<string, string> = { 'Content-Type': 'application/json', Accept: 'application/json' };
  if (opts.expoAccessToken) headers.Authorization = `Bearer ${opts.expoAccessToken}`;

  // per alert: ticket ids, errors, invalid tokens
  const perAlert = new Map<number, { tickets: string[]; errors: string[]; invalid: string[] }>();
  const bucket = (id: number) => {
    let b = perAlert.get(id);
    if (!b) perAlert.set(id, (b = { tickets: [], errors: [], invalid: [] }));
    return b;
  };

  for (let i = 0; i < outgoing.length; i += CHUNK) {
    const chunk = outgoing.slice(i, i + CHUNK);
    let tickets: any[] = [];
    let requestError: string | null = null;
    try {
      const res = await opts.fetch(EXPO_PUSH_URL, { method: 'POST', headers, body: JSON.stringify(chunk.map((c) => c.message)) });
      const json = await res.json().catch(() => ({}));
      if (!res.ok || !Array.isArray(json?.data)) {
        requestError = json?.errors?.[0]?.message ?? `Expo push service returned HTTP ${res.status}`;
      } else {
        tickets = json.data;
      }
    } catch (e) {
      requestError = `Expo push service unreachable: ${e instanceof Error ? e.message : String(e)}`;
    }
    chunk.forEach((c, idx) => {
      const b = bucket(c.alertId);
      if (requestError) return void b.errors.push(requestError);
      const t = tickets[idx];
      if (t?.status === 'ok') b.tickets.push(String(t.id));
      else {
        const code = t?.details?.error ?? 'Unknown';
        b.errors.push(code === 'DeviceNotRegistered' ? 'DeviceNotRegistered' : `${code}: ${t?.message ?? 'push rejected'}`);
        if (code === 'DeviceNotRegistered') b.invalid.push(c.token);
      }
    });
  }

  for (const [id, b] of perAlert) {
    results.set(id, b.tickets.length
      ? { alert_id: id, status: 'sent', ticket_ids: b.tickets, invalid_tokens: b.invalid }
      : { alert_id: id, status: 'failed', error: b.errors[0]?.slice(0, 500) ?? 'push failed', invalid_tokens: b.invalid });
  }

  const list = [...results.values()];
  if (list.length) await opts.db.complete(list);
  return {
    claimed: alerts.length,
    sent: list.filter((r) => r.status === 'sent').length,
    failed: list.filter((r) => r.status === 'failed').length,
    no_device: list.filter((r) => r.status === 'no_device').length,
    invalid_tokens: list.reduce((n, r) => n + (r.invalid_tokens?.length ?? 0), 0),
  };
}

/** HTTP entry: POST with header x-dispatch-secret and optional JSON body { request_id }. */
export async function handle(req: Request, deps: { db: AlertDb; fetch: Fetch; expoAccessToken?: string }): Promise<Response> {
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  if (req.method !== 'POST') return json(405, { error: 'POST only' });

  const expected = await deps.db.secret();
  const given = req.headers.get('x-dispatch-secret') ?? '';
  if (!expected || !safeEqual(given, expected)) return json(401, { error: 'unauthorized' });

  let body: any = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }
  const requestId = typeof body?.request_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.request_id) ? body.request_id : null;
  try {
    const summary = await dispatch({ db: deps.db, fetch: deps.fetch, requestId, expoAccessToken: deps.expoAccessToken });
    return json(200, summary);
  } catch (e) {
    return json(500, { error: e instanceof Error ? e.message : String(e) });
  }
}
