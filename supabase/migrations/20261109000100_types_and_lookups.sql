-- ============================================================================
-- LifeLink Platform — 0001: enums and lookup tables
-- Shared by: LifeDrop website, LifeLink Android app, Admin dashboard
-- ============================================================================

create extension if not exists citext with schema extensions;

-- ── Enums ───────────────────────────────────────────────────────────────────
create type public.account_type        as enum ('donor', 'recipient', 'both');
create type public.account_status      as enum ('active', 'suspended');
create type public.app_role            as enum ('admin', 'moderator', 'hospital_staff');
create type public.availability_status as enum ('available', 'resting', 'busy');
create type public.gender              as enum ('male', 'female', 'other');

create type public.request_status  as enum ('pending', 'approved', 'active', 'fulfilled', 'rejected', 'cancelled');
create type public.request_urgency as enum ('critical', 'urgent', 'normal');
create type public.request_source  as enum ('website', 'android', 'admin');
create type public.response_status as enum ('responded', 'donated', 'withdrawn');

create type public.application_status as enum ('pending', 'approved', 'declined');
create type public.hospital_type      as enum ('private', 'public', 'semi_government');
create type public.donation_status    as enum ('recorded', 'verified');
create type public.notification_type  as enum ('request', 'accepted', 'message', 'donation', 'badge', 'system');

-- ── Blood groups (reference data, shipped with the schema) ──────────────────
create table public.blood_groups (
  code             text primary key check (code in ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
  sort_order       smallint not null unique,
  can_donate_to    text[]   not null,
  can_receive_from text[]   not null
);

insert into public.blood_groups (code, sort_order, can_donate_to, can_receive_from) values
  ('A+',  1, '{A+,AB+}',                         '{A+,A-,O+,O-}'),
  ('A-',  2, '{A-,A+,AB-,AB+}',                  '{A-,O-}'),
  ('B+',  3, '{B+,AB+}',                         '{B+,B-,O+,O-}'),
  ('B-',  4, '{B-,B+,AB-,AB+}',                  '{B-,O-}'),
  ('AB+', 5, '{AB+}',                            '{AB+,AB-,A+,A-,B+,B-,O+,O-}'),
  ('AB-', 6, '{AB-,AB+}',                        '{AB-,A-,B-,O-}'),
  ('O+',  7, '{O+,A+,B+,AB+}',                   '{O+,O-}'),
  ('O-',  8, '{O-,O+,A-,A+,B-,B+,AB-,AB+}',      '{O-}');

-- ── Cities (normalised; website city is free text and resolved via resolve_city) ──
create table public.cities (
  id         integer generated always as identity primary key,
  name       text not null check (char_length(trim(name)) between 2 and 80),
  name_key   text generated always as (lower(regexp_replace(trim(name), '\s+', ' ', 'g'))) stored,
  province   text,
  country    text not null default 'Pakistan',
  created_at timestamptz not null default now(),
  constraint cities_name_key_unique unique (name_key)
);

insert into public.cities (name, province) values
  ('Karachi', 'Sindh'), ('Lahore', 'Punjab'), ('Islamabad', 'ICT'),
  ('Rawalpindi', 'Punjab'), ('Hyderabad', 'Sindh'), ('Faisalabad', 'Punjab'),
  ('Multan', 'Punjab'), ('Peshawar', 'Khyber Pakhtunkhwa'), ('Quetta', 'Balochistan');

-- ── Badges catalogue ────────────────────────────────────────────────────────
create table public.badges (
  id          text primary key check (id ~ '^[a-z0-9_-]+$'),
  title       text not null,
  description text not null,
  requirement text not null,
  icon        text not null,
  tone        text not null check (tone in ('blue','green','red','amber','purple')),
  metric      text not null check (metric in ('donations','urgent_responses','lives_saved','fast_response')),
  threshold   integer not null check (threshold > 0),
  sort_order  smallint not null default 0
);

insert into public.badges (id, title, description, requirement, icon, tone, metric, threshold, sort_order) values
  ('regular-donor',   'Regular Donor',   '5+ donations',                   'Complete 5 blood donations',                  'shield', 'blue',   'donations',        5,  1),
  ('community-hero',  'Community Hero',  'Responded to 3 urgent requests', 'Respond to 3 urgent requests',                'help',   'green',  'urgent_responses', 3,  2),
  ('hero-donor',      'Hero Donor',      '10 donations',                   'Complete 10 blood donations',                 'award',  'red',    'donations',        10, 3),
  ('life-saver',      'Life Saver',      'Saved 25 lives',                 'Help save 25 lives through donations',        'heart',  'purple', 'lives_saved',      25, 4),
  ('rapid-responder', 'Rapid Responder', 'Responded within 15 min',        'Respond to a critical request within 15 min', 'zap',    'amber',  'fast_response',    1,  5),
  ('lifelink-legend', 'LifeLink Legend', '25 donations',                   'Complete 25 blood donations',                 'trophy', 'amber',  'donations',        25, 6);
