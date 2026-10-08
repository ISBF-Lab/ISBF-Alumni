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

## Deployment

Release only a merged Git commit. Place its tracked source under `/shared/isbf-alumni-releases/<commit>/isbf-alumni` with a matching `.release-commit` file, then use `deploy/install-plugin.sh <commit>` in the container's existing plugin hook. The installer accepts the expected symlink or creates it when the plugin path is absent; it refuses to replace another installation. Keep database, active theme and service configuration rollback points before enabling the plugin and updating the theme.

## Map assets

Map boundaries are generated from Natural Earth country and Admin 1 data. Natural Earth data is public domain. The published catalog and map show province-level regions only for China; other countries expose country names only. The source archive includes additional Admin 1 data, but those regions and city fields are not exposed by the plugin. The generated world and region GeoJSON is simplified and served by authenticated same-origin plugin routes.

Leaflet 1.9.4 is vendored locally under assets/vendor/leaflet under its BSD 2-Clause license. The map uses no external tile service.

To regenerate map data, run python scripts/build_geography.py. The script downloads the public source files to an ignored local assets/geography/source directory and writes only the minimized map/catalog files tracked by Git.
