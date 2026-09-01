-- Run once in Supabase Dashboard > SQL Editor before deploying the Stripe
-- Edge Functions. Existing orders remain manual orders.

begin;

alter table public.orders
  add column if not exists payment_provider text not null default 'manual';

alter table public.orders
  add column if not exists payment_status text not null default 'unpaid';

alter table public.orders
  add column if not exists stripe_checkout_session_id text;

alter table public.orders
  add column if not exists stripe_payment_intent_id text;

alter table public.orders
  add column if not exists paid_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'orders_payment_provider_check'
      and conrelid = 'public.orders'::regclass
  ) then
    alter table public.orders
      add constraint orders_payment_provider_check
      check (payment_provider in ('manual', 'stripe'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'orders_payment_status_check'
      and conrelid = 'public.orders'::regclass
  ) then
    alter table public.orders
      add constraint orders_payment_status_check
      check (payment_status in ('unpaid', 'pending', 'paid', 'failed', 'refunded'));
  end if;
end;
$$;

create unique index if not exists orders_stripe_checkout_session_idx
  on public.orders(stripe_checkout_session_id)
  where stripe_checkout_session_id is not null;

create index if not exists orders_payment_status_idx
  on public.orders(payment_status, created_at desc);

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

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

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

  update public.orders
  set status = 'confirmed',
      points_awarded = v_points,
      confirmed_at = now(),
      confirmed_by = auth.uid()
  where id = p_order_id
  returning * into v_order;

  update public.profiles
  set points = points + v_points,
      total_spent = total_spent + v_order.total,
      updated_at = now()
  where id = v_order.user_id;

  return v_order;
end;
$$;

revoke all on function public.create_order(jsonb) from public, anon, authenticated;
revoke all on function public.create_payment_order(jsonb) from public, anon;
revoke all on function public.confirm_order(uuid) from public, anon;
grant execute on function public.create_payment_order(jsonb) to authenticated;
grant execute on function public.confirm_order(uuid) to authenticated;

commit;
