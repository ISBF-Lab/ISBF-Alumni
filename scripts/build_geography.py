import json
import math
import re
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/geography/source"
OUT = ROOT / "assets/geography"
DETAIL_CODES = {"CN": "CHN", "US": "USA", "CA": "CAN", "GB": "GBR", "AU": "AUS", "JP": "JPN", "DE": "DEU", "FR": "FRA"}
COUNTRY_ZH = {
    "CN": "\u4e2d\u56fd", "US": "\u7f8e\u56fd", "CA": "\u52a0\u62ff\u5927",
    "GB": "\u82f1\u56fd", "AU": "\u6fb3\u5927\u5229\u4e9a", "JP": "\u65e5\u672c",
    "DE": "\u5fb7\u56fd", "FR": "\u6cd5\u56fd"
}
REGION_ZH = {
    "BJ": "\u5317\u4eac", "TJ": "\u5929\u6d25", "HE": "\u6cb3\u5317", "SX": "\u5c71\u897f", "NM": "\u5185\u8499\u53e4",
    "LN": "\u8fbd\u5b81", "JL": "\u5409\u6797", "HL": "\u9ed1\u9f99\u6c5f", "SH": "\u4e0a\u6d77", "JS": "\u6c5f\u82cf",
    "ZJ": "\u6d59\u6c5f", "AH": "\u5b89\u5fbd", "FJ": "\u798f\u5efa", "JX": "\u6c5f\u897f", "SD": "\u5c71\u4e1c",
    "HA": "\u6cb3\u5357", "HB": "\u6e56\u5317", "HN": "\u6e56\u5357", "GD": "\u5e7f\u4e1c", "GX": "\u5e7f\u897f",
    "HI": "\u6d77\u5357", "CQ": "\u91cd\u5e86", "SC": "\u56db\u5ddd", "GZ": "\u8d35\u5dde", "YN": "\u4e91\u5357",
    "XZ": "\u897f\u85cf", "SN": "\u9655\u897f", "GS": "\u7518\u8083", "QH": "\u9752\u6d77", "NX": "\u5b81\u590f",
    "XJ": "\u65b0\u7586"
}
CITIES = [
    ("BJ", "BJ", "\u5317\u4eac", 39.9042, 116.4074), ("TJ", "TJ", "\u5929\u6d25", 39.0842, 117.2010),
    ("HE", "SJZ", "\u77f3\u5bb6\u5e84", 38.0428, 114.5149), ("SX", "TY", "\u592a\u539f", 37.8706, 112.5489),
    ("NM", "HHHT", "\u547c\u548c\u6d69\u7279", 40.8426, 111.7492), ("LN", "SY", "\u6c88\u9633", 41.8057, 123.4315),
    ("LN", "DL", "\u5927\u8fde", 38.9140, 121.6147), ("JL", "CC", "\u957f\u6625", 43.8171, 125.3235),
    ("HL", "HEB", "\u54c8\u5c14\u6ee8", 45.8038, 126.5350), ("SH", "SH", "\u4e0a\u6d77", 31.2304, 121.4737),
    ("JS", "NJ", "\u5357\u4eac", 32.0603, 118.7969), ("JS", "SZ", "\u82cf\u5dde", 31.2989, 120.5853),
    ("ZJ", "HZ", "\u676d\u5dde", 30.2741, 120.1551), ("ZJ", "NB", "\u5b81\u6ce2", 29.8683, 121.5440),
    ("AH", "HF", "\u5408\u80a5", 31.8206, 117.2272), ("FJ", "FZ", "\u798f\u5dde", 26.0745, 119.2965),
    ("FJ", "XM", "\u53a6\u95e8", 24.4798, 118.0894), ("JX", "NC", "\u5357\u660c", 28.6820, 115.8579),
    ("SD", "JN", "\u6d4e\u5357", 36.6512, 117.1201), ("SD", "QD", "\u9752\u5c9b", 36.0671, 120.3826),
    ("HA", "ZZ", "\u90d1\u5dde", 34.7466, 113.6254), ("HB", "WH", "\u6b66\u6c49", 30.5928, 114.3055),
    ("HN", "CS", "\u957f\u6c99", 28.2282, 112.9388), ("GD", "GZ", "\u5e7f\u5dde", 23.1291, 113.2644),
    ("GD", "SZ", "\u6df1\u5733", 22.5431, 114.0579), ("GD", "ZH", "\u73e0\u6d77", 22.2707, 113.5767),
    ("GX", "NN", "\u5357\u5b81", 22.8170, 108.3665), ("HI", "HK", "\u6d77\u53e3", 20.0440, 110.1999),
    ("CQ", "CQ", "\u91cd\u5e86", 29.5630, 106.5516), ("SC", "CD", "\u6210\u90fd", 30.5728, 104.0668),
    ("GZ", "GY", "\u8d35\u9633", 26.6470, 106.6302), ("YN", "KM", "\u6606\u660e", 25.0389, 102.7183),
    ("XZ", "LS", "\u62c9\u8428", 29.6520, 91.1721), ("SN", "XA", "\u897f\u5b89", 34.3416, 108.9398),
    ("GS", "LZ", "\u5170\u5dde", 36.0611, 103.8343), ("QH", "XN", "\u897f\u5b81", 36.6171, 101.7782),
    ("NX", "YC", "\u94f6\u5ddd", 38.4872, 106.2309), ("XJ", "URC", "\u4e4c\u9c81\u6728\u9f50", 43.8256, 87.6168),
    ("HK", "HK", "\u9999\u6e2f", 22.3193, 114.1694), ("MO", "MO", "\u6fb3\u95e8", 22.1987, 113.5439)
]

