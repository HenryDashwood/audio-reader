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
  both showed expired access, with the saved PDF and debit unchanged. Final
  phone confirmation of the expired paywall and continued reader access is pending.
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
- `AUDIOREADER_PDF_IMPORT_EMAILS=["hcndashwood@gmail.com"]`: verified Apple/Google identity
  emails only. This account has unlimited pages even without a purchase.
- `AUDIOREADER_BILLING_SANDBOX_EMAILS=[]` in production. Add only verified, explicitly
  approved test accounts when paid-allowance sandbox testing against production
  is necessary. The owner's unlimited exemption is independent of this list.

Configure one RevenueCat webhook per environment at `/billing/webhook`, with
its corresponding secret Authorization header. Filter sandbox events to staging
and production events to production. Events refresh authoritative subscriber
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
