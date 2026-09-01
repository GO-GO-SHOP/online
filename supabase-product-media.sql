-- GO GO SHOP reusable product media library.
-- Run once in Supabase Dashboard > SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.product_media (
  id uuid primary key default gen_random_uuid(),
  url text not null unique,
  storage_path text,
  file_name text not null default '',
  alt_text text not null default '',
  mime_type text not null default '',
  size_bytes bigint not null default 0 check (size_bytes >= 0),
  width integer not null default 0 check (width >= 0),
  height integer not null default 0 check (height >= 0),
  source text not null default 'upload' check (source in ('upload', 'product', 'external')),
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.product_media add column if not exists storage_path text;
alter table public.product_media add column if not exists file_name text not null default '';
alter table public.product_media add column if not exists alt_text text not null default '';
alter table public.product_media add column if not exists mime_type text not null default '';
alter table public.product_media add column if not exists size_bytes bigint not null default 0;
alter table public.product_media add column if not exists width integer not null default 0;
alter table public.product_media add column if not exists height integer not null default 0;
alter table public.product_media add column if not exists source text not null default 'upload';
alter table public.product_media add column if not exists created_by uuid references public.profiles(id) on delete set null default auth.uid();
alter table public.product_media add column if not exists created_at timestamptz not null default now();
alter table public.product_media add column if not exists updated_at timestamptz not null default now();

create unique index if not exists product_media_storage_path_unique_idx
  on public.product_media (storage_path)
  where storage_path is not null;
create index if not exists product_media_created_at_idx
  on public.product_media (created_at desc);
create index if not exists product_media_file_name_idx
  on public.product_media (lower(file_name));

alter table public.product_media enable row level security;

drop policy if exists "product media admin read" on public.product_media;
create policy "product media admin read" on public.product_media
  for select to authenticated
  using (public.is_admin());

drop policy if exists "product media admin insert" on public.product_media;
create policy "product media admin insert" on public.product_media
  for insert to authenticated
  with check (public.is_admin());

drop policy if exists "product media admin update" on public.product_media;
create policy "product media admin update" on public.product_media
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "product media admin delete" on public.product_media;
create policy "product media admin delete" on public.product_media
  for delete to authenticated
  using (public.is_admin());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'product-media',
  'product-media',
  true,
  6291456,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "product media storage admin insert" on storage.objects;
create policy "product media storage admin insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'product-media' and public.is_admin());

drop policy if exists "product media storage admin update" on storage.objects;
create policy "product media storage admin update" on storage.objects
  for update to authenticated
  using (bucket_id = 'product-media' and public.is_admin())
  with check (bucket_id = 'product-media' and public.is_admin());

drop policy if exists "product media storage admin delete" on storage.objects;
create policy "product media storage admin delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'product-media' and public.is_admin());

with existing_urls as (
  select trim(image) as url
  from public.products
  where nullif(trim(image), '') is not null
    and trim(image) !~* '^data:'
  union
  select trim(image_url) as url
  from public.products
  cross join lateral jsonb_array_elements_text(
    case when jsonb_typeof(images) = 'array' then images else '[]'::jsonb end
  ) as media(image_url)
  where nullif(trim(image_url), '') is not null
    and trim(image_url) !~* '^data:'
)
insert into public.product_media (url, file_name, source)
select
  url,
  coalesce(
    nullif(regexp_replace(split_part(split_part(url, '?', 1), '#', 1), '^.*/', ''), ''),
    'Product image'
  ),
  'product'
from existing_urls
on conflict (url) do nothing;

grant select, insert, update, delete on public.product_media to authenticated;

select
  (select count(*) from public.product_media) as registered_images,
  (select public from storage.buckets where id = 'product-media') as bucket_is_public;
