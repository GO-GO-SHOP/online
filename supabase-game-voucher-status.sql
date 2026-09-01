-- Run once in the GO GO SHOP Supabase SQL Editor.

begin;

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

revoke all on function public.get_game_voucher_status(text[], text) from public, anon;
grant execute on function public.get_game_voucher_status(text[], text) to anon, authenticated;

notify pgrst, 'reload schema';

commit;