def ensure_sources():
    SOURCE.mkdir(parents=True, exist_ok=True)
    downloads = {
        "ne_110m_admin_0_countries.geojson": "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson",
    }
    query = urlencode({
        "where": "ADM0_A3 IN ('USA','CAN','GBR','AUS','JPN','DEU','FRA','CHN')",
        "outFields": "*",
        "returnGeometry": "true",
        "outSR": "4326",
        "f": "geojson",
    })
    downloads["admin1-selected.geojson"] = (
        "https://services.arcgis.com/0xnwbwUttaTjns4i/ArcGIS/rest/services/"
        "Natural_Earth_quick_start/FeatureServer/47/query?" + query
    )
    for filename, url in downloads.items():
        target = SOURCE / filename
        if target.exists() and target.stat().st_size > 0:
            continue
        request = Request(url, headers={"User-Agent": "ISBF-Alumni geography asset builder"})
        with urlopen(request, timeout=180) as response, target.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)


def point_segment_distance_sq(point, start, end):
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    if dx == 0 and dy == 0:
        return (point[0] - start[0]) ** 2 + (point[1] - start[1]) ** 2
    t = max(0.0, min(1.0, ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / (dx * dx + dy * dy)))
    x = start[0] + t * dx
    y = start[1] + t * dy
    return (point[0] - x) ** 2 + (point[1] - y) ** 2

def simplify_open(points, tolerance):
    if len(points) <= 2:
        return points
    keep = {0, len(points) - 1}
    stack = [(0, len(points) - 1)]
    limit = tolerance * tolerance
    while stack:
        first, last = stack.pop()
        best_index = None
        best_distance = limit
        for index in range(first + 1, last):
            distance = point_segment_distance_sq(points[index], points[first], points[last])
            if distance > best_distance:
                best_index, best_distance = index, distance
        if best_index is not None:
            keep.add(best_index)
            stack.append((first, best_index))
            stack.append((best_index, last))
    return [points[index] for index in sorted(keep)]

def simplify_ring(points, tolerance):
    if len(points) <= 5:
        return points
    ring = points[:-1] if points[0] == points[-1] else points[:]
    start = ring[0]
    split = max(range(1, len(ring)), key=lambda index: (ring[index][0] - start[0]) ** 2 + (ring[index][1] - start[1]) ** 2)
    first = simplify_open(ring[:split + 1], tolerance)
    second = simplify_open(ring[split:] + [ring[0]], tolerance)
    output = first[:-1] + second[:-1] + [first[0]]
    return output if len(output) >= 4 else points

