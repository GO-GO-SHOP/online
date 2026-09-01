-- Run once in Supabase Dashboard > SQL Editor.
-- Adds customer loyalty barcodes and awards rounded POS points at checkout.

alter table public.profiles
  add column if not exists customer_barcode text not null default '';

update public.profiles
set customer_barcode = 'CUST-' || upper(substr(replace(id::text, '-', ''), 1, 10))
where nullif(trim(customer_barcode), '') is null;

create unique index if not exists profiles_customer_barcode_unique_idx
  on public.profiles (customer_barcode)
  where nullif(trim(customer_barcode), '') is not null;

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

alter table public.orders add column if not exists order_source text not null default 'online';
alter table public.orders drop constraint if exists orders_order_source_check;
alter table public.orders add constraint orders_order_source_check
  check (order_source in ('online', 'pos'));

drop function if exists public.create_pos_order(jsonb);
create or replace function public.create_pos_order(
  p_items jsonb,
  p_customer_barcode text default null
)
returns public.orders
language plpgsql
security definer set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_customer uuid;
  v_customer_barcode text := nullif(
    regexp_replace(upper(trim(coalesce(p_customer_barcode, ''))), '[^0-9A-Z]', '', 'g'),
    ''
  );
  v_order public.orders%rowtype;
  v_order_number text;
  v_total numeric(12,2) := 0;
  v_item_count integer := 0;
  v_points integer := 0;
  v_item jsonb;
  v_product public.products%rowtype;
  v_quantity integer;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Cart is empty';
  end if;

  if v_customer_barcode is not null and left(v_customer_barcode, 4) = 'CUST' then
    v_customer_barcode := substr(v_customer_barcode, 5);
  end if;
  if v_customer_barcode is not null and length(v_customer_barcode) = 10 then
    v_customer_barcode := 'CUST-' || v_customer_barcode;
  end if;

  if v_customer_barcode is not null then
    select id into v_customer
    from public.profiles
    where regexp_replace(upper(coalesce(customer_barcode, '')), '[^0-9A-Z]', '', 'g')
        = regexp_replace(upper(v_customer_barcode), '[^0-9A-Z]', '', 'g')
      and is_admin = false;
    if not found then raise exception 'Customer barcode not found'; end if;
  end if;

  for v_item in
    select jsonb_build_object(
      'product_id', item ->> 'product_id',
      'quantity', sum(greatest(1, coalesce((item ->> 'quantity')::integer, 1)))
    )
    from jsonb_array_elements(p_items) as entries(item)
    group by item ->> 'product_id'
  loop
    v_quantity := (v_item ->> 'quantity')::integer;
    select * into v_product from public.products
      where id = v_item ->> 'product_id' and deleted_at is null
      for update;
    if not found then raise exception 'Product unavailable: %', v_item ->> 'product_id'; end if;
    if v_product.stock < v_quantity then raise exception 'Insufficient stock for %', v_product.title; end if;
    v_total := v_total + (v_product.price * v_quantity);
    v_item_count := v_item_count + v_quantity;
  end loop;

  v_order_number := 'POS-' || to_char(clock_timestamp(), 'YYMMDDHH24MISS') || '-' || upper(substr(gen_random_uuid()::text, 1, 4));
  v_points := case when v_customer is null then 0 else round(v_total)::integer end;

  insert into public.orders (
    order_number, user_id, status, total, item_count, points_awarded,
    payment_provider, payment_status, paid_at, confirmed_at, confirmed_by, order_source
  ) values (
    v_order_number, coalesce(v_customer, v_admin), 'confirmed', round(v_total, 2), v_item_count, v_points,
    'manual', 'paid', now(), now(), v_admin, 'pos'
  ) returning * into v_order;

  for v_item in
    select jsonb_build_object(
      'product_id', item ->> 'product_id',
      'quantity', sum(greatest(1, coalesce((item ->> 'quantity')::integer, 1)))
    )
    from jsonb_array_elements(p_items) as entries(item)
    group by item ->> 'product_id'
  loop
    v_quantity := (v_item ->> 'quantity')::integer;
    select * into v_product from public.products where id = v_item ->> 'product_id';
    insert into public.order_items (order_id, product_id, product_title, unit_price, quantity)
    values (v_order.id, v_product.id, v_product.title, v_product.price, v_quantity);
    update public.products
    set stock = stock - v_quantity,
        sales = sales + v_quantity,
        updated_at = now()
    where id = v_product.id;
  end loop;

  if v_customer is not null then
    update public.profiles
    set points = points + v_points,
        total_spent = total_spent + round(v_total, 2),
        updated_at = now()
    where id = v_customer;
  end if;

  return v_order;
end;
$$;

revoke all on function public.create_pos_order(jsonb, text) from public, anon;
grant execute on function public.create_pos_order(jsonb, text) to authenticated;
