begin;

alter table public.products
  add column if not exists deleted_at timestamptz;

alter table public.products
  add column if not exists deleted_was_published boolean not null default false;

create index if not exists products_deleted_at_idx
  on public.products(deleted_at);

drop policy if exists "products public read" on public.products;
drop policy if exists "products admin read" on public.products;
create policy "products admin read" on public.products
  for select
  using (public.is_admin());

commit;
