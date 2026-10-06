-- Exam Ready — Supabase schema. Run once in Supabase → SQL Editor.
-- Roles: 'parent' and 'student'. A parent creates an invite code; the student redeems it to link accounts.
-- Row-level security: students see only their own data; parents see only children linked to them.

-- Supabase installs pgcrypto in the "extensions" schema; functions that use it list that schema in search_path.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Profiles (one per auth user) -----------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('parent','student')),
  full_name text not null default '',
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

-- Parent ↔ student links -------------------------------------------------------------------
create table if not exists public.links (
  parent_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (parent_id, student_id)
);
alter table public.links enable row level security;

-- Invite codes (created by parents, redeemed by students) ---------------------------------
create table if not exists public.invites (
  code text primary key,
  parent_id uuid not null references public.profiles(id) on delete cascade,
  child_name text not null default '',
  created_at timestamptz not null default now(),
  used_by uuid references public.profiles(id) on delete set null,
  used_at timestamptz
);
alter table public.invites enable row level security;

-- Student progress (the app's full state) and the summary report parents read -------------
create table if not exists public.progress (
  student_id uuid primary key references public.profiles(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.progress enable row level security;

create table if not exists public.reports (
  student_id uuid primary key references public.profiles(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.reports enable row level security;

-- AI usage log (written only by the server function, used for daily limits) --------------
create table if not exists public.ai_usage (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'tutor',
  input_tokens int not null default 0,
  output_tokens int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists ai_usage_user_time on public.ai_usage(user_id, created_at desc);
alter table public.ai_usage enable row level security;

-- Helper: is the current user a parent of this student? ------------------------------------
create or replace function public.is_parent_of(p_student uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.links where parent_id = auth.uid() and student_id = p_student);
$$;

-- Policies -----------------------------------------------------------------------------------
drop policy if exists "profiles: read own or linked" on public.profiles;
create policy "profiles: read own or linked" on public.profiles for select
  using (id = auth.uid() or public.is_parent_of(id)
         or exists(select 1 from public.links l where l.student_id = auth.uid() and l.parent_id = profiles.id));
drop policy if exists "profiles: update own name" on public.profiles;
create policy "profiles: update own name" on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());
-- only the name can be changed by the user; the role is fixed at sign-up
revoke update on public.profiles from authenticated, anon;
grant update (full_name) on public.profiles to authenticated;

drop policy if exists "links: read own" on public.links;
create policy "links: read own" on public.links for select
  using (parent_id = auth.uid() or student_id = auth.uid());
drop policy if exists "links: parent can remove" on public.links;
create policy "links: parent can remove" on public.links for delete
  using (parent_id = auth.uid());

drop policy if exists "invites: parent reads own" on public.invites;
create policy "invites: parent reads own" on public.invites for select using (parent_id = auth.uid());
drop policy if exists "invites: parent deletes own" on public.invites;
create policy "invites: parent deletes own" on public.invites for delete using (parent_id = auth.uid() and used_by is null);

drop policy if exists "progress: student owns" on public.progress;
create policy "progress: student owns" on public.progress for all
  using (student_id = auth.uid()) with check (student_id = auth.uid());
drop policy if exists "progress: parent reads" on public.progress;
create policy "progress: parent reads" on public.progress for select using (public.is_parent_of(student_id));

drop policy if exists "reports: student owns" on public.reports;
create policy "reports: student owns" on public.reports for all
  using (student_id = auth.uid()) with check (student_id = auth.uid());
drop policy if exists "reports: parent reads" on public.reports;
create policy "reports: parent reads" on public.reports for select using (public.is_parent_of(student_id));

drop policy if exists "ai_usage: read own" on public.ai_usage;
create policy "ai_usage: read own" on public.ai_usage for select using (user_id = auth.uid() or public.is_parent_of(user_id));

-- Create a profile automatically when someone signs up --------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, role, full_name)
  values (new.id,
          case when new.raw_user_meta_data->>'role' = 'parent' then 'parent' else 'student' end,
          coalesce(new.raw_user_meta_data->>'full_name', ''))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Parent creates an invite code ------------------------------------------------------------
create or replace function public.create_invite(p_child_name text default '')
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_code text; v_role text;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if v_role is distinct from 'parent' then raise exception 'Only parent accounts can create invite codes'; end if;
  if (select count(*) from public.invites where parent_id = auth.uid() and used_by is null) >= 10 then
    raise exception 'Too many unused codes. Delete some first.'; end if;
  loop
    v_code := upper(substr(translate(encode(gen_random_bytes(6), 'base64'), '+/=0O1Il', 'XYZ23456'), 1, 6));
    exit when not exists(select 1 from public.invites where code = v_code);
  end loop;
  insert into public.invites(code, parent_id, child_name) values (v_code, auth.uid(), coalesce(p_child_name,''));
  return v_code;
end $$;

-- Student redeems a code (valid 14 days, single use) ------------------------------------------
create or replace function public.redeem_invite(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare v_inv public.invites; v_role text;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if v_role is distinct from 'student' then raise exception 'Only student accounts can use a family code'; end if;
  select * into v_inv from public.invites where code = upper(trim(p_code)) for update;
  if v_inv.code is null then raise exception 'That code does not exist. Check it with your parent.'; end if;
  if v_inv.used_by is not null then raise exception 'That code has already been used.'; end if;
  if v_inv.created_at < now() - interval '14 days' then raise exception 'That code has expired. Ask your parent for a new one.'; end if;
  insert into public.links(parent_id, student_id) values (v_inv.parent_id, auth.uid()) on conflict do nothing;
  update public.invites set used_by = auth.uid(), used_at = now() where code = v_inv.code;
  return (select full_name from public.profiles where id = v_inv.parent_id);
end $$;

grant execute on function public.create_invite(text) to authenticated;
grant execute on function public.redeem_invite(text) to authenticated;
grant execute on function public.is_parent_of(uuid) to authenticated;


-- =============================================================================================
-- Part 2: admin console, safety queue, parent tasks and notes, richer parent dashboard.
-- Safe to re-run. After the first run, make yourself an admin (change the email):
--   insert into public.admins(user_id) select id from auth.users where email = 'you@example.com' on conflict do nothing;
-- =============================================================================================

-- Account controls on profiles (users can still only change their own full_name) ---------------
alter table public.profiles add column if not exists status text not null default 'active';
alter table public.profiles add column if not exists suspended_reason text not null default '';
alter table public.profiles add column if not exists ai_daily_limit int;
do $$ begin
  alter table public.profiles add constraint profiles_status_chk check (status in ('active','suspended'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.profiles add constraint profiles_ai_limit_chk check (ai_daily_limit is null or ai_daily_limit between 0 and 1000);
exception when duplicate_object then null; end $$;

alter table public.ai_usage add column if not exists model text;
create index if not exists ai_usage_time on public.ai_usage(created_at desc);

-- Admins ----------------------------------------------------------------------------------------
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now(),
  added_by uuid
);
alter table public.admins enable row level security;   -- no policies: only reachable through the functions below

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.assert_admin()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only' using errcode = '42501'; end if;
end $$;

-- App-wide settings -------------------------------------------------------------------------------
create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.app_settings enable row level security;
insert into public.app_settings(key, value) values
  ('ai_enabled', 'true'::jsonb),
  ('ai_daily_limit', 'null'::jsonb),
  ('announcement', '{"text":"","audience":"all"}'::jsonb),
  ('ai_price_per_mtok', '{"currency":"USD","models":{}}'::jsonb)
on conflict (key) do nothing;
drop policy if exists "settings: public keys readable" on public.app_settings;
create policy "settings: public keys readable" on public.app_settings for select to authenticated
  using (key in ('announcement','ai_enabled'));

-- Safety queue (written by the AI server function, reviewed by admins) ---------------------------
create table if not exists public.safety_flags (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  category text not null default 'wellbeing',
  source text not null default 'model',
  excerpt text not null default '',
  reply_excerpt text not null default '',
  status text not null default 'open' check (status in ('open','reviewed')),
  review_note text not null default '',
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists safety_flags_open on public.safety_flags(status, created_at desc);
alter table public.safety_flags enable row level security;   -- admins read through functions only

-- Audit log of admin actions ----------------------------------------------------------------------
create table if not exists public.admin_audit (
  id bigserial primary key,
  actor uuid,
  action text not null,
  target uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.admin_audit enable row level security;

create or replace function public.audit(p_action text, p_target uuid, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.admin_audit(actor, action, target, details) values (auth.uid(), p_action, p_target, coalesce(p_details,'{}'::jsonb));
$$;
revoke execute on function public.audit(text, uuid, jsonb) from public, anon, authenticated;

-- Parent → child tasks and notes ------------------------------------------------------------------
create table if not exists public.tasks (
  id bigserial primary key,
  parent_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'task' check (kind in ('task','note')),
  title text not null check (char_length(title) between 1 and 200),
  detail text not null default '' check (char_length(detail) <= 1000),
  subject text,
  due date,
  done_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists tasks_student on public.tasks(student_id, done_at, created_at desc);
alter table public.tasks enable row level security;
drop policy if exists "tasks: parent or student reads" on public.tasks;
create policy "tasks: parent or student reads" on public.tasks for select
  using ((parent_id = auth.uid() and public.is_parent_of(student_id)) or student_id = auth.uid());
drop policy if exists "tasks: parent adds for own child" on public.tasks;
create policy "tasks: parent adds for own child" on public.tasks for insert
  with check (parent_id = auth.uid() and public.is_parent_of(student_id) and done_at is null);
drop policy if exists "tasks: parent deletes own" on public.tasks;
create policy "tasks: parent deletes own" on public.tasks for delete using (parent_id = auth.uid());
revoke update on public.tasks from authenticated, anon;

create or replace function public.add_task(p_student uuid, p_kind text, p_title text, p_detail text default '', p_subject text default null, p_due date default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.is_parent_of(p_student) then raise exception 'You can only add tasks for your own linked children'; end if;
  if (select count(*) from public.tasks where student_id = p_student and done_at is null) >= 30 then
    raise exception 'This child already has 30 open tasks and notes. Remove some first.'; end if;
  insert into public.tasks(parent_id, student_id, kind, title, detail, subject, due)
  values (auth.uid(), p_student, case when p_kind = 'note' then 'note' else 'task' end, left(trim(p_title),200), left(coalesce(p_detail,''),1000), nullif(p_subject,''), p_due)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.complete_task(p_id bigint, p_done boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.tasks set done_at = case when p_done then now() else null end
  where id = p_id and student_id = auth.uid();
  if not found then raise exception 'Task not found'; end if;
end $$;

-- Student home: account status, announcement for students, open tasks and notes -------------------
create or replace function public.my_home()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'status', p.status,
    'suspended_reason', p.suspended_reason,
    'role', p.role,
    'is_admin', public.is_admin(),
    'announcement', (select case when a.value->>'text' <> '' and coalesce(a.value->>'audience','all') in ('all', p.role || 's') then a.value end
                     from public.app_settings a where a.key = 'announcement'),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'title', t.title, 'detail', t.detail,
                        'subject', t.subject, 'due', t.due, 'done_at', t.done_at, 'created_at', t.created_at,
                        'from', (select full_name from public.profiles pp where pp.id = t.parent_id)) order by t.done_at nulls first, t.created_at desc)
                      from public.tasks t where t.student_id = p.id and (t.done_at is null or t.done_at > now() - interval '7 days')), '[]'::jsonb)
  )
  from public.profiles p where p.id = auth.uid();
$$;

-- Parent dashboard: everything about each linked child in one call -------------------------------
create or replace function public.parent_dashboard()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(k order by k->>'name'), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', s.id,
      'name', coalesce(nullif(s.full_name,''), r.data->>'name', 'Student'),
      'linked_at', l.created_at,
      'status', s.status,
      'report', r.data,
      'report_at', r.updated_at,
      'state', case when g.state is null then null else jsonb_build_object(
                 'stats', g.state->'stats', 'sessions', g.state->'sessions', 'mistakes', g.state->'mistakes',
                 'subjects', g.state->'subjects', 'dates', g.state->'dates', 'targets', g.state->'targets',
                 'xp', g.state->'xp', 'day', g.state->'day', 'badges', g.state->'badges') end,
      'progress_at', g.updated_at,
      'ai', (select jsonb_build_object(
                'd7', count(*) filter (where u.created_at > now() - interval '7 days'),
                'd30', count(*),
                'by_kind', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) n from public.ai_usage
                            where user_id = s.id and created_at > now() - interval '7 days' group by kind) z), '{}'::jsonb))
             from public.ai_usage u where u.user_id = s.id and u.created_at > now() - interval '30 days'),
      'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'title', t.title, 'detail', t.detail,
                  'subject', t.subject, 'due', t.due, 'done_at', t.done_at, 'created_at', t.created_at) order by t.done_at nulls first, t.created_at desc)
                from public.tasks t where t.student_id = s.id and t.parent_id = auth.uid()
                  and (t.done_at is null or t.done_at > now() - interval '30 days')), '[]'::jsonb)
    ) k
    from public.links l
    join public.profiles s on s.id = l.student_id
    left join public.reports r on r.student_id = s.id
    left join public.progress g on g.student_id = s.id
    where l.parent_id = auth.uid()
  ) x;
