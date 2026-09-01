import json
import re
from pathlib import Path

from argostranslate import package, translate


ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATH = ROOT / "source-products.raw.json"
OUTPUT_PATH = ROOT / "source-product-translations.json"


def display_title(name: str) -> str:
    normalized = str(name or "").strip()
    match = re.search(r"\s*([A-Z]{1,8}[A-Z0-9_-]*\d[A-Z0-9_-]*|\d{4,14})[*,;]*$", normalized)
    if not match:
        return normalized
    return normalized[: match.start()].strip() or normalized


def english_translator():
    installed = translate.get_installed_languages()
    source = next((language for language in installed if language.code == "zh"), None)
    target = next((language for language in installed if language.code == "en"), None)
    if source and target:
        return source.get_translation(target)

    package.update_package_index()
    model = next(
        candidate
        for candidate in package.get_available_packages()
        if candidate.from_code == "zh" and candidate.to_code == "en"
    )
    package.install_from_path(model.download())
    installed = translate.get_installed_languages()
    source = next(language for language in installed if language.code == "zh")
    target = next(language for language in installed if language.code == "en")
    return source.get_translation(target)


products = json.loads(SOURCE_PATH.read_text(encoding="utf-8"))
translator = english_translator()
translations = {"categories": {}, "products": {}}

categories = sorted({str(product.get("category") or "其他").strip() for product in products})
for category in categories:
    translations["categories"][category] = translator.translate(category).strip()

for index, product in enumerate(products, start=1):
    product_id = f"kdh-{product['source_id']}"
    title = display_title(product.get("name", ""))
    translations["products"][product_id] = translator.translate(title).strip()
    if index % 25 == 0 or index == len(products):
        print(f"translated {index}/{len(products)}", flush=True)

OUTPUT_PATH.write_text(
    json.dumps(translations, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
print(
    json.dumps(
        {
            "products": len(translations["products"]),
            "categories": len(translations["categories"]),
            "output": str(OUTPUT_PATH),
        },
        ensure_ascii=False,
        indent=2,
    ),
    flush=True,
)
