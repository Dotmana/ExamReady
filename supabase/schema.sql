-- Exam Ready — Supabase schema. Run once in Supabase → SQL Editor.
-- Roles: 'parent' and 'student'. A parent creates an invite code; the student redeems it to link accounts.
-- Row-level security: students see only their own data; parents see only children linked to them.

create extension if not exists pgcrypto;

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
returns text language plpgsql security definer set search_path = public as $$
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
