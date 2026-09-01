-- Run once in Supabase Dashboard > SQL Editor.
-- Adds separate English and Chinese product content for the admin editor.

begin;

alter table public.products add column if not exists title_en text not null default '';
alter table public.products add column if not exists title_zh text not null default '';
alter table public.products add column if not exists description_en text not null default '';
alter table public.products add column if not exists description_zh text not null default '';

update public.products
set title_en = title
where nullif(trim(title_en), '') is null or trim(title_en) = '';

update public.products
set description_en = description
where (nullif(trim(description_en), '') is null or trim(description_en) = '')
  and id not like '1688-%';

drop function if exists public.get_storefront_products();

create function public.get_storefront_products()
returns table (
  id text,
  title text,
  title_en text,
  title_zh text,
  category text,
  description text,
  description_en text,
  description_zh text,
  price numeric,
  compare_at_price numeric,
  stock integer,
  published boolean,
  image text,
  images jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  select
    products.id,
    coalesce(nullif(products.title_en, ''), products.title),
    products.title_en,
    products.title_zh,
    products.category,
    case when products.id like '1688-%' then '' else products.description end,
    products.description_en,
    products.description_zh,
    products.price,
    products.compare_at_price,
    products.stock,
    products.published,
    products.image,
    products.images
  from public.products
  where products.deleted_at is null
    and products.published = true
  order by products.updated_at desc, products.id;
$$;

revoke all on function public.get_storefront_products() from public;
grant execute on function public.get_storefront_products() to anon, authenticated;

commit;
