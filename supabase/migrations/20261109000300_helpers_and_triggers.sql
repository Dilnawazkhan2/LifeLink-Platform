-- ============================================================================
-- LifeLink Platform — 0003: helper functions, triggers, audit logging
-- All security-definer functions pin search_path = '' and fully qualify names.
-- ============================================================================

-- ── updated_at maintenance ──────────────────────────────────────────────────
create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','user_addresses','donor_applications','donors','hospitals',
    'blood_requests','request_responses','donations'
  ] loop
    execute format('create trigger %I_set_updated_at before update on public.%I
                    for each row execute function public.set_updated_at()', t, t);
  end loop;
end $$;

-- ── Role helpers (server-side source of truth for authorization) ─────────────
create or replace function public.has_role(_role public.app_role)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.user_roles r
    join public.profiles p on p.id = r.user_id
    where r.user_id = (select auth.uid()) and r.role = _role and p.status = 'active'
  );
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select public.has_role('admin');
$$;

-- admin or moderator: may review requests/applications
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = '' as $$
  select public.has_role('admin') or public.has_role('moderator');
$$;

create or replace function public.is_active_user()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = (select auth.uid()) and status = 'active');
$$;

create or replace function public.manages_hospital(_hospital_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_admin() or (
    public.has_role('hospital_staff') and exists (
      select 1 from public.hospital_staff s where s.user_id = (select auth.uid()) and s.hospital_id = _hospital_id
    )
  );
$$;

create or replace function public.my_donor_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.donors where profile_id = (select auth.uid());
$$;

-- ── City resolution: free-text city → cities.id (creates unknown cities) ─────
create or replace function public.resolve_city(_name text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  _clean text := initcap(regexp_replace(trim(coalesce(_name, '')), '\s+', ' ', 'g'));
  _id integer;
begin
  if char_length(_clean) < 2 or char_length(_clean) > 80 or _clean !~ '^[[:alpha:] .''-]+$' then
    raise exception 'Invalid city name' using errcode = '22023';
  end if;
  select id into _id from public.cities where name_key = lower(_clean);
  if _id is null then
    insert into public.cities (name) values (_clean)
    on conflict (name_key) do nothing
    returning id into _id;
    if _id is null then
      select id into _id from public.cities where name_key = lower(_clean);
    end if;
  end if;
  return _id;
end $$;

-- ── Notifications helper ─────────────────────────────────────────────────────
create or replace function public.notify_user(
  _user_id uuid, _type public.notification_type, _title text, _body text,
  _link text default null, _data jsonb default '{}'
) returns void language sql security definer set search_path = '' as $$
  insert into public.notifications (user_id, type, title, body, link, data)
  select _user_id, _type, left(_title, 120), left(_body, 500), _link, coalesce(_data, '{}')
  where _user_id is not null;
$$;

-- ── New auth user → profile, preferences, donor record ───────────────────────
-- Accepts metadata from both clients:
--   website : { first_name, last_name, user_type: donor|recipient }
--   app     : { full_name, account_type, phone, blood_group, city, area }
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}');
  _name text := coalesce(
    nullif(trim(m->>'full_name'), ''),
    nullif(trim(concat_ws(' ', m->>'first_name', m->>'last_name')), ''),
    split_part(new.email, '@', 1)
  );
  _type public.account_type := case coalesce(m->>'account_type', m->>'user_type')
    when 'donor' then 'donor'::public.account_type
    when 'recipient' then 'recipient'::public.account_type
    else 'both'::public.account_type end;
  _group text := case when m->>'blood_group' in ('A+','A-','B+','B-','AB+','AB-','O+','O-') then m->>'blood_group' end;
  _city integer;
  _phone text := nullif(trim(m->>'phone'), '');
  _donor uuid;
begin
  if nullif(trim(m->>'city'), '') is not null then
    begin _city := public.resolve_city(m->>'city'); exception when others then _city := null; end;
  end if;
  if _phone is not null and _phone !~ '^\+?[0-9][0-9 ()\-]{6,22}$' then _phone := null; end if;

  insert into public.profiles (id, full_name, email, phone, blood_group, account_type, city_id, area)
  values (new.id, left(_name, 100), new.email, _phone, _group, _type, _city, nullif(left(trim(m->>'area'), 120), ''));

  insert into public.notification_preferences (user_id) values (new.id);

  -- Link a website-approved donor with the same email instead of duplicating it.
  update public.donors set profile_id = new.id
  where email = new.email and profile_id is null
  returning id into _donor;

  if _donor is null and _type in ('donor', 'both') and _group is not null and _city is not null then
    insert into public.donors (profile_id, blood_group, city_id, area)
    values (new.id, _group, _city, nullif(left(trim(m->>'area'), 120), ''))
    returning id into _donor;
    insert into public.donor_availability (donor_id, updated_by) values (_donor, new.id);
  end if;

  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keep profiles.email in sync when the auth email changes.
create or replace function public.handle_user_email_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.profiles set email = new.email where id = new.id;
  return new;
end $$;

create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row when (old.email is distinct from new.email)
  execute function public.handle_user_email_change();

-- ── Generic audit trigger ────────────────────────────────────────────────────
create or replace function public.audit_row_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  _id text;
  _old jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  _new jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
begin
  if tg_op = 'UPDATE' and (_old - 'updated_at') = (_new - 'updated_at') then
    return new; -- no real change
  end if;
  _id := coalesce(_new->>'id', _old->>'id', _new->>'donor_id', _old->>'donor_id',
                  concat_ws(':', coalesce(_new, _old)->>'hospital_id', coalesce(_new, _old)->>'blood_group'),
                  concat_ws(':', coalesce(_new, _old)->>'user_id', coalesce(_new, _old)->>'role'));
  insert into public.audit_logs (table_name, record_id, action, old_data, new_data, actor_id)
  values (tg_table_name, _id, tg_op, _old, _new, (select auth.uid()));
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','user_roles','donor_applications','donors','donor_availability',
    'hospitals','hospital_inventory','hospital_staff','blood_requests','request_responses','donations'
  ] loop
    execute format('create trigger %I_audit after insert or update or delete on public.%I
                    for each row execute function public.audit_row_change()', t, t);
  end loop;
end $$;

-- ── Blood request: status history + notifications ────────────────────────────
create or replace function public.on_blood_request_status()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  _label text;
begin
  if tg_op = 'INSERT' then
    insert into public.request_status_history (request_id, from_status, to_status, changed_by, reason)
    values (new.id, null, new.status, (select auth.uid()), 'created via ' || new.source);
  elsif new.status is distinct from old.status then
    insert into public.request_status_history (request_id, from_status, to_status, changed_by, reason)
    values (new.id, old.status, new.status, (select auth.uid()), new.status_reason);

    _label := case new.status
      when 'approved'  then 'approved'
      when 'active'    then 'now live — donors are being notified'
      when 'fulfilled' then 'fulfilled'
      when 'rejected'  then 'rejected'
      when 'cancelled' then 'cancelled'
      else new.status::text end;

    perform public.notify_user(
      new.requester_id, 'system',
      'Request ' || initcap(new.status::text),
      format('Your request %s for %s (%s) is %s.', new.reference_code, new.patient_name, new.blood_group, _label)
        || coalesce(' Reason: ' || new.status_reason, ''),
      '/requests/' || new.id, jsonb_build_object('request_id', new.id, 'status', new.status)
    );

    -- Tell people who responded when the request is closed.
    if new.status in ('fulfilled', 'cancelled') then
      insert into public.notifications (user_id, type, title, body, link, data)
      select rr.responder_id, 'system', 'Request ' || initcap(new.status::text),
             format('The request for %s at %s is %s. Thank you for responding.', new.patient_name, new.hospital_name, new.status),
             '/requests/' || new.id, jsonb_build_object('request_id', new.id)
      from public.request_responses rr
      where rr.request_id = new.id and rr.status <> 'withdrawn' and rr.responder_id is not null;
    end if;
  end if;

  -- Fan out to compatible, available donors in the same city when it goes live.
  if new.status = 'active' and (tg_op = 'INSERT' or old.status is distinct from 'active') then
    insert into public.notifications (user_id, type, title, body, link, data)
    select d.profile_id, 'request',
           case when new.urgency = 'normal' then 'Blood Request Near You' else 'Urgent: ' || new.blood_group || ' Blood Needed' end,
           format('%s blood needed at %s, %s.', new.blood_group, new.hospital_name, c.name),
           '/requests/' || new.id, jsonb_build_object('request_id', new.id)
    from public.donors d
    join public.donor_availability a on a.donor_id = d.id and a.status = 'available'
    join public.notification_preferences np on np.user_id = d.profile_id
    join public.blood_groups bg on bg.code = d.blood_group
    join public.cities c on c.id = new.city_id
    join public.profiles p on p.id = d.profile_id and p.status = 'active'
    where d.is_active
      and d.city_id = new.city_id
      and new.blood_group = any (bg.can_donate_to)
      and d.profile_id is distinct from new.requester_id
      and (np.emergency_alerts or new.urgency = 'normal')
      and np.push_enabled
    limit 500;
  end if;

  return new;
end $$;

create trigger blood_requests_status_events
  after insert or update of status on public.blood_requests
  for each row execute function public.on_blood_request_status();

-- ── Responses → notify requester ─────────────────────────────────────────────
create or replace function public.on_request_response()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  _req public.blood_requests;
  _name text;
begin
  select * into _req from public.blood_requests where id = new.request_id;
  select coalesce(p.full_name, d.full_name) || ' (' || d.blood_group || ')' into _name
  from public.donors d left join public.profiles p on p.id = d.profile_id where d.id = new.donor_id;

  if tg_op = 'INSERT' then
    perform public.notify_user(_req.requester_id, 'accepted', 'Donor Accepted Your Request',
      format('%s has accepted your blood request at %s.', _name, _req.hospital_name),
      '/requests/' || _req.id, jsonb_build_object('request_id', _req.id, 'donor_id', new.donor_id));
  elsif new.status = 'withdrawn' and old.status <> 'withdrawn' then
    perform public.notify_user(_req.requester_id, 'system', 'Donor Withdrew',
      format('%s can no longer donate for your request at %s.', _name, _req.hospital_name),
      '/requests/' || _req.id, jsonb_build_object('request_id', _req.id));
  end if;
  return new;
end $$;

create trigger request_responses_events
  after insert or update of status on public.request_responses
  for each row execute function public.on_request_response();

-- ── Badges: award automatically from donation / response counts ─────────────
create or replace function public.evaluate_badges(_profile_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  _donor uuid;
  _donations int; _units int; _urgent int;
  b record;
  _value int;
begin
  select id into _donor from public.donors where profile_id = _profile_id;
  if _donor is null then return; end if;

  select count(*), coalesce(sum(units), 0) into _donations, _units from public.donations where donor_id = _donor;
  select count(*) into _urgent
    from public.request_responses rr join public.blood_requests br on br.id = rr.request_id
    where rr.donor_id = _donor and rr.status <> 'withdrawn' and br.urgency <> 'normal';

  for b in select * from public.badges where metric in ('donations','urgent_responses','lives_saved') loop
    _value := case b.metric when 'donations' then _donations when 'urgent_responses' then _urgent else _units * 3 end;
    if _value >= b.threshold then
      insert into public.user_badges (user_id, badge_id) values (_profile_id, b.id)
      on conflict do nothing;
      if found then
        perform public.notify_user(_profile_id, 'badge', 'Badge Earned: ' || b.title, b.description, '/profile/badges');
      end if;
    end if;
  end loop;
end $$;

create or replace function public.on_donation_or_response_badges()
returns trigger language plpgsql security definer set search_path = '' as $$
declare _profile uuid;
begin
  select profile_id into _profile from public.donors where id = new.donor_id;
  if _profile is not null then perform public.evaluate_badges(_profile); end if;
  return new;
end $$;

create trigger donations_badges after insert on public.donations
  for each row execute function public.on_donation_or_response_badges();
create trigger responses_badges after insert on public.request_responses
  for each row execute function public.on_donation_or_response_badges();
