# Magpie Plus subscriptions

The first paid feature is PDF importing: **£3.99 per month, 500 pages per billing
month, no rollover**. Apple and Google provide the localized checkout price.
This change does not publish a subscription or enable sales automatically.
`AUDIOREADER_BILLING_ENABLED` defaults to false until the store configuration and purchase
checks below are complete. Do not advertise PDF importing in release notes yet.

## RevenueCat and store configuration

Use the existing RevenueCat project **Magpie: Reading and Listening** (`a99a544f`).
Connect App Store app `com.henrydashwood.hearful` and Google Play app
`com.henrydashwood.magpie`; never ship a RevenueCat Test Store key.

Create one auto-renewing monthly subscription in each store:

| Setting | Apple | Google Play |
| --- | --- | --- |
| Product | `magpie_plus_monthly` | `magpie_plus` |
| Base plan | Monthly subscription duration | `monthly`, auto-renewing, P1M |
| UK price | £3.99 including tax | £3.99 including tax |
| RevenueCat product identifier | `magpie_plus_monthly` | `magpie_plus:monthly` |

RevenueCat entitlement `magpie_plus` (`entl0c432ec4e8`) and offering `magpie_plus`
(`ofrng3ffb833eb8`) have been created, with a monthly package. Attach both
store products to the entitlement and monthly package after connecting the stores.
Do not add trials, introductory prices or annual packages without updating the
allowance policy. Both apps select this exact offering's monthly package.
Use RevenueCat's **Keep with original App User ID** restore behaviour to avoid
moving a paid entitlement between unrelated Magpie accounts. Users should sign
in to their existing Magpie account, or connect Apple and Google identities in
Magpie Settings, to share a subscription across platforms.

The App Store connection requires an In-App Purchase key. Google Play requires
service-account credentials scoped to the app's purchase/subscription APIs.
Store financial agreements, tax/bank setup, product review and Google Play base
plan activation must be completed by the account holder. RevenueCat SDK setup
alone cannot make the products available for purchase.

### Setup status (27 October 2026)

- Apple app connection `app4085822f6f` has validated In-App Purchase credentials.
  Subscription group `22517313` contains draft subscription `6827365515`
  (`magpie_plus_monthly`): one month, £3.99 UK price, English (U.K.) name
  **Magpie Plus**, and description **Import 500 PDF pages each month to read and listen.**
  Availability is configured for all 175 territories with Apple-derived local
  prices. Family Sharing and multiseat purchasing are off. Nothing has been
  submitted for review; the first subscription needs a new app version and a
  review screenshot. Draft review notes explain the Settings > Magpie Plus
  purchase/restore flow and the page allowance.
- RevenueCat Apple product `prodc56f19ad5b` is attached to `magpie_plus` and its
  `$rc_monthly` package. **Keep with original App User ID** is saved and verified.
  The optional App Store Connect API connection is not configured, so automated
  product import/status lookup is unavailable; the product was registered manually.
