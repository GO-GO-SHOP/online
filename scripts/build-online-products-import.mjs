import { readFile, writeFile } from "node:fs/promises";
import vm from "node:vm";

const sourcePath = new URL("../products-data.js", import.meta.url);
const outputPath = new URL("../supabase-online-products-import.sql", import.meta.url);
const source = await readFile(sourcePath, "utf8");
const context = {};
context.window = context;
vm.runInNewContext(source, context, { timeout: 10000 });

const sourceProducts = context.GOGO_SHOP_PRODUCTS;
if (!Array.isArray(sourceProducts) || !sourceProducts.length) {
  throw new Error("products-data.js did not provide a product catalogue.");
}

const products = sourceProducts.map((product) => {
  const id = String(product.id || "").trim();
  const title = String(product.title || product.titleZh || product.titleEn || "").trim();
  const titleEn = String(product.titleEn || "").trim();
  const titleZh = String(product.titleZh || product.title || "").trim();
  const image = String(product.image || "").trim();
  const images = Array.isArray(product.images) ? product.images.filter(Boolean).map(String) : [];
  if (!id || !title || !titleZh || !product.category || !product.sku) {
    throw new Error(`Missing required product field for ${id || "unknown product"}.`);
  }
  return {
    id,
    title,
    title_en: titleEn,
    title_zh: titleZh,
    category: String(product.category).trim(),
    description: String(product.description || ""),
    description_en: String(product.descriptionEn || ""),
    description_zh: String(product.descriptionZh || ""),
    price: Math.max(0, Number(product.price) || 0),
    compare_at_price: Math.max(0, Number(product.compareAtPrice) || 0),
    cost_per_item: Math.max(0, Number(product.costPerItem) || 0),
    stock: Math.max(0, Math.trunc(Number(product.stock) || 0)),
    sales: Math.max(0, Math.trunc(Number(product.sales) || 0)),
    published: Boolean(product.published),
    image,
    images: images.length ? images : (image ? [image] : []),
    vendor: "GO GO SHOP",
    sku: String(product.sku).trim(),
    barcode: String(product.barcode || "").trim(),
    tags: String(product.tags || "").trim()
  };
});

const ids = new Set(products.map((product) => product.id));
if (ids.size !== products.length) throw new Error("Duplicate product IDs found.");

const json = JSON.stringify(products);
const dollarTag = "$gogoshop_online_products$";
if (json.includes(dollarTag)) throw new Error("Product data contains the SQL dollar-quote delimiter.");

const sql = `-- GO GO SHOP online catalogue import.
-- Generated from products-data.js. Run this file in the ONLINE Supabase project only.
-- It imports ${products.length} products, including their public image URLs.
-- Existing rows with the same id are refreshed from the catalogue; sales are preserved.

begin;

with payload(json_data) as (
  values (${dollarTag}${json}${dollarTag}::jsonb)
), imported as (
  select *
  from jsonb_to_recordset((select json_data from payload)) as product(
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
    cost_per_item numeric,
    stock integer,
    sales integer,
    published boolean,
    image text,
    images jsonb,
    vendor text,
    sku text,
    barcode text,
    tags text
  )
)
insert into public.products (
  id,
  title,
  title_en,
  title_zh,
  category,
  description,
  description_en,
  description_zh,
  price,
  compare_at_price,
  cost_per_item,
  stock,
  sales,
  published,
  image,
  images,
  vendor,
  sku,
  barcode,
  tags,
  source_url,
  source_currency,
  source_price,
  source_variants,
  source_attributes,
  deleted_at,
  deleted_was_published,
  updated_at
)
select
  id,
  coalesce(title, ''),
  coalesce(title_en, ''),
  coalesce(title_zh, ''),
  coalesce(category, ''),
  coalesce(description, ''),
  coalesce(description_en, ''),
  coalesce(description_zh, ''),
  greatest(0, coalesce(price, 0)),
  greatest(0, coalesce(compare_at_price, 0)),
  greatest(0, coalesce(cost_per_item, 0)),
  greatest(0, coalesce(stock, 0)),
  greatest(0, coalesce(sales, 0)),
  coalesce(published, false),
  coalesce(image, ''),
  case when jsonb_typeof(images) = 'array' then images else '[]'::jsonb end,
  coalesce(vendor, 'GO GO SHOP'),
  coalesce(sku, ''),
  coalesce(barcode, ''),
  coalesce(tags, ''),
  '',
  '',
  0,
  '[]'::jsonb,
  '[]'::jsonb,
  null,
  false,
  now()
from imported
on conflict (id) do update set
  title = excluded.title,
  title_en = excluded.title_en,
  title_zh = excluded.title_zh,
  category = excluded.category,
  description = excluded.description,
  description_en = excluded.description_en,
  description_zh = excluded.description_zh,
  price = excluded.price,
  compare_at_price = excluded.compare_at_price,
  cost_per_item = excluded.cost_per_item,
  stock = excluded.stock,
  published = excluded.published,
  image = excluded.image,
  images = excluded.images,
  vendor = excluded.vendor,
  sku = excluded.sku,
  barcode = excluded.barcode,
  tags = excluded.tags,
  source_url = excluded.source_url,
  source_currency = excluded.source_currency,
  source_price = excluded.source_price,
  source_variants = excluded.source_variants,
  source_attributes = excluded.source_attributes,
  deleted_at = null,
  deleted_was_published = false,
  updated_at = now();

-- Hide only the nine demo rows created by the empty-project schema.
update public.products
set published = false, updated_at = now()
where id in (
  'blind-box', 'blind-box-1', 'key-chain', 'phone-case',
  'phone-case-1', 'phone-case-2', 'phone-case-3',
  'smart-glasses', 'soft-toy'
)
  and coalesce(tags, '') = ''
  and coalesce(source_url, '') = '';

commit;

select
  count(*) filter (where id like 'kdh-%') as online_catalogue_products,
  count(*) filter (where id like 'kdh-%' and published) as published_products,
  count(*) filter (where id like 'kdh-%' and nullif(trim(image), '') is not null) as products_with_images,
  coalesce(sum(stock) filter (where id like 'kdh-%'), 0) as total_stock
from public.products;
`;

await writeFile(outputPath, sql, "utf8");
console.log(JSON.stringify({
  products: products.length,
  published: products.filter((product) => product.published).length,
  withImages: products.filter((product) => product.image).length,
  bytes: Buffer.byteLength(sql)
}, null, 2));