def simplify_geometry(geometry, tolerance):
    if not geometry:
        return geometry
    kind = geometry["type"]
    coords = geometry["coordinates"]
    if kind == "Polygon":
        coords = [[simplify_ring(ring, tolerance) for ring in coords]]
        return {"type": kind, "coordinates": coords[0]}
    if kind == "MultiPolygon":
        return {"type": kind, "coordinates": [[simplify_ring(ring, tolerance) for ring in polygon] for polygon in coords]}
    return geometry

def main():
    ensure_sources()
    world = json.loads((SOURCE / "ne_110m_admin_0_countries.geojson").read_text(encoding="utf-8"))
    a3_to_a2 = {}
    country_names = {}
    world_features = []
    for feature in world["features"]:
        properties = feature["properties"]
        code = (properties.get("ISO_A2") or "").upper()
        if not re.fullmatch(r"[A-Z]{2}", code):
            code = (properties.get("ISO_A2_EH") or "").upper()
        if not re.fullmatch(r"[A-Z]{2}", code):
            continue
        name = COUNTRY_ZH.get(code) or properties.get("NAME_ZH") or properties.get("NAME") or properties.get("ADMIN") or code
        a3 = (properties.get("ADM0_A3") or "").upper()
        if a3:
            a3_to_a2[a3] = code
        country_names[code] = name
        world_features.append({
            "type": "Feature",
            "properties": {"code": code, "country_code": code, "name": name},
            "geometry": simplify_geometry(feature.get("geometry"), 0.15),
        })
    (OUT / "world.geojson").write_text(json.dumps({"type": "FeatureCollection", "features": world_features}, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")

    source = json.loads((SOURCE / "admin1-selected.geojson").read_text(encoding="utf-8"))
    regions_by_country = {code: [] for code in DETAIL_CODES}
    for feature in source["features"]:
        props = feature["properties"]
        country_code = a3_to_a2.get((props.get("adm0_a3") or "").upper())
        if country_code not in DETAIL_CODES:
            continue
        iso = (props.get("iso_3166_2") or "").upper()
        if not re.fullmatch(r"[A-Z]{2}-[A-Z0-9]{1,3}", iso):
            continue
        code = iso.split("-", 1)[1]
        if country_code == "CN":
            name = REGION_ZH.get(code)
            if not name:
                continue
        else:
            name = props.get("name_en") or props.get("name") or code
        regions_by_country[country_code].append({
            "type": "Feature",
            "properties": {"code": code, "country_code": country_code, "name": name},
            "geometry": simplify_geometry(feature.get("geometry"), 0.025),
        })
    for code, features in regions_by_country.items():
        features.sort(key=lambda item: item["properties"]["name"])
        (OUT / "regions" / f"{code}.geojson").write_text(
            json.dumps({"type": "FeatureCollection", "features": features}, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8"
        )

    region_catalog = {}
    for code, features in regions_by_country.items():
        region_catalog[code] = [
            {"code": item["properties"]["code"], "name": item["properties"]["name"], "cities": []}
            for item in features
        ]
    region_catalog["CN"].extend([
        {"code": "HK", "name": "\u9999\u6e2f\u7279\u522b\u884c\u653f\u533a", "cities": []},
        {"code": "MO", "name": "\u6fb3\u95e8\u7279\u522b\u884c\u653f\u533a", "cities": []},
    ])
    by_region = {
        code: {region["code"]: region for region in regions}
        for code, regions in region_catalog.items()
    }
    for country, city_code, city_name, lat, lng in CITIES:
        by_region["CN"][country]["cities"].append({
            "code": city_code, "name": city_name, "lat": lat, "lng": lng
        })
    countries = [
        {
            "code": code,
            "name": name,
            "regions": region_catalog.get(code, []),
        }
        for code, name in sorted(country_names.items(), key=lambda item: item[1])
    ]
    catalog = {"countries": countries, "default_country": "CN"}
    (OUT / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print("world countries:", len(world_features))
    print("detailed regions:", {code: len(regions) for code, regions in regions_by_country.items()})
    print("assets:", {str(path.relative_to(ROOT)): path.stat().st_size for path in [OUT / "world.geojson", OUT / "catalog.json", *(OUT / "regions").glob("*.geojson")]})

if __name__ == "__main__":
    main()
