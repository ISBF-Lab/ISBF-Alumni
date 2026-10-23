import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "assets/geography"
catalog = json.loads((root / "catalog.json").read_text(encoding="utf-8"))
countries = {item["code"]: item for item in catalog["countries"]}
assert not {"TW", "XK", "EH"} & countries.keys()
assert "PS" in countries
regions = {item["code"]: item for item in countries["CN"]["regions"]}
assert regions["TW"]["name"] == "台湾省"
assert regions["HK"]["name"] == "中国香港"
assert regions["MO"]["name"] == "中国澳门"
world = json.loads((root / "world.geojson").read_text(encoding="utf-8"))["features"]
assert not any(item["properties"].get("country_code") in {"TW", "XK", "EH"} for item in world)
assert sum(not item["properties"] for item in world) == 2
china = next(item for item in world if item["properties"].get("code") == "CN")
detail = json.loads((root / "regions/CN.geojson").read_text(encoding="utf-8"))["features"]
taiwan = next(item for item in detail if item["properties"]["code"] == "TW")
assert taiwan["properties"] == {"code": "TW", "country_code": "CN", "name": "台湾省"}
assert china["geometry"]["type"] == "MultiPolygon"
assert taiwan["geometry"]["coordinates"] in china["geometry"]["coordinates"]
assert len(detail) == 32 and len(regions) == 34
print("Geography catalog, retained outlines and Taiwan layer checks passed.")

# Fixed centers must be a complete, reproducible partition of selectable cities.
import importlib.util

builder_path = Path(__file__).with_name("build_city_centers.py")
spec = importlib.util.spec_from_file_location("city_center_builder", builder_path)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
generated, unmatched = builder.build()
centers = json.loads((root / "city-centers.json").read_text(encoding="utf-8"))
assert generated == centers
assert unmatched == json.loads((root / "city-centers-unmatched.json").read_text(encoding="utf-8"))
options = json.loads((root / "cities.json").read_text(encoding="utf-8"))
all_options = {(region, city["code"]): city["name"] for region, cities in options.items() for city in cities}
mapped = {(region, city["code"]): city for region, cities in centers.items() for city in cities}
missing = {(city["region"], city["code"]) for city in unmatched}
assert mapped.keys().isdisjoint(missing)
assert mapped.keys() | missing == all_options.keys()
assert len(mapped) == 383 and len(missing) == 10
assert sum(len(cities) for cities in centers.values()) == len(mapped)
for key, city in mapped.items():
    assert set(city) == {"code", "name", "lat", "lng"}
    assert city["name"] == all_options[key]
    assert -90 <= city["lat"] <= 90 and -180 <= city["lng"] <= 180
assert len(centers["TW"]) == 22
for province in regions.values():
    for old in province["cities"]:
        matches = [city for city in centers[province["code"]] if builder.short_name(city["name"]) == builder.short_name(old["name"])]
        if province["code"] in {"HK", "MO"}:
            matches = [city for city in centers[province["code"]] if city["code"] == old["code"]]
        assert len(matches) == 1
        assert (matches[0]["lat"], matches[0]["lng"]) == (old["lat"], old["lng"])
assert mapped[("GD", "4403")]["lng"] == 114.0579
assert mapped[("JS", "3205")]["lng"] == 120.5853
print("Verified city centers, curated priority, unique IDs and explicit unmatched checks passed.")
