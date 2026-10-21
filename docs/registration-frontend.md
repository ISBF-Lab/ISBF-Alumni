# Alumni registration frontend

The identity registration page preserves invite completion and presents an alumni option only when `site.isbf_alumni.registration_enabled === true`. The identity component uses the native `academy-alumni-registration` PluginOutlet, with the connector owned by ISBF-Alumni. It does not import the optional plugin module, so missing or disabled Alumni assets cannot prevent native login or student invitation boot. The plugin component independently verifies `/isbf/alumni/registration-config` before rendering the workflow.

Email verification, pending/rejected applications, evidence uploads and invite resending use the plugin endpoints. Applicant data, proof URLs and verification codes remain in component memory. Destroying the component aborts supported in-flight requests and clears private state. Browser storage is not used. The server must bind the HttpOnly challenge and recheck every operation.

The evidence picker accepts JPEG, PNG, WebP, HEIC and HEIF and rejects more than five files or sources larger than 10,000,000 bytes. Client extension checks are convenience validation; server magic-byte, conversion and private-access checks are authoritative. Only server-returned compressed proof URLs and byte counts are displayed. Existing submitted proofs are detached locally on editing, never deleted using the draft-proof deletion route.

China/Hong Kong/Macao cities use configured region city options; overseas cities use text. All geographical fields and biography are optional. Public visibility defaults to false. Biography is plain text and limited to 500 characters.

The native Reviewable card only renders serializer-authorized private application data. Approval and required rejection reasons remain native Reviewable actions; no separate frontend permission or moderation API is introduced. `review_alumni` is added to the existing developer-managed permissions page alongside peer `review_resumes` capability.

## Verification

Run `node scripts/check-registration-ui.mjs` for component logic coverage: email verification, country/region reset, visibility default, failed-submit retention, pending/rejected states, submitted-proof preservation and private-state cleanup. This test runs extracted class logic without rendering Ember; it does not prove browser behavior.

Prettier, Discourse ESLint and Stylelint should cover the new plugin components and stylesheet plus the touched identity component, permissions, locales and auth styles. Full native signup, review actions, protected proof access and layouts require integration tests and browser QA; no production applications or email messages are created by these checks.
