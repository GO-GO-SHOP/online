-- Run this entire file once in Supabase Dashboard > SQL Editor.
-- Then run supabase-vouchers.sql to enable voucher redemption and discounts.
-- After creating your first account, promote it with:
-- update public.profiles set is_admin = true where email = 'YOUR_EMAIL';

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null default '',
  full_name text not null default '',
  points integer not null default 0 check (points >= 0),
  total_spent numeric(12,2) not null default 0 check (total_spent >= 0),
  is_admin boolean not null default false,
  customer_barcode text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.products (
  id text primary key,
  title text not null,
  title_en text not null default '',
  title_zh text not null default '',
  category text not null default '',
  description text not null default '',
  description_en text not null default '',
  description_zh text not null default '',
  price numeric(12,2) not null check (price >= 0),
  compare_at_price numeric(12,2) not null default 0 check (compare_at_price >= 0),
  cost_per_item numeric(12,2) not null default 0 check (cost_per_item >= 0),
  stock integer not null default 0 check (stock >= 0),
  sales integer not null default 0 check (sales >= 0),
  published boolean not null default true,
  image text not null default '',
  images jsonb not null default '[]'::jsonb,
  vendor text not null default '',
  sku text not null default '',
  barcode text not null default '',
  tags text not null default '',
  source_url text not null default '',
  source_currency text not null default '',
  source_price numeric(12,2) not null default 0 check (source_price >= 0),
  source_variants jsonb not null default '[]'::jsonb,
  source_attributes jsonb not null default '[]'::jsonb,
  deleted_at timestamptz,
  deleted_was_published boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.products add column if not exists category text not null default '';
alter table public.products add column if not exists title_en text not null default '';
alter table public.products add column if not exists title_zh text not null default '';
alter table public.products add column if not exists description text not null default '';
alter table public.products add column if not exists description_en text not null default '';
alter table public.products add column if not exists description_zh text not null default '';
alter table public.products add column if not exists compare_at_price numeric(12,2) not null default 0;
alter table public.products add column if not exists cost_per_item numeric(12,2) not null default 0;
alter table public.products add column if not exists image text not null default '';
alter table public.products add column if not exists images jsonb not null default '[]'::jsonb;
alter table public.products add column if not exists vendor text not null default '';
alter table public.products add column if not exists sku text not null default '';
alter table public.products add column if not exists barcode text not null default '';
alter table public.products add column if not exists tags text not null default '';
alter table public.products add column if not exists source_url text not null default '';
alter table public.products add column if not exists source_currency text not null default '';
alter table public.products add column if not exists source_price numeric(12,2) not null default 0;
alter table public.products add column if not exists source_variants jsonb not null default '[]'::jsonb;
alter table public.products add column if not exists source_attributes jsonb not null default '[]'::jsonb;
alter table public.products add column if not exists deleted_at timestamptz;
alter table public.products add column if not exists deleted_was_published boolean not null default false;

alter table public.profiles add column if not exists customer_barcode text not null default '';
update public.profiles
set customer_barcode = 'CUST-' || upper(substr(replace(id::text, '-', ''), 1, 10))
where nullif(trim(customer_barcode), '') is null;
create unique index if not exists profiles_customer_barcode_unique_idx
  on public.profiles (customer_barcode)
  where nullif(trim(customer_barcode), '') is not null;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  user_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'cancelled')),
  total numeric(12,2) not null check (total >= 0),
  item_count integer not null check (item_count > 0),
  points_awarded integer not null default 0 check (points_awarded >= 0),
  payment_provider text not null default 'manual' check (payment_provider in ('manual', 'stripe')),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid', 'pending', 'paid', 'failed', 'refunded')),
  stripe_checkout_session_id text,
  stripe_payment_intent_id text,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  confirmed_by uuid references public.profiles(id) on delete set null,
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id) on delete set null
);

alter table public.orders add column if not exists order_note text not null default '';

