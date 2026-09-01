-- Run this file once in Supabase Dashboard > SQL Editor.
-- It adds a secure admin-only way to edit the existing order note field.

begin;

create or replace function public.update_admin_order_note(
  p_order_id uuid,
  p_order_note text default null
)
returns public.orders
language plpgsql
security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found';
  end if;

  update public.orders
  set order_note = left(trim(coalesce(p_order_note, '')), 1000)
  where id = p_order_id
  returning * into v_order;

  return v_order;
end;
$$;

revoke all on function public.update_admin_order_note(uuid, text) from public, anon;
grant execute on function public.update_admin_order_note(uuid, text) to authenticated;

commit;
