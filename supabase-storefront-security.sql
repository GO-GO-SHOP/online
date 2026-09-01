-- Run once in Supabase Dashboard > SQL Editor.
-- Public shoppers receive only storefront fields. Full sourcing data remains
-- available to authenticated administrators through the products table.

begin;

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

drop policy if exists "products public read" on public.products;
drop policy if exists "products admin read" on public.products;
create policy "products admin read" on public.products
  for select
  using (public.is_admin());

revoke select on public.products from anon;
grant select on public.products to authenticated;

commit;
