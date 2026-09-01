-- Voucher system for GO GO SHOP.
-- Run once in Supabase Dashboard > SQL Editor.

begin;

create table if not exists public.vouchers (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  discount_type text not null check (discount_type in ('fixed', 'percent')),
  discount_value numeric(12,2) not null check (discount_value > 0),
  minimum_spend numeric(12,2) not null default 0 check (minimum_spend >= 0),
  maximum_discount numeric(12,2) check (maximum_discount is null or maximum_discount > 0),
  starts_at timestamptz,
  expires_at timestamptz,
  total_redemption_limit integer check (total_redemption_limit is null or total_redemption_limit > 0),
  per_customer_limit integer not null default 1 check (per_customer_limit > 0),
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (discount_type <> 'percent' or discount_value <= 100),
  check (expires_at is null or starts_at is null or expires_at > starts_at)
);

create unique index if not exists vouchers_code_upper_idx on public.vouchers (upper(code));
create index if not exists vouchers_active_dates_idx on public.vouchers (active, starts_at, expires_at);

create table if not exists public.customer_vouchers (
  id uuid primary key default gen_random_uuid(),
  voucher_id uuid not null references public.vouchers(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete cascade,
  source text not null default 'code' check (source in ('code', 'admin')),
  issued_by uuid references public.profiles(id) on delete set null,
  redeemed_at timestamptz not null default now(),
  reserved_at timestamptz,
  used_at timestamptz,
  order_id uuid references public.orders(id) on delete set null
);

create index if not exists customer_vouchers_user_idx on public.customer_vouchers (user_id, redeemed_at desc);
create index if not exists customer_vouchers_voucher_idx on public.customer_vouchers (voucher_id, redeemed_at desc);
create unique index if not exists customer_vouchers_order_idx on public.customer_vouchers (order_id) where order_id is not null;

alter table public.orders add column if not exists subtotal numeric(12,2);
alter table public.orders add column if not exists discount_amount numeric(12,2) not null default 0;
alter table public.orders add column if not exists voucher_id uuid references public.vouchers(id) on delete set null;
alter table public.orders add column if not exists voucher_code text;
alter table public.orders add column if not exists customer_voucher_id uuid references public.customer_vouchers(id) on delete set null;

update public.orders
set subtotal = total
where subtotal is null;

create or replace function public.ensure_order_subtotal()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.subtotal := coalesce(new.subtotal, new.total);
  elsif new.subtotal is null or (coalesce(new.discount_amount, 0) = 0 and new.voucher_id is null) then
    new.subtotal := new.total;
  end if;
  return new;
end;
$$;

drop trigger if exists ensure_order_subtotal_trigger on public.orders;
create trigger ensure_order_subtotal_trigger
  before insert or update of total on public.orders
  for each row execute procedure public.ensure_order_subtotal();

alter table public.orders alter column subtotal set not null;

create or replace function public.normalize_voucher_code()
returns trigger
language plpgsql
as $$
begin
  new.code := upper(regexp_replace(trim(new.code), '\s+', '', 'g'));
  if new.code = '' then raise exception 'Voucher code is required'; end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists normalize_voucher_code_trigger on public.vouchers;
create trigger normalize_voucher_code_trigger
  before insert or update on public.vouchers
  for each row execute procedure public.normalize_voucher_code();

alter table public.vouchers enable row level security;
alter table public.customer_vouchers enable row level security;

drop policy if exists "vouchers admin manage" on public.vouchers;
create policy "vouchers admin manage" on public.vouchers
  for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "customer vouchers read own or admin" on public.customer_vouchers;
create policy "customer vouchers read own or admin" on public.customer_vouchers
  for select using (user_id = auth.uid() or public.is_admin());

drop policy if exists "customer vouchers admin manage" on public.customer_vouchers;
create policy "customer vouchers admin manage" on public.customer_vouchers
  for all using (public.is_admin()) with check (public.is_admin());

create or replace function public.redeem_voucher(p_code text)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_code text := upper(regexp_replace(trim(coalesce(p_code, '')), '\s+', '', 'g'));
  v_voucher public.vouchers%rowtype;
  v_claim_count integer;
  v_customer_count integer;
  v_customer_voucher_id uuid;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if v_code = '' then raise exception 'Enter a voucher code'; end if;

  select * into v_voucher
  from public.vouchers
  where upper(code) = v_code
  for update;

  if not found then raise exception 'Voucher code not found'; end if;
  if not v_voucher.active then raise exception 'Voucher is inactive'; end if;
  if v_voucher.starts_at is not null and now() < v_voucher.starts_at then raise exception 'Voucher is not active yet'; end if;
  if v_voucher.expires_at is not null and now() >= v_voucher.expires_at then raise exception 'Voucher has expired'; end if;

  select count(*) into v_customer_count
  from public.customer_vouchers
  where voucher_id = v_voucher.id and user_id = v_user;

  if v_customer_count >= v_voucher.per_customer_limit then
    raise exception 'Voucher redemption limit reached';
  end if;

  if v_voucher.total_redemption_limit is not null then
    select count(*) into v_claim_count from public.customer_vouchers where voucher_id = v_voucher.id;
    if v_claim_count >= v_voucher.total_redemption_limit then raise exception 'Voucher is fully redeemed'; end if;
  end if;

  insert into public.customer_vouchers (voucher_id, user_id, source)
  values (v_voucher.id, v_user, 'code')
  returning id into v_customer_voucher_id;

  return v_customer_voucher_id;
end;
$$;

create or replace function public.issue_voucher(p_voucher_id uuid, p_user_id uuid)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  v_voucher public.vouchers%rowtype;
  v_claim_count integer;
  v_customer_count integer;
  v_customer_voucher_id uuid;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then raise exception 'Customer not found'; end if;

  select * into v_voucher from public.vouchers where id = p_voucher_id for update;
  if not found then raise exception 'Voucher not found'; end if;

  select count(*) into v_customer_count
  from public.customer_vouchers
  where voucher_id = p_voucher_id and user_id = p_user_id;
  if v_customer_count >= v_voucher.per_customer_limit then raise exception 'Customer voucher limit reached'; end if;

  if v_voucher.total_redemption_limit is not null then
    select count(*) into v_claim_count from public.customer_vouchers where voucher_id = p_voucher_id;
    if v_claim_count >= v_voucher.total_redemption_limit then raise exception 'Voucher issue limit reached'; end if;
  end if;

  insert into public.customer_vouchers (voucher_id, user_id, source, issued_by)
  values (p_voucher_id, p_user_id, 'admin', auth.uid())
  returning id into v_customer_voucher_id;

  return v_customer_voucher_id;
end;
$$;

create or replace function public.get_my_vouchers()
returns table (
  customer_voucher_id uuid,
  voucher_id uuid,
  code text,
  name text,
  discount_type text,
  discount_value numeric,
  minimum_spend numeric,
  maximum_discount numeric,
  starts_at timestamptz,
  expires_at timestamptz,
  active boolean,
  redeemed_at timestamptz,
  reserved_at timestamptz,
  used_at timestamptz,
  order_id uuid
)
language sql
stable
security definer set search_path = public
as $$
  select
    cv.id,
    v.id,
    v.code,
    v.name,
    v.discount_type,
    v.discount_value,
    v.minimum_spend,
    v.maximum_discount,
    v.starts_at,
    v.expires_at,
    v.active,
    cv.redeemed_at,
    cv.reserved_at,
    cv.used_at,
    cv.order_id
  from public.customer_vouchers cv
  join public.vouchers v on v.id = cv.voucher_id
  where cv.user_id = auth.uid()
  order by cv.redeemed_at desc;
$$;

create or replace function public.get_voucher_quote(p_items jsonb, p_customer_voucher_id uuid default null)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_item jsonb;
  v_product public.products%rowtype;
  v_quantity integer;
  v_subtotal numeric(12,2) := 0;
  v_discount numeric(12,2) := 0;
  v_customer_voucher public.customer_vouchers%rowtype;
  v_voucher public.vouchers%rowtype;
  v_reason text := '';
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then
    raise exception 'Cart is empty or invalid';
  end if;

  for v_item in
    select jsonb_build_object(
      'product_id', item ->> 'product_id',
      'quantity', sum(case when coalesce(item ->> 'quantity', '') ~ '^[0-9]+$' then greatest(1, least(99, (item ->> 'quantity')::integer)) else 1 end)
    )
    from jsonb_array_elements(p_items) as entries(item)
    group by item ->> 'product_id'
  loop
    v_quantity := (v_item ->> 'quantity')::integer;
    select * into v_product from public.products
    where id = v_item ->> 'product_id' and published = true and deleted_at is null;
    if not found then raise exception 'Product unavailable: %', v_item ->> 'product_id'; end if;
    if v_product.stock < v_quantity then raise exception 'Insufficient stock for %', v_product.title; end if;
    v_subtotal := v_subtotal + (v_product.price * v_quantity);
  end loop;

  if p_customer_voucher_id is null then
    return jsonb_build_object('eligible', true, 'subtotal', round(v_subtotal, 2), 'discount', 0, 'total', round(v_subtotal, 2), 'reason', '');
  end if;

  select * into v_customer_voucher
  from public.customer_vouchers
  where id = p_customer_voucher_id and user_id = v_user;
  if not found then v_reason := 'Voucher not found';
  elsif v_customer_voucher.used_at is not null then v_reason := 'Voucher has already been used';
  elsif v_customer_voucher.order_id is not null then v_reason := 'Voucher is reserved for another order';
  end if;

  if v_reason = '' then
    select * into v_voucher from public.vouchers where id = v_customer_voucher.voucher_id;
    if not found or not v_voucher.active then v_reason := 'Voucher is inactive';
    elsif v_voucher.starts_at is not null and now() < v_voucher.starts_at then v_reason := 'Voucher is not active yet';
    elsif v_voucher.expires_at is not null and now() >= v_voucher.expires_at then v_reason := 'Voucher has expired';
    elsif v_subtotal < v_voucher.minimum_spend then v_reason := 'Minimum spend not reached';
    end if;
  end if;

  if v_reason = '' then
    if v_voucher.discount_type = 'fixed' then
      v_discount := least(v_subtotal, v_voucher.discount_value);
    else
      v_discount := round(v_subtotal * v_voucher.discount_value / 100, 2);
      if v_voucher.maximum_discount is not null then v_discount := least(v_discount, v_voucher.maximum_discount); end if;
      v_discount := least(v_subtotal, v_discount);
    end if;
  end if;

  return jsonb_build_object(
    'eligible', v_reason = '',
    'subtotal', round(v_subtotal, 2),
    'discount', round(v_discount, 2),
    'total', round(v_subtotal - v_discount, 2),
    'reason', v_reason,
    'voucher_code', case when v_reason = '' then v_voucher.code else null end
  );
end;
$$;

drop function if exists public.create_payment_order(jsonb);
drop function if exists public.create_payment_order(jsonb, uuid);
create function public.create_payment_order(p_items jsonb, p_customer_voucher_id uuid default null)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_order_id uuid;
  v_order public.orders%rowtype;
  v_customer_voucher public.customer_vouchers%rowtype;
  v_voucher public.vouchers%rowtype;
  v_discount numeric(12,2) := 0;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  v_order_id := public.create_order(p_items);
  select * into v_order from public.orders where id = v_order_id and user_id = v_user for update;
  if not found then raise exception 'Unable to create order'; end if;

  if p_customer_voucher_id is not null then
    select * into v_customer_voucher
    from public.customer_vouchers
    where id = p_customer_voucher_id and user_id = v_user
    for update;
    if not found then raise exception 'Voucher not found'; end if;
    if v_customer_voucher.used_at is not null then raise exception 'Voucher has already been used'; end if;
    if v_customer_voucher.order_id is not null then raise exception 'Voucher is reserved for another order'; end if;

    select * into v_voucher from public.vouchers where id = v_customer_voucher.voucher_id for update;
    if not found or not v_voucher.active then raise exception 'Voucher is inactive'; end if;
    if v_voucher.starts_at is not null and now() < v_voucher.starts_at then raise exception 'Voucher is not active yet'; end if;
    if v_voucher.expires_at is not null and now() >= v_voucher.expires_at then raise exception 'Voucher has expired'; end if;
    if v_order.total < v_voucher.minimum_spend then raise exception 'Minimum spend not reached'; end if;

    if v_voucher.discount_type = 'fixed' then
      v_discount := least(v_order.total, v_voucher.discount_value);
    else
      v_discount := round(v_order.total * v_voucher.discount_value / 100, 2);
      if v_voucher.maximum_discount is not null then v_discount := least(v_discount, v_voucher.maximum_discount); end if;
      v_discount := least(v_order.total, v_discount);
    end if;

    update public.customer_vouchers
    set reserved_at = now(), order_id = v_order_id
    where id = v_customer_voucher.id;
  end if;

  update public.orders
  set subtotal = v_order.total,
      discount_amount = round(v_discount, 2),
      total = round(v_order.total - v_discount, 2),
      voucher_id = case when p_customer_voucher_id is null then null else v_voucher.id end,
      voucher_code = case when p_customer_voucher_id is null then null else v_voucher.code end,
      customer_voucher_id = p_customer_voucher_id,
      payment_provider = 'stripe',
      payment_status = 'pending'
  where id = v_order_id;

  return v_order_id;
end;
$$;

create or replace function public.cancel_payment_order(p_order_id uuid)
returns boolean
language plpgsql
security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  select * into v_order from public.orders
  where id = p_order_id and user_id = auth.uid()
  for update;
  if not found then raise exception 'Order not found'; end if;
  if v_order.payment_provider <> 'stripe' or v_order.payment_status = 'paid' then raise exception 'Order cannot be cancelled'; end if;

  update public.customer_vouchers
  set reserved_at = null, order_id = null
  where id = v_order.customer_voucher_id and used_at is null;

  update public.orders
  set status = 'cancelled', payment_status = 'failed'
  where id = p_order_id;
  return true;
end;
$$;

create or replace function public.release_order_voucher_on_delete()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  update public.customer_vouchers
  set reserved_at = null, used_at = null, order_id = null
  where id = old.customer_voucher_id;
  return old;
end;
$$;

drop trigger if exists release_order_voucher_on_delete_trigger on public.orders;
create trigger release_order_voucher_on_delete_trigger
  before delete on public.orders
  for each row execute procedure public.release_order_voucher_on_delete();

create or replace function public.sync_recycled_order_voucher()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if old.customer_voucher_id is null then return new; end if;
  if old.deleted_at is null and new.deleted_at is not null then
    update public.customer_vouchers
    set reserved_at = null, used_at = null, order_id = null
    where id = old.customer_voucher_id;
  elsif old.deleted_at is not null and new.deleted_at is null then
    if exists (
      select 1 from public.customer_vouchers
      where id = old.customer_voucher_id and order_id is not null and order_id <> old.id
    ) then
      raise exception 'The order voucher has been used by another order';
    end if;
    update public.customer_vouchers
    set order_id = old.id,
        reserved_at = coalesce(reserved_at, now()),
        used_at = case when old.payment_status = 'paid' then coalesce(used_at, old.paid_at, now()) else null end
    where id = old.customer_voucher_id;
  end if;
  return new;
end;
$$;

drop trigger if exists sync_recycled_order_voucher_trigger on public.orders;
create trigger sync_recycled_order_voucher_trigger
  before update of deleted_at on public.orders
  for each row execute procedure public.sync_recycled_order_voucher();

create or replace function public.import_game_voucher(
  p_code text,
  p_name text,
  p_discount_type text,
  p_discount_value numeric,
  p_minimum_spend numeric default 0,
  p_maximum_discount numeric default null,
  p_starts_at timestamptz default now(),
  p_expires_at timestamptz default null,
  p_total_redemption_limit integer default 1,
  p_per_customer_limit integer default 1,
  p_token text default ''
)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  v_code text := upper(regexp_replace(trim(coalesce(p_code, '')), '\s+', '', 'g'));
  v_name text := trim(coalesce(p_name, ''));
  v_token text := trim(coalesce(p_token, ''));
  v_existing public.vouchers%rowtype;
  v_voucher_id uuid;
  v_discount_value numeric(12,2) := round(coalesce(p_discount_value, 0)::numeric, 2);
begin
  if v_token <> 'HAPPY_SHEEP_FARM_2026_IMPORT' then
    raise exception 'Unauthorized import';
  end if;
  if v_code = '' then raise exception 'Voucher code is required'; end if;
  if v_name = '' then raise exception 'Voucher name is required'; end if;
  if p_discount_type not in ('fixed', 'percent') then raise exception 'Invalid discount type'; end if;
  if v_discount_value <= 0 then raise exception 'Discount value must be greater than zero'; end if;
  if p_discount_type = 'percent' and v_discount_value > 100 then raise exception 'Percent discount cannot exceed 100'; end if;
  if p_per_customer_limit is null or p_per_customer_limit <= 0 then raise exception 'Per customer limit must be positive'; end if;
  if p_total_redemption_limit is not null and p_total_redemption_limit <= 0 then raise exception 'Total redemption limit must be positive'; end if;

  select * into v_existing
  from public.vouchers
  where upper(code) = v_code
  for update;

  if found then
    update public.vouchers
    set
      code = v_code,
      name = v_name,
      discount_type = p_discount_type,
      discount_value = v_discount_value,
      minimum_spend = coalesce(p_minimum_spend, 0),
      maximum_discount = p_maximum_discount,
      starts_at = p_starts_at,
      expires_at = p_expires_at,
      total_redemption_limit = p_total_redemption_limit,
      per_customer_limit = p_per_customer_limit,
      active = true
    where id = v_existing.id
    returning id into v_voucher_id;
  else
    insert into public.vouchers (
      code,
      name,
      discount_type,
      discount_value,
      minimum_spend,
      maximum_discount,
      starts_at,
      expires_at,
      total_redemption_limit,
      per_customer_limit,
      active
    ) values (
      v_code,
      v_name,
      p_discount_type,
      v_discount_value,
      coalesce(p_minimum_spend, 0),
      p_maximum_discount,
      p_starts_at,
      p_expires_at,
      p_total_redemption_limit,
      p_per_customer_limit,
      true
    )
    returning id into v_voucher_id;
  end if;

  return v_voucher_id;
end;
$$;

create or replace function public.get_game_voucher_status(
  p_codes text[],
  p_token text default ''
)
returns table (
  code text,
  status text,
  redeemed_at timestamptz,
  used_at timestamptz
)
language plpgsql
security definer set search_path = public
as $$
declare
  v_query_code text;
begin
  if trim(coalesce(p_token, '')) <> 'HAPPY_SHEEP_FARM_2026_IMPORT' then
    raise exception 'Unauthorized status lookup';
  end if;
  if p_codes is null or cardinality(p_codes) = 0 then
    return;
  end if;
  if cardinality(p_codes) > 100 then
    raise exception 'Too many voucher codes';
  end if;

  for v_query_code in
    select distinct upper(regexp_replace(trim(coalesce(input_code, '')), '\s+', '', 'g'))
    from unnest(p_codes) as input_codes(input_code)
    where trim(coalesce(input_code, '')) <> ''
  loop
    return query
    select
      v.code,
      case
        when cv.used_at is not null then 'used'
        when cv.id is not null then 'pending_use'
        else 'pending_redeem'
      end,
      cv.redeemed_at,
      cv.used_at
    from public.vouchers v
    left join lateral (
      select customer_voucher.id, customer_voucher.redeemed_at, customer_voucher.used_at
      from public.customer_vouchers customer_voucher
      where customer_voucher.voucher_id = v.id
      order by customer_voucher.redeemed_at desc
      limit 1
    ) cv on true
    where upper(v.code) = v_query_code;
  end loop;
end;
$$;

revoke all on function public.redeem_voucher(text) from public, anon;
revoke all on function public.issue_voucher(uuid, uuid) from public, anon;
revoke all on function public.get_my_vouchers() from public, anon;
revoke all on function public.get_voucher_quote(jsonb, uuid) from public, anon;
revoke all on function public.create_payment_order(jsonb, uuid) from public, anon;
revoke all on function public.cancel_payment_order(uuid) from public, anon;
revoke all on function public.import_game_voucher(text, text, text, numeric, numeric, numeric, timestamptz, timestamptz, integer, integer, text) from public, anon;
revoke all on function public.get_game_voucher_status(text[], text) from public, anon;

grant execute on function public.redeem_voucher(text) to authenticated;
grant execute on function public.issue_voucher(uuid, uuid) to authenticated;
grant execute on function public.get_my_vouchers() to authenticated;
grant execute on function public.get_voucher_quote(jsonb, uuid) to authenticated;
grant execute on function public.create_payment_order(jsonb, uuid) to authenticated;
grant execute on function public.cancel_payment_order(uuid) to authenticated;
grant execute on function public.import_game_voucher(text, text, text, numeric, numeric, numeric, timestamptz, timestamptz, integer, integer, text) to anon, authenticated;
grant execute on function public.get_game_voucher_status(text[], text) to anon, authenticated;

grant select, insert, update, delete on public.vouchers to authenticated;
grant select, insert, update, delete on public.customer_vouchers to authenticated;

commit;