$$;

-- ---------------------------------------------------------------------------------------------
-- Admin functions. Every one checks is_admin(); every change is written to admin_audit.
-- ---------------------------------------------------------------------------------------------
create or replace function public.admin_overview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; today date := (now() at time zone 'Africa/Lagos')::date;
begin
  perform public.assert_admin();
  with sess as (
    select r.student_id, to_timestamp((e->>'ts')::double precision / 1000) as ts
    from public.reports r, jsonb_array_elements(case when jsonb_typeof(r.data->'sessions') = 'array' then r.data->'sessions' else '[]'::jsonb end) e
    where e ? 'ts'
  ), days as (
    select generate_series(today - 29, today, interval '1 day')::date d
  )
  select jsonb_build_object(
    'students', (select count(*) from public.profiles where role = 'student'),
    'parents', (select count(*) from public.profiles where role = 'parent'),
    'linked_students', (select count(distinct student_id) from public.links),
    'suspended', (select count(*) from public.profiles where status = 'suspended'),
    'signups_7d', (select count(*) from public.profiles where created_at > now() - interval '7 days'),
    'signups_30d', (select count(*) from public.profiles where created_at > now() - interval '30 days'),
    'active_today', (select count(*) from public.progress where (updated_at at time zone 'Africa/Lagos')::date = today),
    'active_7d', (select count(*) from public.progress where updated_at > now() - interval '7 days'),
    'tests_7d', (select count(*) from sess where ts > now() - interval '7 days'),
    'questions_today', (select coalesce(sum(case when (r.data->>'today') ~ '^\d+$' then (r.data->>'today')::int else 0 end), 0)
                        from public.reports r where (r.updated_at at time zone 'Africa/Lagos')::date = today),
    'ai_today', (select count(*) from public.ai_usage where (created_at at time zone 'Africa/Lagos')::date = today),
    'ai_7d', (select count(*) from public.ai_usage where created_at > now() - interval '7 days'),
    'ai_30d', (select count(*) from public.ai_usage where created_at > now() - interval '30 days'),
    'tokens_30d', (select coalesce(jsonb_agg(jsonb_build_object('model', coalesce(model,'unknown'), 'requests', n, 'input', i, 'output', o)), '[]'::jsonb)
                   from (select model, count(*) n, sum(input_tokens) i, sum(output_tokens) o from public.ai_usage
                         where created_at > now() - interval '30 days' group by model) z),
    'open_flags', (select count(*) from public.safety_flags where status = 'open'),
    'price', (select value from public.app_settings where key = 'ai_price_per_mtok'),
    'daily', (select jsonb_agg(jsonb_build_object('d', d,
                'signups', (select count(*) from public.profiles p where (p.created_at at time zone 'Africa/Lagos')::date = d),
                'ai', (select count(*) from public.ai_usage u where (u.created_at at time zone 'Africa/Lagos')::date = d),
                'tests', (select count(*) from sess where (ts at time zone 'Africa/Lagos')::date = d)) order by d) from days)
  ) into v;
  return v;
