// Supabase Edge Function: send-emergency-alerts
// Deploy with verify_jwt = false; requests are authorised by the x-dispatch-secret
// header (a random secret kept in Supabase Vault, sent by pg_net from Postgres).
// Server-side keys come from the Edge Function environment and never reach a client.
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { handle, type AlertDb, type AlertResult, type ClaimedAlert } from './core.ts';

const url = Deno.env.get('SUPABASE_URL')!;
const secretKeys = (() => {
  try {
    return JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}') as Record<string, string>;
  } catch {
    return {} as Record<string, string>;
  }
})();
const serverKey = secretKeys['default'] ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(url, serverKey, { auth: { persistSession: false, autoRefreshToken: false } });

const db: AlertDb = {
  async secret() {
    const { data, error } = await admin.rpc('_alert_dispatch_secret');
    if (error) throw new Error(error.message);
    return (data as string | null) ?? null;
  },
  async claim(requestId, limit) {
    const { data, error } = await admin.rpc('_claim_queued_alerts', { _request_id: requestId, _limit: limit });
    if (error) throw new Error(error.message);
    return (data ?? []) as ClaimedAlert[];
  },
  async complete(results: AlertResult[]) {
    const { data, error } = await admin.rpc('_complete_alerts', { _results: results });
    if (error) throw new Error(error.message);
    return Number(data ?? 0);
  },
};

Deno.serve((req) =>
  handle(req, { db, fetch: (u, init) => fetch(u, init), expoAccessToken: Deno.env.get('EXPO_ACCESS_TOKEN') ?? undefined }),
);
