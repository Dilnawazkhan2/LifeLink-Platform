// PGlite database for the local dev server: same migrations + seeds as Supabase.
import { PGlite } from '@electric-sql/pglite';
import { citext } from '@electric-sql/pglite/contrib/citext';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import fs from 'node:fs';
import path from 'node:path';

const STUB = path.resolve(import.meta.dirname, '../tests/db/supabase_stub.sql');

// Dev-only: forward every change on a realtime-published table to NOTIFY so the
// server can push it over the websocket (stands in for Supabase Realtime/WAL).
const REALTIME_TRIGGERS = `
create schema if not exists dev_realtime;
create or replace function dev_realtime.notify() returns trigger language plpgsql security definer as $$
begin
  perform pg_notify('dev_realtime', json_build_object(
    'table', tg_table_name, 'type', tg_op,
    'record', case when tg_op <> 'DELETE' then to_jsonb(new) end,
    'old_record', case when tg_op <> 'INSERT' then to_jsonb(old) end,
    'ts', now())::text);
  return coalesce(new, old);
end $$;
do $$
declare t record;
begin
  for t in select tablename from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' loop
    execute format('drop trigger if exists zz_dev_realtime on public.%I', t.tablename);
    execute format('create trigger zz_dev_realtime after insert or update or delete on public.%I
                    for each row execute function dev_realtime.notify()', t.tablename);
  end loop;
end $$;`;

export async function openDatabase({ dataDir, supabaseDir, seed = true, log = console.log }) {
  if (dataDir) fs.mkdirSync(dataDir, { recursive: true });
  const db = new PGlite(dataDir ? { dataDir, extensions: { citext, pgcrypto } } : { extensions: { citext, pgcrypto } });
  await db.waitReady;
  const ready = (await db.query(`select to_regclass('public.profiles') is not null as ok`)).rows[0].ok;
  if (!ready) {
    log('• Initialising database (first run)…');
    await db.exec(fs.readFileSync(STUB, 'utf8'));
    const migDir = path.join(supabaseDir, 'migrations');
    for (const f of fs.readdirSync(migDir).filter((f) => f.endsWith('.sql')).sort()) {
      await db.exec(fs.readFileSync(path.join(migDir, f), 'utf8'));
      log('  applied', f);
    }
    await db.exec(fs.readFileSync(path.join(supabaseDir, 'seeds/reference.sql'), 'utf8'));
    log('  applied seeds/reference.sql');
    if (seed) {
      await db.exec(fs.readFileSync(path.join(supabaseDir, 'seeds/dev_demo.sql'), 'utf8'));
      log('  applied seeds/dev_demo.sql (demo accounts)');
    }
  }
  // (Migrations changed after the first run? Run `npm run dev:reset` to rebuild the data dir.)
  await db.exec(REALTIME_TRIGGERS);
  return db;
}

/** Serialises access: PGlite has a single connection. */
export function createQueue() {
  let tail = Promise.resolve();
  return (fn) => {
    const run = tail.then(fn, fn);
    tail = run.catch(() => {});
    return run;
  };
}