- Apple production and sandbox notification URLs both point to RevenueCat's
  app-specific receiver, saved with the owner's approval and verified after a
  page reload. Delivery itself still needs a sandbox transaction. Leave **Track new purchases from server-to-server
  notifications** off because the app uses non-UUID RevenueCat identities and
  **Keep with original App User ID**. See RevenueCat's
  [notification guidance](https://www.revenuecat.com/docs/platform-resources/server-notifications/apple-server-notifications).
- Google connection `appae62406bc8` can read the product and subscription catalogs,
  but purchase validation still needs attention. The service account has app
  access and the financial/orders permissions in Play Console. Play Console also
  merchant payment profile has been completed by the owner; bank verification is
  awaiting Google's small deposit. No Google product or base plan has been created yet.
- Apple Business lists the Paid Apps Agreement, bank account, and both required
  U.S. tax forms as **Active**, verified after the owner completed the setup.
  App-level EU trader status currently says non-trader; the owner should review
  that declaration before launching paid subscriptions. The subscription currently
  inherits the parent app's tax category.
- The existing public Apple/Google SDK keys have been saved to the ignored local
  file `build/magpie-plus/revenuecat-config.env`, with billing disabled. Live API
  smoke checks using `magpie_setup_connection_check_20261027` succeeded for both
  keys. Apple's offering returns `$rc_monthly` / `magpie_plus_monthly`; Google's
  package list is empty until its product is configured. This verifies connection
  and catalog configuration, not a purchase or paid entitlement.
- Staging has the RevenueCat configuration and a dedicated webhook authorization
  secret. Its webhook `whintgr4663f9506b` sends sandbox events only to
  `https://audio-reader-staging.up.railway.app/billing/webhook`. The owner's
  verified email remains the sole unlimited account. Production is unchanged.
  PR #26 passed backend, released-client compatibility, Android, iOS 26 and iOS 27
  checks and merged as `97415491739bd9ba0ce1eeddd2ddb3ea271c321c`. Main CI run
  `40496773569` passed and deployed staging as
  `1103d0a9-7d67-445e-ac6d-e076a2a17c28`. The billing migration and startup succeeded.
  Health/sign-in checks, webhook authentication, duplicate delivery and malformed
  event rejection passed against the live deployment. RevenueCat's dashboard
  test event returned HTTP 200 with `{"received":true}`.
- Apple sandbox initial purchase passed on the physical iPhone on 27 October:
  RevenueCat event `075c7f07-a7d9-4d38-8a90-29527eff68d5` records
  `magpie_plus_monthly`, offering/entitlement `magpie_plus`, country `GB`, currency
  `GBP`, and a purchased price of `3.99`. Its staging webhook received HTTP 200.
  The owner confirmed the ordinary reviewer account displayed **500 pages
  remaining**. The app initially displayed a dollar price, but the verified
  purchase used GBP; RevenueCat documents this
  [Apple sandbox metadata inconsistency](https://www.revenuecat.com/docs/test-and-launch/sandbox/apple-app-store).
  Do not hardcode GBP over StoreKit's localized price.
- The same Apple sandbox subscription renewed from 11:53:36–11:58:36 UTC to
  11:58:36–12:03:36 UTC. RevenueCat's API confirmed the new active period with
  no refund, cancellation or billing issue. Restore initially reported no active
  subscription near that boundary; after the renewal was visible, the owner
  confirmed both Refresh and Restore succeeded with 500 pages. Investigation of
  renewal event `b91e3839-94a2-4421-a3a3-bf385cd244e2` found Apple delivered it at
  11:57:44 UTC with a future purchase date of 11:58:36 UTC. The old validation
  rejected that future period and cleared the still-valid current subscription.
  The regression fix preserves only already verified access and its current page
  usage until the new period begins; it neither grants future access nor resets
  pages early. Refunds, missing/expired entitlements, unauthorized production
  sandbox purchases and genuine gaps in access still fail closed. Regression
  coverage exercises webhook delivery, duplicate delivery, restore, and rollover
  with a nonzero page debit. Subsequent live checks below cover allowance reset
  and cancellation; refund and Google purchase checks remain outstanding.
- Follow-up cancellation coverage verifies that cancelling auto-renew preserves
  a consumed page and access until the verified expiry. Repeated restore and
  duplicate saves do not reset that balance. After expiry, the next access check
  blocks new imports even without an expiry webhook, while the saved reader text
  and original PDF remain accessible. The full backend gate passes (1,276 backend
  tests and 188 repository-script tests). This is automated coverage with mocked
  store/provider responses; it is separate from the live checks below.
- Live allowance testing exposed Safari hiding Magpie when sharing the one-page
  W3C dummy PDF. iOS logs showed two extension items: the PDF/file URL and its
  source webpage/URL. The previous activation rule rejected that combination.
  Declaring a maximum of two attachments, while retaining the existing file and
  webpage limits, made Magpie visible for the identical payload in the iOS 27
  simulator. The corrected Release build was installed and launched on the
  physical iPhone against staging. The owner confirmed the PDF saved and the
  ordinary reviewer account displayed **499 pages remaining**. Staging recorded
  exactly one used page for ready document `3d763ce5-b40a-44fd-9e71-eaedb5c3f3b6`
  (episode `10155`), imported at 12:48:44 UTC during the 12:45:14–12:50:14 period.
  Both iOS 27 and iOS 26.5 suites passed 707 tests with one skipped and no
  compiler warnings; the simulator and physical Release builds also passed.
- The second phone save reached subscription expiry rather than proving duplicate
  saving while active. RevenueCat recorded billing issue
  `4f287ef4-f79c-45b7-9095-61365de8b792` and expiry
  `aee74896-7d60-4f3a-b085-c30a0167097c` at 12:50 UTC. The receipt reported
  `billing_issues_detected_at=2026-10-27T12:50:18Z`, with no cancellation or refund.
  Staging blocked the new import and retained one document/one page debit. The
  owner confirmed sandbox purchases/renewals were already enabled. This expired
  period is not evidence of an allowance reset or cancellation test.
- Apple subsequently recorded renewal `14cd5628-49bd-4d81-b025-01ee601a913f`
  for 12:54:21–12:59:21 UTC. Both the phone and staging showed a fresh 500-page
  allowance, with the previous one-page debit retained in its original period.
  Sharing the same PDF again left 500 pages, confirmed on the phone; staging
  retained exactly one ready document and one used-page ledger entry.
- Cancellation `ce7e90cd-8f41-46e1-87a5-87a98dd77d18` arrived at 12:54:36 UTC
  with reason `UNSUBSCRIBE`; its staging webhook returned HTTP 200. RevenueCat
  and staging retained access until 12:59:21. At 12:59:25 the receipt and staging
  both showed expired access, with the saved PDF and debit unchanged. The owner
  confirmed that Refresh offered Subscribe again and the saved PDF still opened
  on the physical iPhone after expiry.
  The iOS allowance date now says **Current period ends** instead of **Renews**,
  because a verified active period does not imply auto-renew is still enabled.
- A development-signed Release build is installed on the owner's iPhone and
  launched against staging. Use **Sign in with Google** with the reviewer Gmail
  account for the ordinary Magpie account. Separately sign into the Apple sandbox
  tester in **Settings > Developer > Sandbox Apple Account**; this account handles
  the test payment and is not a Magpie sign-in method. Leave the normal iCloud
  account signed in. The owner account hides checkout because it is unlimited.
  Apple lists the owner's dedicated UK sandbox tester; its password is separate
  from the reviewer Google account password.

## Backend configuration

### iOS production preparation (27 October 2026)

- Promoted verified staging deployment `262d3a2a-20d2-4ebb-9e36-839790345de7`
  through production workflow `40528958637`. Production deployment
  `96436437-bea4-409f-8257-04a7fcff4453` reached `SUCCESS` at commit
  `4d3d858dc89f9483a4c13558fc6c344bab16921e`. Runtime settings were checked
  inside that deployment; health returned 200 and unauthenticated account and
  billing requests returned 401.
- Production billing is enabled for Apple with a 500-page monthly allowance.
  The Google SDK key is empty and the accepted product list contains only
  `magpie_plus_monthly`. The Android client cannot configure Google checkout
  without its key. Do not populate it or add Google's product until Google
  configuration and purchase testing are complete.
- At that deployment, the legacy verified-email allowlist granted unlimited
  access to one account. Current code replaces that allowlist with
  `pdf_unlimited`; see [feature flags](feature-flags.md) for transition steps.
  `magpiereview0@gmail.com` is the only production sandbox exception, verified
  against its linked Google identity; it is not unlimited. A profile email alone
  cannot grant either exception.
- RevenueCat webhook `whintgra6c6bd41e2` sends Apple events to production using
  its separate authorization secret. Both real and sandbox Apple events are
  delivered so the approved review account can test renewal/refund delivery.
  Customer IDs are environment-prefixed: staging identities have no production
  owner and are ignored. This does not allow other production accounts to spend
  sandbox entitlements. Google's app is excluded from this webhook.
  RevenueCat test event `47C74CF0-C42C-4DC3-A9C5-4D3620BA530F` received HTTP 200;
  missing authorization returned 401 and malformed authenticated events 422.
- Production `/privacy` and `/terms` are live; the privacy page includes
  RevenueCat. Public release notes are unchanged and do not advertise PDFs.
- Additional regressions exercise real PDF uploads totalling exactly 500 pages,
  rejection before provider submission, duplicate saves at zero balance, refund
  webhook delivery and restore, preserved saved content after a refund, and the
  production owner/reviewer/Apple-only configuration. `make backend-check`
  passed 1,280 backend and 188 repository-script tests. These use mocked store
  and conversion services; they do not prove a live Apple refund.
- Internal TestFlight workflow `40528972580` succeeded for version 1.6.5 (332)
  from the promoted commit. Apple marked build
  `d0cb2cc9-58b7-4ef6-a136-22cb1eb77128` `VALID` at 15:26 UTC and App Store
  Connect shows it in the Internal group with two testers. It was not submitted
  to external beta review or App Review. Its public test notes do not mention
  PDFs or subscriptions. Device purchase/refund verification against production
  remains separate from upload and Apple processing.
- The owner completed the production TestFlight purchase and confirmed **500
  pages remaining**. At 15:45 UTC, the production database and RevenueCat agreed
  on the reviewer customer's Apple sandbox period, 15:44:53–15:49:53 UTC.
  Initial purchase event `bc2a2505-057c-40ac-a93d-6d6201bc0732` recorded country
  `GB`, currency `GBP`, price `3.99`, and received HTTP 200 from the production
  webhook. The reviewer is not unlimited; the owner-only exemption and empty
  Google SDK key were verified again.
- The owner confirmed Restore succeeded with 500 pages, the one-page Safari
  share reduced the balance to 499, and sharing it again retained 499. At
  15:49:40 UTC, production contained exactly one ready document
  `9d65e5a0-137a-4b36-acdf-c5dd39e845ff` (episode `161128`) and one used-page
  entry, charged to the 15:44:53–15:49:53 period. RevenueCat had already supplied
  the future 15:49:53–15:54:53 renewal; the backend correctly retained the
  current period until its boundary. Renewal event
  `76f24fb3-69c4-42a8-ae97-bc5480d50b1b` received HTTP 200.
- The owner cancelled the production test subscription and confirmed access
  remained available. Cancellation event `41284b60-5749-488e-b9c3-00a88d97176d`
  recorded `UNSUBSCRIBE` at 15:53:17 UTC and received HTTP 200. At 15:53:55,
  RevenueCat and production retained access until 15:54:53, with the ready PDF
  and its single page debit unchanged. Expiration event
  `d69f3e8c-cffd-4174-9f4f-c1d3b9cb2d4d` subsequently recorded `UNSUBSCRIBE`
  and received HTTP 200 at 15:55 UTC. A 15:55:20 read confirmed expired access
  in both the receipt and production record, with the ready document and single
  used-page ledger entry retained. Post-expiry phone checks and the live refund
  test remain in progress.
- The subsequent attempt to resubscribe in TestFlight at about 15:57 UTC
  displayed RevenueCat's invalid-receipt error: the purchased product was
  missing from the receipt. A 15:58:10 read still showed only the expired
  subscription, with no new purchase or refund. The app resolves RevenueCat
  5.91.0 and uses its default StoreKit 2 path; do not prescribe a StoreKit 2
  migration as a fix. The owner was asked to refresh the existing sandbox
  tester's sign-in, restore, and retry once. Resubscription and live refund
  verification are blocked until a valid new purchase is observed. No purchase
  history was cleared, entitlement granted manually, or access policy relaxed.
- After refreshing the sandbox login, **Restore purchases** reported another
  subscriber using the receipt; the owner confirmed it was the restore action,
  not a new Subscribe attempt. At 16:09 UTC, the production customer still had
  only its original expired purchase and no aliases/transfers. The dashboard's
  earlier staging customer also had expired access. The conflicting transaction
  is not identified by this error; do not claim its owner is proven or that it
  represents an active charge. A direct Subscribe retry after the refreshed
  Apple login is pending, with the original restore policy unchanged.
- The direct retry also failed. A Release device diagnostic at 16:20 UTC
  confirmed Magpie's session is the production reviewer, while StoreKit's
  verified transaction history contains the **staging** original transaction
  `2000001257928722`, including a new transaction `2000001258048028` from
  16:14:03 and its renewal. The successful production purchase instead used
  original transaction `2000001258037020`. This identifies the conflicting
  receipt lineage; the tester shown in Settings still needs to be checked to
  distinguish a wrong login from stale Apple purchase history. Do not transfer
  the staging receipt or grant production access to work around it.
  The development diagnostic build now replaces TestFlight on the connected
  phone without uninstalling it. The diagnostic intentionally failed its
  assertion rejecting the known staging receipt; the refund test was skipped.
  Compilation had no warnings. Physical tests require the existing development
  team override (`DEVELOPMENT_TEAM=67F2439F4X`) and `ENABLE_TESTABILITY=YES`.
  Select the full `HearfulTests/SubscriptionRefundDeviceTests` suite: selecting
  the bare Swift method name ran zero tests despite a successful build.
- The owner confirmed Settings was signed into the original
  `magpiereview0@gmail.com` sandbox tester, then switched it to
  `magpiereview0+production@gmail.com`. The same physical-device diagnostic
  passed at 16:25 UTC (one passed, refund skipped, no warnings). StoreKit now
  returned only the two known production transactions, original ID
  `2000001258037020`, and no staging receipt. No transfer-policy change or
  purchase-history deletion was needed.
- After that correction, the owner confirmed a new purchase succeeded and
  displayed 500 pages. Production and RevenueCat independently confirmed the
  new sandbox period 16:26:31–16:31:31 UTC, with no cancellation, refund or
  billing issue. The earlier saved PDF and its single ledger entry remain
  intact. The live refund test is now running against that active purchase;
  opening/submitting Apple's sheet is not yet proof of delivered revocation.
- The guarded physical-device refund test returned Apple's `.success` on
  submission (one passed, diagnostic skipped, no compiler warnings). The test
  runner then closed the host app; the owner perceived this as a possible crash,
  but the test session completed successfully. At 16:29 UTC, RevenueCat event
  `03e20606-8956-41a2-8651-28a717ba453e` recorded only `CANCELLATION` /
  `UNSUBSCRIBE`, delivered to production with HTTP 200. `refunded_at` was null.
  A fresh on-device read at 16:30 still showed transaction `2000001258052861`
  with `revocationDate=nil`. Refund submission passed; refund approval and
  revocation delivery have **not** yet passed. Do not count cancellation as a
  successful refund check.
- The app was relaunched normally after the test runner exited. The owner
  confirmed Refresh offers Subscribe again and the existing dummy PDF remains
  readable after the 16:31:31 expiry. This verifies post-expiry behaviour on the
  phone, but does not substitute for a refund/revocation event.
- At 16:34:04 UTC, RevenueCat still reported `refunded_at=null`. Expiration
  event `5811316d-df3b-4fca-a652-423e1fabcaf8` received HTTP 200 but had reason
  `UNKNOWN`, not a refund signal. Live refund approval/delivery remains an open
  release verification item. The owner-only unlimited exemption and disabled
  Google checkout were verified unchanged in that read.
- Follow-up at 16:47:26 UTC confirmed the refund: RevenueCat records
  `refunded_at=2026-10-27T16:38:03Z`. Event
  `18bf96d8-a76b-436c-b03d-84f7bc72b370` is `CANCELLATION` with
  `cancel_reason=CUSTOMER_SUPPORT`, transaction `2000001258052861`, and
  GBP -3.99; production acknowledged it with HTTP 200. The production customer
  has no active entitlement, while the ready PDF and single page debit remain.
  This verifies refund approval/delivery after expiry, not immediate revocation
  of a still-active period. Owner-only unlimited access and disabled Google
  checkout were reverified unchanged.
- App Store version 1.6.5 is a saved draft with build 332 and manual release.
  Public release notes remain neutral. Dedicated reviewer login and private
  subscription instructions are saved; the owner entered the password directly
  in App Store Connect. Purchase History was added to the published privacy
  label for App Functionality, linked to identity, not tracking.

For production test purchases, use a separate Apple sandbox tester from staging.
RevenueCat's **Keep with original App User ID** also applies to new purchases
on a receipt already associated with another identity. The Gmail alias
`magpiereview0+production@gmail.com` uses the existing inbox and does not require
another Google account. The Magpie Google sign-in remains
`magpiereview0@gmail.com`; only the Apple test-payment login changes.
For TestFlight, signing into Developer's Sandbox Apple Account alone is not
enough while the normal Media & Purchases account remains signed in. After
installing the build, sign out of **Media & Purchases only**, retain the normal
iCloud login, and sign into the dedicated tester under **Settings > Developer >
Sandbox Apple Account**. This corrected the owner's normal-account checkout
prompt and enabled the verified test purchase. See
[Apple's TestFlight account instructions](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox).
The development phone can retain its staging-server override across an update:
use **Settings > Use the normal server** before the production TestFlight check,
then sign in again as needed. Never uninstall the app to switch environments.

The manual device test
`HearfulTests/SubscriptionRefundDeviceTests/requestSandboxRefund` presents Apple's
refund sheet only when `HEARFUL_TEST_SANDBOX_REFUND=1` is explicitly passed to the
test runner, together with `HEARFUL_TEST_REFUND_ORIGINAL_TRANSACTION` matching
the freshly verified production tester's original transaction ID. It requires
an active Apple-verified sandbox transaction for the exact monthly product and
refuses real purchases or another tester's receipt. It compiles on iOS 26.5 and 27 and
is skipped by default; test bundles do not ship in TestFlight/App Store builds.
Use a Release device test and complete the sheet on the phone. A successful
request still requires verification of Apple's refund event, RevenueCat delivery,
and the backend's revoked access with preserved saved PDFs.

The same suite has an opt-in read-only receipt diagnostic,
`sandboxReceiptIdentity`, enabled by `HEARFUL_TEST_RECEIPT_DIAGNOSTICS=1` with
`HEARFUL_TEST_EXPECTED_USER` and `HEARFUL_TEST_STAGING_TRANSACTION`. It checks
the current production session and rejects the known staging receipt lineage.
It logs only transaction IDs/dates, never receipt signatures, tokens or keys.
Keep the refund flag unset when running this diagnostic.

Before App Review, supply the subscription review screenshot, attach the first
subscription/group to the version submission, and have the owner review the
trader declaration (currently non-trader). The draft has not been submitted.
Do not broaden sandbox access or declare review/release complete merely because
the production backend is running.

Set separately for staging and production using the normal secret-management
workflow; never commit secret values:

- `AUDIOREADER_BILLING_ENABLED=true` in staging for sandbox testing; enable in
  production only once store setup and purchase checks pass.
- `AUDIOREADER_REVENUECAT_API_KEY`: a RevenueCat API v1-compatible key from the
  same project. The existing public Apple SDK key is sufficient for the backend's
  `GET /subscribers/{id}` call (verified against the live API). It returns customer
  subscription state across the project; the backend does not need subscriber
  attributes or privileged grant/delete operations. An unrestricted secret key
  is therefore unnecessary for this implementation. Never accept a key from the client.
- `AUDIOREADER_REVENUECAT_WEBHOOK_SECRET`: a long random Authorization header value.
- `AUDIOREADER_REVENUECAT_APPLE_SDK_KEY`: public `appl_…` key.
- `AUDIOREADER_REVENUECAT_GOOGLE_SDK_KEY`: public `goog_…` key.
- `AUDIOREADER_REVENUECAT_ENTITLEMENT=magpie_plus` and `AUDIOREADER_REVENUECAT_OFFERING=magpie_plus`.
- `AUDIOREADER_REVENUECAT_PRODUCTS=["magpie_plus_monthly","magpie_plus:monthly"]`.
- `AUDIOREADER_PLUS_MONTHLY_PAGES=500`.
- `pdf_unlimited`: a database feature flag granting unlimited pages without a
  purchase. Assign it with the [private admin command](feature-flags.md). The
  former `AUDIOREADER_PDF_IMPORT_EMAILS` setting is no longer read.
- `AUDIOREADER_BILLING_SANDBOX_EMAILS=[]` in production. Add only verified, explicitly
  approved test accounts when paid-allowance sandbox testing against production
  is necessary. The owner's unlimited exemption is independent of this list.

Configure one RevenueCat webhook per environment at `/billing/webhook`, with
its corresponding secret Authorization header. Staging receives sandbox events;
production receives Apple production and sandbox events for the restricted
reviewer checks described above. Events refresh authoritative subscriber
state, rather than trusting the event's entitlement payload. Unknown/deleted
identities are ignored. Duplicate or out-of-order delivery is safe. Reconciliation
also occurs on purchase/restore and on access checks after a five-minute cache.
If a provider request fails, new paid conversion access fails closed.

The backend supplies public SDK keys and opaque account IDs to the apps. IDs are
namespaced by environment. Neither client sends the backend an entitlement claim
that can grant access. Store SDK purchase and restore operations are serialized
with identity changes, and responses are ignored after the Magpie session changes.

## Allowances and documents

The backend uses RevenueCat's verified monthly purchase and expiry dates, not a
calendar month or the device clock. Access may continue through a store billing
grace period without resetting the page balance. Refunded, revoked, expired,
wrong-product and unauthorized production sandbox purchases grant no new access.

An account-row lock serializes new reservations with imports, restores and account
merges. A durable ledger reserves the PDF's actual page count before submission.
For paid URL imports, Magpie downloads a bounded file from a validated public URL,
counts it, and sends those exact bytes to Datalab. Signed source URLs never go to
RevenueCat. Reading/downloading an existing document needs no subscription.

Duplicate saves and retries use the same document debit. A provider-confirmed
failed conversion releases the reservation; retrying it reserves again. Uncertain
submissions keep their reservation until resolved, to avoid unbounded duplicate
conversion spend. Successful document deletion does not refund pages. Account
deletion removes local subscription and usage records, but does not cancel a
store subscription. Both apps explain this in the deletion confirmation.

Account merges preserve all RevenueCat identities and all page usage. They do
not manufacture a second 500-page allowance. Store purchases remain managed in
the store where they originated. Privacy disclosures explain RevenueCat's role;
`/terms` describes renewals, page usage, cancellation and document handling.
Review these disclosures and update store privacy/data-safety answers before launch.

## Verification and launch

1. Run `make backend-check`, `make backend-compatibility`, `make ios-build`,
   `make ios-test`, `make ios-test-compatibility`, `make android-check` and
   `make android-test` on an emulator.
2. On an ordinary (non-exempt) staging account, buy through Apple sandbox and
   a Google Play license tester installation, then verify purchase, restore,
   cancellation, renewal, refund, grace period and expired access.
3. Check the same Magpie account on the other platform receives the same balance.
   Check account switching during checkout never grants access to the new account.
4. Import across the 500-page boundary, verify the over-limit PDF never reaches
   Datalab, then verify a renewal resets to 500 without rollover. Verify the
   unlimited owner account never consumes pages.
5. Close the app during conversion and reopen: saving is acknowledged immediately;
   downloading/preparation remains distinct from purchase/allowance verification.
6. Use the documented backend release pipeline and internal store tracks first.
   Google Play billing needs the production application ID and a Play-installed
   build; the `.dev` emulator build cannot prove real Google Play checkout.
7. Only enable sales after product configuration, store review and device purchase
   checks succeed. Keep the feature out of release notes until explicitly requested.