alter table public.orders add column if not exists payment_provider text not null default 'manual';
alter table public.orders add column if not exists payment_status text not null default 'unpaid';
alter table public.orders add column if not exists stripe_checkout_session_id text;
alter table public.orders add column if not exists stripe_payment_intent_id text;
alter table public.orders add column if not exists paid_at timestamptz;
alter table public.orders add column if not exists deleted_at timestamptz;
alter table public.orders add column if not exists deleted_by uuid references public.profiles(id) on delete set null;

create table if not exists public.order_items (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id text references public.products(id) on delete set null,
  product_title text not null,
  unit_price numeric(12,2) not null check (unit_price >= 0),
  quantity integer not null check (quantity > 0),
  item_note text not null default '',
  unique (order_id, product_id)
);

alter table public.order_items add column if not exists item_note text not null default '';

alter table public.order_items alter column product_id drop not null;
alter table public.order_items drop constraint if exists order_items_product_id_fkey;
alter table public.order_items add constraint order_items_product_id_fkey
  foreign key (product_id) references public.products(id) on delete set null;

delete from public.products where tags = '__gogoshop_purged__';

create index if not exists orders_user_id_idx on public.orders(user_id, created_at desc);
create index if not exists orders_status_idx on public.orders(status, created_at desc);
create index if not exists orders_payment_status_idx on public.orders(payment_status, created_at desc);
create index if not exists orders_deleted_at_idx on public.orders(deleted_at, created_at desc);
create unique index if not exists orders_stripe_checkout_session_idx on public.orders(stripe_checkout_session_id) where stripe_checkout_session_id is not null;
create index if not exists order_items_order_id_idx on public.order_items(order_id);
create unique index if not exists order_items_order_product_idx on public.order_items(order_id, product_id);
create index if not exists products_deleted_at_idx on public.products(deleted_at);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, customer_barcode)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', ''),
    'CUST-' || upper(substr(replace(new.id::text, '-', ''), 1, 10))
  )
  on conflict (id) do update set
    email = excluded.email,
    full_name = coalesce(nullif(public.profiles.full_name, ''), excluded.full_name),
    customer_barcode = coalesce(nullif(public.profiles.customer_barcode, ''), excluded.customer_barcode),
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert or update of email, raw_user_meta_data on auth.users
  for each row execute procedure public.handle_new_user();

insert into public.profiles (id, email, full_name, customer_barcode)
select id,
  coalesce(email, ''),
  coalesce(raw_user_meta_data ->> 'full_name', raw_user_meta_data ->> 'name', ''),
  'CUST-' || upper(substr(replace(id::text, '-', ''), 1, 10))
from auth.users
on conflict (id) do update set
  email = excluded.email,
  customer_barcode = coalesce(nullif(public.profiles.customer_barcode, ''), excluded.customer_barcode);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select exists(select 1 from public.profiles where id = auth.uid() and is_admin = true);
$$;

create or replace function public.get_admin_login_email()
returns text
language sql
stable
security definer set search_path = public
as $$
  select email from public.profiles where is_admin = true order by created_at limit 1;
$$;

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

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

drop policy if exists "profiles read own or admin" on public.profiles;
create policy "profiles read own or admin" on public.profiles
  for select using (id = auth.uid() or public.is_admin());
drop policy if exists "profiles update own" on public.profiles;

drop policy if exists "products public read" on public.products;
drop policy if exists "products admin read" on public.products;
create policy "products admin read" on public.products for select
  using (public.is_admin());
drop policy if exists "products admin write" on public.products;
create policy "products admin write" on public.products for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "orders read own or admin" on public.orders;
create policy "orders read own or admin" on public.orders
  for select using (
    public.is_admin()
    or (user_id = auth.uid() and deleted_at is null)
  );
drop policy if exists "order items read own or admin" on public.order_items;
create policy "order items read own or admin" on public.order_items
  for select using (
    exists (
      select 1 from public.orders
      where orders.id = order_items.order_id
        and (
          public.is_admin()
          or (orders.user_id = auth.uid() and orders.deleted_at is null)
        )
    )
  );