end $$;

create or replace function public.admin_users(p_search text default '', p_role text default '', p_status text default '', p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; q text := '%' || lower(coalesce(p_search,'')) || '%';
begin
  perform public.assert_admin();
  with base as (
    select p.id, u.email, p.full_name, p.role, p.status, p.created_at, u.last_sign_in_at, p.ai_daily_limit,
           greatest(g.updated_at, r.updated_at) as last_active,
           exists(select 1 from public.admins a where a.user_id = p.id) as is_admin,
           (select count(*) from public.links l where l.parent_id = p.id or l.student_id = p.id) as n_links,
           (select count(*) from public.ai_usage x where x.user_id = p.id and x.created_at > now() - interval '7 days') as ai_7d
    from public.profiles p
    join auth.users u on u.id = p.id
    left join public.progress g on g.student_id = p.id
    left join public.reports r on r.student_id = p.id
    where (lower(p.full_name) like q or lower(u.email) like q)
      and (coalesce(p_role,'') = '' or p.role = p_role or (p_role = 'admin' and exists(select 1 from public.admins a where a.user_id = p.id)))
      and (coalesce(p_status,'') = '' or p.status = p_status)
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'rows', coalesce((select jsonb_agg(to_jsonb(b) order by b.created_at desc) from
              (select * from base order by created_at desc limit least(greatest(p_limit,1),200) offset greatest(p_offset,0)) b), '[]'::jsonb)
  ) into v;
  return v;
end $$;

create or replace function public.admin_user_detail(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform public.assert_admin();
  select jsonb_build_object(
    'id', p.id, 'email', u.email, 'full_name', p.full_name, 'role', p.role, 'status', p.status,
    'suspended_reason', p.suspended_reason, 'ai_daily_limit', p.ai_daily_limit,
    'created_at', p.created_at, 'last_sign_in_at', u.last_sign_in_at, 'email_confirmed_at', u.email_confirmed_at,
    'is_admin', exists(select 1 from public.admins a where a.user_id = p.id),
    'parents', coalesce((select jsonb_agg(jsonb_build_object('id', pp.id, 'name', pp.full_name, 'email', uu.email, 'since', l.created_at))
                from public.links l join public.profiles pp on pp.id = l.parent_id join auth.users uu on uu.id = pp.id where l.student_id = p.id), '[]'::jsonb),
    'children', coalesce((select jsonb_agg(jsonb_build_object('id', cc.id, 'name', cc.full_name, 'email', uu.email, 'since', l.created_at))
                from public.links l join public.profiles cc on cc.id = l.student_id join auth.users uu on uu.id = cc.id where l.parent_id = p.id), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'child_name', i.child_name, 'created_at', i.created_at, 'used', i.used_by is not null))
                from public.invites i where i.parent_id = p.id), '[]'::jsonb),
    'report', (select r.data from public.reports r where r.student_id = p.id),
    'report_at', (select r.updated_at from public.reports r where r.student_id = p.id),
    'progress_at', (select g.updated_at from public.progress g where g.student_id = p.id),
    'ai_30d', coalesce((select jsonb_agg(jsonb_build_object('d', d, 'n', n) order by d) from
                (select (created_at at time zone 'Africa/Lagos')::date d, count(*) n from public.ai_usage
                 where user_id = p.id and created_at > now() - interval '30 days' group by 1) z), '[]'::jsonb),
    'ai_tokens_30d', (select jsonb_build_object('requests', count(*), 'input', coalesce(sum(input_tokens),0), 'output', coalesce(sum(output_tokens),0))
                from public.ai_usage where user_id = p.id and created_at > now() - interval '30 days'),
    'flags', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'category', f.category, 'status', f.status, 'created_at', f.created_at, 'excerpt', f.excerpt) order by f.created_at desc)
                from public.safety_flags f where f.user_id = p.id), '[]'::jsonb)
  ) into v
  from public.profiles p join auth.users u on u.id = p.id where p.id = p_user;
  if v is null then raise exception 'User not found'; end if;
  return v;
