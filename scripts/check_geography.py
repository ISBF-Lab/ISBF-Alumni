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
