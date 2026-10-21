# Alumni registration and review

The public registration UI is supplied through the academy identity plugin's `academy-alumni-registration` outlet. The Alumni plugin owns its form, endpoints and private proof storage. Native Discourse still creates users, verifies invitation ownership and maintains sessions, groups, review history and mail delivery.

## Records and permissions

`isbf_alumni_applications` stores verified email, legal name, graduation year, optional public profile data, proof metadata, submissions and native Reviewable/Invite/User references. Legal identity is never imported into public profile fields. Native administrators can review; delegated moderators require `academy_moderators_review_alumni`. General content review, user editing and global email access do not confer this permission.

Anonymous application ownership uses the native signed session after a 15-minute email-code challenge. Codes are encrypted in expiring Redis data and are absent from HTTP responses and job arguments. Owner sessions expire after 24 hours and may be regained by verifying the same email. Five incorrect attempts invalidate a challenge. Account creation waits for approval; existing accounts cannot enter this signup flow.

Challenge verification and consumption run under the same distributed lock, so parallel requests cannot consume a code twice. The review query scope excludes alumni applications without the dedicated permission, and the native review type selector omits this type for those users. Application, proof and action endpoints independently enforce their permissions. Review payloads resolve country, province and city names without changing the stored identifiers.

Approved email-bound invites expire after seven days and have one redemption. Reissuing invalidates the prior invite; delivery retry keeps the current invite. The academy plugin must recognize the approved Alumni binding, including in its invitation cleanup task. Closing new applications retains the compatibility required to redeem already approved invitations.

## Private proof processing

JPEG, PNG, WebP and HEIC/HEIF sources are checked by magic bytes before native sandboxed ImageMagick decoding. Sources are limited to 10,000,000 bytes and 40 million decoded pixels. Orientation is applied; metadata is removed and images are converted to JPEG. Bounded quality/size attempts must produce at most 1,000,000 bytes within a 30-second budget. Original temporary files are removed even when processing fails.

Only normalized JPEGs persist under `/shared/isbf-alumni-private`, with directory mode 0700 and file mode 0600. Files are never public uploads. Downloads require an owning verified session, the registered owner or a currently authorized reviewer. Five unbound proofs and 25 retained proof records per application limit replacement abuse; previously submitted proofs remain private and cannot be deleted through the applicant form. The configurable total storage cap defaults to 1024 MiB. No automated removal of submitted evidence is scheduled.

## Endpoints

`GET /isbf/alumni/registration-config` provides public geography and limits. `/applications/email`, `/applications/verify-email`, `/applications/current`, `/applications` and `/applications/resend` handle the anonymous verified application lifecycle. `/application-proofs` handles private uploads; `/application-proofs/:id` supports authorized reads and deletion of unsubmitted proofs. Native Reviewable endpoints handle approval and rejection, including the native required-reason dialog and version conflict checks.

## Release and recovery

Keep registration disabled until both compatible plugins, compiled public scripts and production asset manifest have been released and verified. Back up the database, private evidence, installed versions and active theme before applying the migration. Theme fields are patched with source-hash checks. Never roll back by dropping the application table or removing evidence; close new applications and retain the compatible invitation/read/review implementation.

Joint CI checks out a pinned ISBFweb commit through a dedicated read-only key stored only in ISBF-Alumni Actions Secret. No identity dependency snapshot is committed here. The suite runs actual native invitation redemption and proof conversion, including native HEIC fixtures. Local VM checks, formatters and linters do not replace browser, real-email or iPhone validation.