end $$;

create or replace function public.admin_set_status(p_user uuid, p_status text, p_reason text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_status not in ('active','suspended') then raise exception 'Unknown status'; end if;
  if p_user = auth.uid() then raise exception 'You cannot suspend your own account'; end if;
  update public.profiles set status = p_status, suspended_reason = case when p_status = 'suspended' then left(coalesce(p_reason,''),300) else '' end where id = p_user;
  if not found then raise exception 'User not found'; end if;
  perform public.audit(case when p_status = 'suspended' then 'suspend' else 'reactivate' end, p_user, jsonb_build_object('reason', p_reason));
end $$;

create or replace function public.admin_set_ai_limit(p_user uuid, p_limit int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.profiles set ai_daily_limit = p_limit where id = p_user;
  if not found then raise exception 'User not found'; end if;
  perform public.audit('set_ai_limit', p_user, jsonb_build_object('limit', p_limit));
end $$;

create or replace function public.admin_set_admin(p_user uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_on then
    insert into public.admins(user_id, added_by) values (p_user, auth.uid()) on conflict do nothing;
  else
    if p_user = auth.uid() then raise exception 'You cannot remove your own admin access'; end if;
    delete from public.admins where user_id = p_user;
  end if;
  perform public.audit(case when p_on then 'grant_admin' else 'revoke_admin' end, p_user, '{}'::jsonb);
end $$;

create or replace function public.admin_unlink(p_parent uuid, p_student uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  delete from public.links where parent_id = p_parent and student_id = p_student;
  perform public.audit('unlink', p_student, jsonb_build_object('parent', p_parent));
end $$;

create or replace function public.admin_set_setting(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_key not in ('ai_enabled','ai_daily_limit','announcement','ai_price_per_mtok') then raise exception 'Unknown setting %', p_key; end if;
  if p_key = 'ai_enabled' and jsonb_typeof(p_value) <> 'boolean' then raise exception 'ai_enabled must be true or false'; end if;
  if p_key = 'ai_daily_limit' and jsonb_typeof(p_value) not in ('number','null') then raise exception 'ai_daily_limit must be a number'; end if;
  if p_key = 'announcement' and (jsonb_typeof(p_value) <> 'object' or char_length(coalesce(p_value->>'text','')) > 500
     or coalesce(p_value->>'audience','all') not in ('all','students','parents')) then raise exception 'Announcement: up to 500 characters, audience all/students/parents'; end if;
  insert into public.app_settings(key, value, updated_at, updated_by) values (p_key, p_value, now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  perform public.audit('setting', null, jsonb_build_object('key', p_key, 'value', p_value));
end $$;

create or replace function public.admin_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return (select jsonb_object_agg(key, value) from public.app_settings);
end $$;

create or replace function public.admin_flags(p_status text default 'open')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'user_id', f.user_id, 'name', p.full_name, 'email', u.email, 'role', p.role,
            'category', f.category, 'source', f.source, 'excerpt', f.excerpt, 'reply_excerpt', f.reply_excerpt, 'status', f.status,
            'review_note', f.review_note, 'reviewed_at', f.reviewed_at, 'created_at', f.created_at,
            'parents', (select string_agg(pp.full_name || ' <' || uu.email || '>', ', ') from public.links l join public.profiles pp on pp.id = l.parent_id join auth.users uu on uu.id = pp.id where l.student_id = f.user_id))
          order by f.created_at desc)
    from (select * from public.safety_flags where coalesce(p_status,'') = '' or status = p_status order by created_at desc limit 200) f
    join public.profiles p on p.id = f.user_id join auth.users u on u.id = f.user_id), '[]'::jsonb);
end $$;

create or replace function public.admin_review_flag(p_id bigint, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  perform public.assert_admin();
  if char_length(trim(coalesce(p_note,''))) < 3 then raise exception 'Write a short note on what you did'; end if;
  update public.safety_flags set status = 'reviewed', review_note = left(p_note, 1000), reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_id returning user_id into v_user;
  if v_user is null then raise exception 'Flag not found'; end if;
  perform public.audit('review_flag', v_user, jsonb_build_object('flag', p_id, 'note', p_note));
end $$;

create or replace function public.admin_audit_log(p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'action', a.action, 'details', a.details, 'created_at', a.created_at,
            'actor', ua.email, 'target', coalesce(pt.full_name,'') || coalesce(' <' || ut.email || '>', ''), 'target_id', a.target) order by a.created_at desc)
    from (select * from public.admin_audit order by created_at desc limit least(greatest(p_limit,1),1000)) a
    left join auth.users ua on ua.id = a.actor
    left join auth.users ut on ut.id = a.target
    left join public.profiles pt on pt.id = a.target), '[]'::jsonb);
end $$;

-- Who may call what ---------------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'is_admin()','assert_admin()','add_task(uuid,text,text,text,text,date)','complete_task(bigint,boolean)','my_home()','parent_dashboard()',
    'admin_overview()','admin_users(text,text,text,int,int)','admin_user_detail(uuid)','admin_set_status(uuid,text,text)',
    'admin_set_ai_limit(uuid,int)','admin_set_admin(uuid,boolean)','admin_unlink(uuid,uuid)','admin_set_setting(text,jsonb)',
    'admin_settings()','admin_flags(text)','admin_review_flag(bigint,text)','admin_audit_log(int)']
  loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
