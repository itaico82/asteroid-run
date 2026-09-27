-- Asteroid Run: pilots, runs, leaderboard
-- Every pilot is a Supabase auth user created by the pilot-signup edge function.
-- Kids never see each other's usernames; the public leaderboard shows callsigns only.

-- ---------- callsigns: two word lists + a number, so nothing a child types is ever public ----------
create or replace function public.is_valid_callsign(c text)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    array_length(regexp_split_to_array(c, ' '), 1) = 3
    and split_part(c, ' ', 1) = any (array['Swift','Brave','Cosmic','Lucky','Silver','Golden','Turbo','Mighty','Clever','Bright','Speedy','Fearless','Jolly','Zippy','Super','Happy','Sonic','Stellar','Blazing','Daring','Radiant','Rapid','Galactic','Noble'])
    and split_part(c, ' ', 2) = any (array['Comet','Falcon','Nebula','Rocket','Meteor','Panda','Tiger','Dolphin','Phoenix','Star','Moon','Otter','Fox','Owl','Dragon','Pulsar','Orbit','Voyager','Explorer','Eagle','Lynx','Penguin','Koala','Shark'])
    and split_part(c, ' ', 3) ~ '^[1-9][0-9]?$', false);
$$;

-- ---------- pilots ----------
create table public.pilots (
  id          uuid primary key references auth.users(id) on delete cascade,
  username    text not null unique check (username ~ '^[a-z0-9_]{3,16}$'),
  callsign    text not null check (public.is_valid_callsign(callsign)),
  emblem      text not null default '#3ee6ff' check (emblem ~ '^#[0-9a-fA-F]{6}$'),
  unlocked    int  not null default 1 check (unlocked between 1 and 15),
  best        jsonb not null default '{}'::jsonb check (jsonb_typeof(best) = 'object' and pg_column_size(best) < 8000),
  settings    jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object' and pg_column_size(settings) < 4000),
  shop        jsonb not null default '{"owned":[],"eq":{},"spent":0}'::jsonb check (jsonb_typeof(shop) = 'object' and pg_column_size(shop) < 8000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------- runs: one row per 25-question mission ----------
create table public.runs (
  id          text primary key check (id ~ '^[A-Za-z0-9_\-]{8,40}$'),
  pilot_id    uuid not null default auth.uid() references public.pilots(id) on delete cascade,
  ts          bigint not null,
  lvl         text not null check (length(lvl) <= 12),
  name        text check (length(name) <= 40),
  mode        text check (mode in ('ladder','mtc','focus')),
  lim         int  check (lim between 1000 and 20000),
  correct     int  not null check (correct between 0 and 25),
  total       int  not null default 25 check (total = 25),
  score       int  not null check (score between 0 and 15000),
  avg_rt      int  check (avg_rt is null or avg_rt between 0 and 20000),
  max_streak  int  check (max_streak between 0 and 25),
  hull        int  check (hull between 0 and 6),
  warp_q      int  check (warp_q between 0 and 25),
  scan        int  not null default 0 check (scan between 0 and 2000),
  perf        int  not null default 0 check (perf between 0 and 2500),
  att         jsonb not null check (jsonb_typeof(att) = 'array' and jsonb_array_length(att) = 25 and pg_column_size(att) < 12000),
  created_at  timestamptz not null default now()
);
create index runs_pilot_ts on public.runs (pilot_id, ts);

-- Sanity checks on anything a player sends (skipped for admin imports, where auth.uid() is null):
-- a mission takes well over a minute, so two missions less than 60 s apart are not real,
-- and a run can't be from the future or more than 30 days old (offline runs are queued and sent later).
create or replace function public.runs_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  if auth.uid() is null then return new; end if;
  new.pilot_id := auth.uid();
  if new.ts > now_ms + 300000 or new.ts < now_ms - 30::bigint * 86400000 then
    raise exception 'run timestamp out of range' using errcode = 'check_violation';
  end if;
  if new.correct = 25 and new.perf = 0 and new.score > 13500 then
    raise exception 'score out of range' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.runs r where r.pilot_id = new.pilot_id and abs(r.ts - new.ts) < 60000) then
    raise exception 'runs too close together' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger runs_guard before insert on public.runs for each row execute function public.runs_guard();

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
create trigger pilots_touch before update on public.pilots for each row execute function public.touch_updated_at();

-- ---------- row level security: a pilot can only ever see and change their own rows ----------
alter table public.pilots enable row level security;
alter table public.runs   enable row level security;

revoke all on public.pilots from anon, authenticated;
revoke all on public.runs   from anon, authenticated;
grant select on public.pilots to authenticated;
grant update (callsign, emblem, unlocked, best, settings, shop) on public.pilots to authenticated;
grant select, insert, delete on public.runs to authenticated;

create policy "own pilot: read"   on public.pilots for select to authenticated using (id = (select auth.uid()));
create policy "own pilot: update" on public.pilots for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy "own runs: read"    on public.runs for select to authenticated using (pilot_id = (select auth.uid()));
create policy "own runs: add"     on public.runs for insert to authenticated with check (pilot_id = (select auth.uid()));
create policy "own runs: delete"  on public.runs for delete to authenticated using (pilot_id = (select auth.uid()));

-- ---------- public leaderboard: callsigns and totals only, never usernames ----------
create or replace function public.leaderboard(max_rows int default 50)
returns table (rank bigint, callsign text, emblem text, total bigint, flights bigint, best int, accuracy int, level int, is_me boolean)
language sql stable security definer set search_path = '' as $$
  with agg as (
    select p.id, p.callsign, p.emblem, p.unlocked,
           coalesce(sum(r.score), 0)::bigint as total,
           count(r.id)::bigint as flights,
           coalesce(max(r.score), 0)::int as best,
           coalesce(round(100.0 * sum(r.correct) / nullif(count(r.id) * 25, 0)), 0)::int as accuracy
    from public.pilots p
    left join public.runs r on r.pilot_id = p.id
    group by p.id
  ), ranked as (
    select agg.*, rank() over (order by total desc, flights desc) as rnk from agg where flights > 0
  )
  select rnk, callsign, emblem, total, flights, best, accuracy, unlocked, id = auth.uid()
  from ranked
  where rnk <= least(greatest(max_rows, 1), 200) or id = auth.uid()
  order by rnk, callsign;
$$;

create or replace function public.world_stats()
returns table (pilots bigint, flights bigint, total bigint)
language sql stable security definer set search_path = '' as $$
  select (select count(*) from public.pilots)::bigint,
         (select count(*) from public.runs)::bigint,
         (select coalesce(sum(score), 0) from public.runs)::bigint;
$$;

-- ---------- a pilot (or their parent) can delete the account and everything in it ----------
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = auth.uid();
end $$;

revoke all on function public.leaderboard(int), public.world_stats(), public.delete_my_account() from public;
grant execute on function public.leaderboard(int), public.world_stats() to anon, authenticated;
grant execute on function public.delete_my_account() to authenticated;

-- ---------- sign-up throttle (written only by the edge function with the service role) ----------
create table public.signup_log (
  id bigint generated always as identity primary key,
  ip text not null,
  created_at timestamptz not null default now()
);
create index signup_log_ip_time on public.signup_log (ip, created_at);
alter table public.signup_log enable row level security;
revoke all on public.signup_log from anon, authenticated;
