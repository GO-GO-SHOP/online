-- GO GO SHOP online storefront design settings.
-- Run after supabase-schema.sql (and after any migration that defines public.is_admin()).

create table if not exists public.storefront_settings (
  id text primary key,
  design jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint storefront_settings_online_only check (id = 'online')
);

insert into public.storefront_settings (id, design)
values ('online', '{}'::jsonb)
on conflict (id) do nothing;

alter table public.storefront_settings enable row level security;

drop policy if exists "storefront settings public read" on public.storefront_settings;
create policy "storefront settings public read"
  on public.storefront_settings
  for select
  to anon, authenticated
  using (id = 'online');

drop policy if exists "storefront settings admin insert" on public.storefront_settings;
create policy "storefront settings admin insert"
  on public.storefront_settings
  for insert
  to authenticated
  with check (id = 'online' and public.is_admin());

drop policy if exists "storefront settings admin update" on public.storefront_settings;
create policy "storefront settings admin update"
  on public.storefront_settings
  for update
  to authenticated
  using (id = 'online' and public.is_admin())
  with check (id = 'online' and public.is_admin());

drop policy if exists "storefront settings admin delete" on public.storefront_settings;
create policy "storefront settings admin delete"
  on public.storefront_settings
  for delete
  to authenticated
  using (id = 'online' and public.is_admin());

create or replace function public.get_storefront_design()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select design from public.storefront_settings where id = 'online'),
    '{}'::jsonb
  );
$$;

create or replace function public.save_storefront_design(p_design jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  saved_design jsonb;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;

  if p_design is null or jsonb_typeof(p_design) <> 'object' then
    raise exception 'Storefront design must be a JSON object';
  end if;

  if octet_length(p_design::text) > 8000000 then
    raise exception 'Storefront design is too large';
  end if;

  insert into public.storefront_settings (id, design, updated_at, updated_by)
  values ('online', p_design, now(), auth.uid())
  on conflict (id) do update set
    design = excluded.design,
    updated_at = now(),
    updated_by = auth.uid()
  returning design into saved_design;

  return saved_design;
end;
$$;

revoke all on table public.storefront_settings from public, anon, authenticated;
grant select on public.storefront_settings to anon, authenticated;
grant insert, update, delete on public.storefront_settings to authenticated;

revoke all on function public.get_storefront_design() from public;
revoke all on function public.save_storefront_design(jsonb) from public;
grant execute on function public.get_storefront_design() to anon, authenticated;
grant execute on function public.save_storefront_design(jsonb) to authenticated;
