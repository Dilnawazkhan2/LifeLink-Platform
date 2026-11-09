-- ============================================================================
-- LifeLink Platform — 0008: donor profile completion
--
-- Found while debugging "the Donor section shows no donors":
--   * update_my_profile created the donor record only when account_type was part
--     of the same save, and swallowed any error from register_as_donor
--     ("exception when others then null"). A user who signed up on the website
--     as a donor (the website form has no blood group / city) and later added
--     them could stay unlisted, with no error shown.
-- Now: whenever a donor account (donor / both) has a blood group and a city and
-- no donor record yet, saving the profile creates it, and errors surface.
--
-- Safe on existing data: replaces one function; no table, policy or data change.
-- Apply to the cloud project by running this file once in the SQL editor.
-- ============================================================================

create or replace function public.update_my_profile(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  _uid uuid := public._require_active_user();
  _city integer;
  _group text := upper(public._clean(p->>'blood_group', 3));
  _phone text := public._clean(p->>'phone', 30);
  _name text := public._clean(p->>'full_name', 100);
begin
  if p ? 'full_name' and (_name is null or char_length(_name) < 2) then perform public._fail('Please enter your full name.'); end if;
  if p ? 'phone' and _phone is not null and not public._valid_phone(_phone) then perform public._fail('Please enter a valid phone number.'); end if;
  if p ? 'blood_group' and _group is not null and _group not in ('A+','A-','B+','B-','AB+','AB-','O+','O-') then
    perform public._fail('Please choose a valid blood group.');
  end if;
  if public._clean(p->>'city', 80) is not null then _city := public.resolve_city(p->>'city'); end if;
  if p ? 'gender' and coalesce(p->>'gender', '') not in ('', 'male', 'female', 'other') then perform public._fail('Invalid gender.'); end if;

  update public.profiles set
    full_name     = case when p ? 'full_name' then _name else full_name end,
    phone         = case when p ? 'phone' then _phone else phone end,
    blood_group   = case when p ? 'blood_group' then _group else blood_group end,
    city_id       = coalesce(_city, city_id),
    area          = case when p ? 'area' then public._clean(p->>'area', 120) else area end,
    account_type  = case when p->>'account_type' in ('donor','recipient','both') then (p->>'account_type')::public.account_type else account_type end,
    date_of_birth = case when p ? 'date_of_birth' then nullif(p->>'date_of_birth', '')::date else date_of_birth end,
    gender        = case when p ? 'gender' then nullif(p->>'gender', '')::public.gender else gender end,
    weight_kg     = case when p ? 'weight_kg' then nullif(p->>'weight_kg', '')::numeric else weight_kg end,
    avatar_path   = case when p ? 'avatar_path' then public._clean(p->>'avatar_path', 300) else avatar_path end
  where id = _uid;

  -- keep the linked donor record consistent (sync_profile_to_donor covers group/city)
  update public.donors set
    area  = case when p ? 'area' then public._clean(p->>'area', 120) else area end,
    hours = case when p ? 'hours' then public._clean(p->>'hours', 40) else hours end,
    about = case when p ? 'about' then public._clean(p->>'about', 500) else about end
  where profile_id = _uid;

  -- Donor accounts (donor / both) with a blood group and a city get their donor
  -- record as soon as the profile has both, whichever fields this save touched.
  -- Errors are no longer swallowed.
  if exists (select 1 from public.profiles pr
             where pr.id = _uid
               and pr.account_type in ('donor', 'both')
               and pr.blood_group is not null
               and pr.city_id is not null)
     and not exists (select 1 from public.donors where profile_id = _uid) then
    perform public._ensure_my_donor();
  end if;

  return public.get_my_profile();
end $$;

-- create or replace keeps existing privileges; restate them explicitly.
revoke execute on function public.update_my_profile(jsonb) from public, anon;
grant execute on function public.update_my_profile(jsonb) to authenticated;
