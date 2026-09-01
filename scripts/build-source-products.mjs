import { readFile, writeFile } from "node:fs/promises";

const sourcePath = new URL("../source-products.raw.json", import.meta.url);
const translationsPath = new URL("../source-product-translations.json", import.meta.url);
const outputPath = new URL("../products-data.js", import.meta.url);
const sourceProducts = JSON.parse(await readFile(sourcePath, "utf8"));
let translations = { categories: {}, products: {} };
try {
  translations = JSON.parse(await readFile(translationsPath, "utf8"));
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}

function extractSku(name, sourceId) {
  const normalizedName = String(name || "").trim();
  const match = normalizedName.match(/(?:\s*)([A-Z]{1,8}[A-Z0-9_-]*\d[A-Z0-9_-]*|\d{4,14})[*,;]*$/);
  if (!match) return { sku: String(sourceId), title: normalizedName };
  const candidate = match[1];
  return {
    sku: candidate,
    title: normalizedName.slice(0, match.index).trim() || normalizedName
  };
}

const products = sourceProducts.map((source, index) => {
  const { sku, title } = extractSku(source.name, source.source_id);
  const image = String(source.image || "").trim();
  const stock = source.stock === "售罄" ? 0 : Math.max(0, Number(source.stock) || 0);
  const published = source.status === "销售中";
  return {
    id: `kdh-${source.source_id}`,
    handle: `kdh-${source.source_id}`,
    title,
    titleZh: title,
    titleEn: String(translations.products?.[`kdh-${source.source_id}`] || "").trim(),
    category: String(source.category || "其他").trim(),
    productType: String(source.category || "其他").trim(),
    description: "",
    descriptionZh: "",
    descriptionEn: "",
    price: Number(source.price) || 0,
    compareAtPrice: 0,
    costPerItem: Number(source.cost_price) || 0,
    stock,
    sales: Number(String(source.sales || "0").split("+")[0]) || 0,
    published,
    status: published ? "active" : "draft",
    onlineStore: published,
    image,
    images: image ? [image] : [],
    vendor: "GO GO SHOP",
    sku,
    barcode: "",
    tags: `kuaidihe,source-id:${source.source_id}`,
    sourceId: String(source.source_id),
    sourceCreatedAt: String(source.created_at || ""),
    taxable: true,
    trackQuantity: true,
    featured: index < 12,
    views: 0
  };
});

const duplicateSkus = [...new Set(products
  .map((product) => product.sku)
  .filter((sku, index, all) => all.indexOf(sku) !== index))];

if (products.length !== sourceProducts.length) throw new Error("Product count changed during conversion.");
if (new Set(products.map((product) => product.id)).size !== products.length) throw new Error("Duplicate product IDs found.");
if (duplicateSkus.length) throw new Error(`Duplicate SKUs found: ${duplicateSkus.join(", ")}`);
if (products.some((product) => !product.title || !product.category || !product.sku)) throw new Error("Required product fields are missing.");

const categoryTranslations = Object.fromEntries(
  [...new Set(products.map((product) => product.category))]
    .map((category) => [category, String(translations.categories?.[category] || category).trim()])
);
const output = `// Generated from the authenticated source catalogue. Rebuild with scripts/build-source-products.mjs.\nwindow.GOGO_SHOP_CATEGORY_TRANSLATIONS = Object.freeze(${JSON.stringify(categoryTranslations, null, 2)});\nwindow.GOGO_SHOP_PRODUCTS = Object.freeze(${JSON.stringify(products, null, 2)});\n`;
await writeFile(outputPath, output, "utf8");

const categories = new Set(products.map((product) => product.category));
console.log(JSON.stringify({
  products: products.length,
  categories: categories.size,
  published: products.filter((product) => product.published).length,
  soldOut: products.filter((product) => product.stock === 0).length,
  extractedSkus: products.filter((product) => product.sku !== product.sourceId).length,
  fallbackSkus: products.filter((product) => product.sku === product.sourceId).length,
  translatedProducts: products.filter((product) => product.titleEn).length,
  translatedCategories: Object.values(categoryTranslations).filter(Boolean).length
}, null, 2));
