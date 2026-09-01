begin;

-- Preserve historical order lines while allowing products to be permanently deleted.
alter table public.order_items
  alter column product_id drop not null;

alter table public.order_items
  drop constraint if exists order_items_product_id_fkey;

alter table public.order_items
  add constraint order_items_product_id_fkey
  foreign key (product_id)
  references public.products(id)
  on delete set null;

delete from public.products
where tags = '__gogoshop_purged__';

commit;
