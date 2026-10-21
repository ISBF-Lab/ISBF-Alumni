# City catalog provenance

Mainland source: modood/Administrative-divisions-of-China, `dist/pca-code.json`, commit `c49d495b40ac73eb1a66f6eeae5f8fd10696f035`.

Source URL: https://github.com/modood/Administrative-divisions-of-China/blob/c49d495b40ac73eb1a66f6eeae5f8fd10696f035/dist/pca-code.json

WTFPL version 2 license is retained in `cities-LICENSE.txt`. The source SHA-256 is `83b7536f853ad16beb4d37b92890a3fd7bb9d33d4f37e7c8885fb948749a9bc4`.

The bundled catalog maps mainland province numeric IDs to existing ISBF province IDs without changing stored province associations. Province-administered county-level entries are promoted from their administrative grouping so a user can select their actual location. Municipalities have one city option using the existing province display name.

The upstream dataset excludes Taiwan, Hong Kong and Macau. These are explicit local compatibility supplements: Taiwan's 22 municipality/city/county selections use stable `TW-*` IDs; Hong Kong and Macau each retain a single option matching the existing region ID/name. These supplement names are maintained separately from the upstream data and do not add city-level map geometry.

Taiwan supplement verified against the published local-government directory on 2026-10-21: https://www.president.gov.tw/Page/106 and government directory https://www.gov.tw/News_Content_37_764076. Display names are normalized to Simplified Chinese; local identifiers are ISBF-owned, not official administrative codes.
