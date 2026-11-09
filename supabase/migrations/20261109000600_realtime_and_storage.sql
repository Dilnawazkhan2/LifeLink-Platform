-- ============================================================================
-- LifeLink Platform — 0006: Realtime publication + Storage
-- Realtime postgres_changes respects RLS: each subscriber only receives rows
-- their policies allow them to SELECT.
-- ============================================================================

alter publication supabase_realtime add table
  public.blood_requests,          -- dashboard sees new website/app requests; app sees status changes
  public.request_responses,       -- requester sees donors responding
  public.donor_availability,      -- website/app donor lists update live
  public.hospital_inventory,      -- stock changes everywhere
  public.notifications,           -- per-user bell badge
  public.donor_applications,      -- dashboard: new applications
  public.contact_messages;        -- dashboard: new messages

-- Full old row on UPDATE/DELETE so clients can reconcile status changes.
alter table public.blood_requests     replica identity full;
alter table public.donor_availability replica identity full;
alter table public.hospital_inventory replica identity full;

-- ── Storage: profile photos ──────────────────────────────────────────────────
-- Public-read bucket; users may only write inside their own folder: avatars/<uid>/...
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "avatars: public read" on storage.objects
  for select to anon, authenticated using (bucket_id = 'avatars');

create policy "avatars: owner upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "avatars: owner update" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "avatars: owner delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
