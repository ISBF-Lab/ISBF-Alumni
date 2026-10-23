# City center provenance

The map uses fixed city-level representative points, never personal addresses or runtime geocoding. Existing 40 curated points from `catalog.json` retain priority; these were already distributed with this plugin. They match current city IDs by province and exact Chinese name, allowing only a trailing 市. Hong Kong and Macau retain their existing region-ID centers.

## Supplemental structured source

- Wikidata structured data, retrieved 2026-10-23, CC0 1.0: https://www.wikidata.org/wiki/Wikidata:Licensing
- License: https://creativecommons.org/publicdomain/zero/1.0/legalcode
- Frozen facts: `city-centers-source.json`, SHA-256 `e4a3ff88f4092dce0d3c4fbb77a0a2110883ceb197046e728edd7132d9d858b4`.
- Each entry retains entity QID, exact revision ID, Chinese labels/aliases, identifiers and one unambiguous Earth coordinate (P625, WGS84). Revision data is reproducible from `https://www.wikidata.org/wiki/Special:EntityData/QID.json?revision=REVISION`.
- Mainland exact identifiers: P442 (China administrative division code), removing spaces. Current catalog code must match exactly, including its province prefix, and its Chinese name must match a Chinese label/alias (only trailing 市 normalization). Taiwan's existing local IDs remain unchanged; an exact Chinese name plus a five-digit P5020 MOI municipality/county identifier is required. P2586 is not used.
- Dissolved administrative entities (P576) and deprecated claims are excluded; preferred claims take precedence. Entities with multiple different non-deprecated coordinates are excluded. No nearest-name or fuzzy matching is used.

## Rebuild and coverage

Run `python scripts/build_city_centers.py` offline. The builder preserves existing catalog and city IDs; it only generates `city-centers.json` and the explicit unmatched report.

The current 393 selectable cities have 383 verified map points; 10 unmatched cities remain in profile selection and population totals without a guessed marker. See `city-centers-unmatched.json` for the exact list. Centers represent administrative areas, not a person's precise location.

## Source retrieval recipe

1. Query `https://query.wikidata.org/sparql` for `?item wdt:P442 ?code; wdt:P625 ?coord`, retaining only exact selectable catalog codes after removing identifier spaces.
2. Query entities having P5020 identifiers of length five and P625 for the Taiwan city/county supplement.
3. Fetch selected entities with `action=wbgetentities`, `props=claims|labels|aliases|info`; freeze the relevant claims and `lastrevid` as above. Updating the snapshot requires reviewing the generated unmatched report and rerunning the geography checks.
