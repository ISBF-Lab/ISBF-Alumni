# Alumni plugin development

Use the application's shared UI kit for dropdowns. Form selections use FormKit
or `discourse/ui-kit/d-select`; searchable selections retain the existing
SelectKit adapters. Action menus use DMenu, DDropdownMenu and DButton.

The active site theme owns menu colors, spacing, rounded panels and motion.
Do not add visible native selects or private menu frames and animations.
Menus remain anchored to their trigger on mobile. Preserve values, dependent
location resets, disabled states, validation and native form events.

Follow the application's [dropdown contract](https://github.com/ISBF-Lab/ISBFweb/blob/main/docs/design-system/dropdowns.md).
Run the plugin checks and `pnpm lint:menus` in the checked-out application with
this plugin installed. The registration integration workflow pins the required
core revision and enforces this policy.

Write pull request titles and descriptions in English.