create or replace function public.create_order(p_items jsonb)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_order_id uuid;
  v_order_number text;
  v_total numeric(12,2) := 0;
  v_item_count integer := 0;
  v_item jsonb;
  v_product public.products%rowtype;
  v_quantity integer;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Cart is empty';
  end if;

  for v_item in
    select jsonb_build_object(
      'product_id', item ->> 'product_id',
      'quantity', sum(greatest(1, coalesce((item ->> 'quantity')::integer, 1)))
    )
    from jsonb_array_elements(p_items) as entries(item)
    group by item ->> 'product_id'
  loop
    v_quantity := greatest(1, coalesce((v_item ->> 'quantity')::integer, 1));
    select * into v_product from public.products
      where id = v_item ->> 'product_id' and published = true;
    if not found then raise exception 'Product unavailable: %', v_item ->> 'product_id'; end if;
    if v_product.stock < v_quantity then raise exception 'Insufficient stock for %', v_product.title; end if;
    v_total := v_total + (v_product.price * v_quantity);
    v_item_count := v_item_count + v_quantity;
  end loop;

  v_order_number := 'GGS-' || to_char(clock_timestamp(), 'YYMMDDHH24MISS') || '-' || upper(substr(gen_random_uuid()::text, 1, 4));
  insert into public.orders (order_number, user_id, total, item_count)
  values (v_order_number, v_user, round(v_total, 2), v_item_count)
  returning id into v_order_id;

  for v_item in
    select jsonb_build_object(
      'product_id', item ->> 'product_id',
      'quantity', sum(greatest(1, coalesce((item ->> 'quantity')::integer, 1)))
    )
    from jsonb_array_elements(p_items) as entries(item)
    group by item ->> 'product_id'
  loop
    v_quantity := greatest(1, coalesce((v_item ->> 'quantity')::integer, 1));
    select * into v_product from public.products where id = v_item ->> 'product_id';
    insert into public.order_items (order_id, product_id, product_title, unit_price, quantity)
    values (v_order_id, v_product.id, v_product.title, v_product.price, v_quantity);
  end loop;

  return v_order_id;
end;
$$;

create or replace function public.confirm_order(p_order_id uuid)
returns public.orders
language plpgsql
security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_item public.order_items%rowtype;
  v_points integer;
  v_stock integer;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'Order not found'; end if;
  if v_order.status <> 'pending' then raise exception 'Order has already been processed'; end if;
  if v_order.payment_provider = 'stripe' and v_order.payment_status <> 'paid' then
    raise exception 'Online payment has not been completed';
  end if;

  for v_item in select * from public.order_items where order_id = p_order_id
  loop
    select stock into v_stock from public.products where id = v_item.product_id for update;
    if v_stock is null or v_stock < v_item.quantity then
      raise exception 'Insufficient stock for %', v_item.product_title;
    end if;
  end loop;

  for v_item in select * from public.order_items where order_id = p_order_id
  loop
    update public.products
      set stock = stock - v_item.quantity,
          sales = sales + v_item.quantity,
          updated_at = now()
      where id = v_item.product_id;
  end loop;

  v_points := round(v_order.total)::integer;
  update public.orders set
    status = 'confirmed', points_awarded = v_points,
    confirmed_at = now(), confirmed_by = auth.uid()
    where id = p_order_id returning * into v_order;
  update public.profiles set
    points = points + v_points,
    total_spent = total_spent + v_order.total,
    updated_at = now()
    where id = v_order.user_id;
  return v_order;
end;
$$;

