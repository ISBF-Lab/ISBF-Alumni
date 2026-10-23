"""Rebuild map centers offline from fixed, CC0 Wikidata facts and existing curated centers."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "assets/geography"


def short_name(name):
    return name.removesuffix("市")


def build():
    cities = json.loads((ROOT / "cities.json").read_text(encoding="utf-8"))
    old = json.loads((ROOT / "catalog.json").read_text(encoding="utf-8"))
    china = next(country for country in old["countries"] if country["code"] == "CN")
    curated = {region["code"]: region["cities"] for region in china["regions"]}
    facts = json.loads((ROOT / "city-centers-source.json").read_text(encoding="utf-8"))
    centers = {}
    unmatched = []
    for province, options in cities.items():
        centers[province] = []
        for city in options:
            # Existing centers have province-scoped short IDs. Preserve their coordinates
            # by exact display name, allowing only the conventional trailing 市 suffix.
            matches = [item for item in curated[province] if short_name(item["name"]) == short_name(city["name"])]
            if province in {"HK", "MO"}:
                matches = [item for item in curated[province] if item["code"] == city["code"]]
            if len(matches) == 1:
                point = {key: matches[0][key] for key in ("lat", "lng")}
            else:
                matches = []
                for item in facts["entities"]:
                    same_name = any(short_name(name) == short_name(city["name"]) for name in item["names"])
                    same_code = city["code"] in item["p442"]
                    # Taiwan local IDs are not official codes: exact Chinese name plus
                    # a five-digit MOI identifier identifies its city/county entity.
                    if province == "TW":
                        same_code = bool(item["p5020"])
                        same_name = city["name"] in item["names"]
                    if same_code and same_name:
                        matches.append(item)
                unique = {(item["lat"], item["lng"]) for item in matches}
                point = dict(zip(("lat", "lng"), unique.pop())) if len(unique) == 1 else None
            if point:
                assert -90 <= point["lat"] <= 90 and -180 <= point["lng"] <= 180
                centers[province].append({**city, **point})
            else:
                unmatched.append({"region": province, **city})
    return centers, unmatched


if __name__ == "__main__":
    centers, unmatched = build()
    (ROOT / "city-centers.json").write_text(json.dumps(centers, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (ROOT / "city-centers-unmatched.json").write_text(json.dumps(unmatched, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Verified centers: {sum(map(len, centers.values()))}; unmatched: {len(unmatched)}")
