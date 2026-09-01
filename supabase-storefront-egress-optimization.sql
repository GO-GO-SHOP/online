-- Run once in Supabase Dashboard > SQL Editor.
-- Public storefront queries intentionally expose only the fields needed by the
-- catalog. Full image galleries and descriptions are loaded for one product
-- only after a shopper opens its detail view.

begin;

drop function if exists public.get_storefront_catalog();
create function public.get_storefront_catalog()
returns table (
  id text,
  title text,
  title_en text,
  title_zh text,
  category text,
  price numeric,
  compare_at_price numeric,
  stock integer,
  published boolean,
  image text,
  sku text,
  barcode text
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
    products.price,
    products.compare_at_price,
    products.stock,
    products.published,
    products.image,
    products.sku,
    products.barcode
  from public.products
  where products.deleted_at is null
    and products.published = true
    and coalesce(products.tags, '') <> '__gogoshop_purged__'
  order by products.updated_at desc, products.id;
$$;

drop function if exists public.get_storefront_product_detail(text);
create function public.get_storefront_product_detail(p_product_id text)
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
  images jsonb,
  sku text,
  barcode text
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
    products.images,
    products.sku,
    products.barcode
  from public.products
  where products.id = p_product_id
    and products.deleted_at is null
    and products.published = true
    and coalesce(products.tags, '') <> '__gogoshop_purged__';
$$;

revoke all on function public.get_storefront_catalog() from public;
grant execute on function public.get_storefront_catalog() to anon, authenticated;
revoke all on function public.get_storefront_product_detail(text) from public;
grant execute on function public.get_storefront_product_detail(text) to anon, authenticated;

commit;
