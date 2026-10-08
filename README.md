# ISBF Alumni

An independent Discourse plugin that adds an authenticated alumni directory to ISBF Campus Feed.

## Native Discourse setup

1. Install the plugin from this repository and enable the site setting isbf_alumni_enabled.
2. Create a native group with slug alumni and display name 校友. Keep its permissions at the site's normal-user level.
3. Add alumni to that group through Discourse Admin. This plugin never creates the group or changes its permissions.
4. Group members can manage their own profile. Directory profiles are private by default and appear only after the member opts in.
5. All signed-in users may view the directory. Guests are sent through Discourse login.

If the group does not exist or the site setting is disabled, the plugin omits the enabled capability from Site and the theme does not expose the feature.

## Data and privacy

Profile fields are stored in native UserCustomField records. They are not registered as public user fields. The directory endpoint returns only fields for active, approved members who opted in. Profile updates can only target the signed-in member.

The plugin uses the native Group and GroupUser membership model, Discourse sessions and CSRF handling, and adds no database tables or Core patches.

## Map assets

Map boundaries are generated from Natural Earth country and Admin 1 data. Natural Earth data is public domain. The Admin 1 source is queried from the Natural Earth Quick Start ArcGIS service and filtered to China, the United States, Canada, the United Kingdom, Australia, Japan, Germany, and France. The generated world and region GeoJSON is simplified and served by authenticated same-origin plugin routes.

Leaflet 1.9.4 is vendored locally under assets/vendor/leaflet under its BSD 2-Clause license. The map uses no external tile service.

To regenerate map data, run python scripts/build_geography.py. The script downloads the public source files to an ignored local assets/geography/source directory and writes only the minimized map/catalog files tracked by Git.