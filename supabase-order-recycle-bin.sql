begin;

alter table public.orders
  add column if not exists deleted_at timestamptz;

alter table public.orders
  add column if not exists deleted_by uuid references public.profiles(id) on delete set null;

create index if not exists orders_deleted_at_idx
  on public.orders(deleted_at, created_at desc);

create or replace function public.soft_delete_order(p_order_id uuid)
returns public.orders
language plpgsql
security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_item public.order_items%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

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
  set deleted_at = now(),
      deleted_by = auth.uid()
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
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then raise exception 'Order not found'; end if;
  if v_order.deleted_at is null then raise exception 'Order is not in the recycle bin'; end if;

  if v_order.status = 'confirmed' then
    for v_item in select * from public.order_items where order_id = p_order_id
    loop
      select stock into v_stock
      from public.products
      where id = v_item.product_id
      for update;

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
  set deleted_at = null,
      deleted_by = null
  where id = p_order_id
  returning * into v_order;

  return v_order;
end;
$$;

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

revoke all on function public.soft_delete_order(uuid) from public, anon;
revoke all on function public.restore_order(uuid) from public, anon;
grant execute on function public.soft_delete_order(uuid) to authenticated;
grant execute on function public.restore_order(uuid) to authenticated;

do $$
begin
  if to_regprocedure('public.delete_order(uuid)') is not null then
    execute 'revoke all on function public.delete_order(uuid) from authenticated';
  end if;
end
$$;

commit;