create or replace function public.soft_delete_order(p_order_id uuid)
returns public.orders
language plpgsql
security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_item public.order_items%rowtype;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'Order not found'; end if;
  if v_order.deleted_at is not null then raise exception 'Order is already in the recycle bin'; end if;

  if v_order.status = 'confirmed' then
    for v_item in select * from public.order_items where order_id = p_order_id
    loop
      update public.products
      set stock = stock + v_item.quantity,
          sales = greatest(0, sales - v_item.quantity),
          updated_at = now()
      where id = v_item.product_id;
    end loop;

    update public.profiles
    set points = greatest(0, points - v_order.points_awarded),
        total_spent = greatest(0, total_spent - v_order.total),
        updated_at = now()
    where id = v_order.user_id;
  end if;

  update public.orders
  set deleted_at = now(), deleted_by = auth.uid()
  where id = p_order_id
  returning * into v_order;

  return v_order;
end;
$$;

create or replace function public.restore_order(p_order_id uuid)
returns public.orders
language plpgsql
security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_item public.order_items%rowtype;
  v_stock integer;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'Order not found'; end if;
  if v_order.deleted_at is null then raise exception 'Order is not in the recycle bin'; end if;

  if v_order.status = 'confirmed' then
    for v_item in select * from public.order_items where order_id = p_order_id
    loop
      select stock into v_stock from public.products where id = v_item.product_id for update;
      if v_stock is null or v_stock < v_item.quantity then
        raise exception 'Insufficient stock to restore %', v_item.product_title;
      end if;
    end loop;

    for v_item in select * from public.order_items where order_id = p_order_id
    loop
      update public.products
      set stock = stock - v_item.quantity,
          sales = sales + v_item.quantity,
          updated_at = now()
      where id = v_item.product_id;
    end loop;

    update public.profiles
    set points = points + v_order.points_awarded,
        total_spent = total_spent + v_order.total,
        updated_at = now()
    where id = v_order.user_id;
  end if;

  update public.orders
  set deleted_at = null, deleted_by = null
  where id = p_order_id
  returning * into v_order;

  return v_order;
end;
$$;

create or replace function public.create_payment_order(p_items jsonb)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  v_order_id uuid;
begin
  v_order_id := public.create_order(p_items);
  update public.orders
  set payment_provider = 'stripe',
      payment_status = 'pending'
  where id = v_order_id
    and user_id = auth.uid();
  return v_order_id;
end;
$$;

revoke all on function public.create_order(jsonb) from public, anon, authenticated;
revoke all on function public.create_payment_order(jsonb) from public, anon;
revoke all on function public.confirm_order(uuid) from public, anon;
revoke all on function public.soft_delete_order(uuid) from public, anon;
revoke all on function public.restore_order(uuid) from public, anon;
revoke all on function public.get_admin_login_email() from public;
revoke all on function public.get_storefront_products() from public;
grant execute on function public.create_payment_order(jsonb) to authenticated;
grant execute on function public.confirm_order(uuid) to authenticated;
grant execute on function public.soft_delete_order(uuid) to authenticated;
grant execute on function public.restore_order(uuid) to authenticated;
grant execute on function public.get_admin_login_email() to anon, authenticated;
grant execute on function public.get_storefront_products() to anon, authenticated;
revoke select on public.products from anon;
grant select on public.products to authenticated;
grant insert, update, delete on public.products to authenticated;
grant select on public.profiles, public.orders, public.order_items to authenticated;

insert into public.products (id, title, price, stock, sales, published) values
  ('blind-box', 'Blind Box', 12.99, 0, 31, true),
  ('blind-box-1', 'Blind Box', 12.99, 0, 24, true),
  ('key-chain', 'Key Chain', 9.99, 0, 18, true),
  ('phone-case-3', 'Phone Case', 4.99, 44, 52, true),
  ('phone-case-2', 'Phone Case', 9.99, 20, 29, true),
  ('phone-case-1', 'Phone Case', 4.99, 35, 43, true),
  ('phone-case', 'Phone Case', 4.99, 22, 37, true),
  ('smart-glasses', 'Smart Glasses', 14.99, 13, 11, true),
  ('soft-toy', 'Soft Toy', 14.99, 0, 15, true)
on conflict (id) do nothing;
