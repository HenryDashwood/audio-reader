# Magpie Plus subscriptions

Magpie Plus provides **500 PDF pages per billing month, with no rollover**.
The configured UK monthly price is £3.99; the apps display the store
checkout price. See [PDF imports](pdf-imports.md) for document behaviour.

`AUDIOREADER_BILLING_ENABLED` defaults to false in source. Availability in a
deployed environment also depends on its configuration, public SDK keys, store
products and account eligibility. Verify those before describing sales as live;
this guide is not a record of current store approval or deployment status.

## RevenueCat and store configuration

Use the existing RevenueCat project **Magpie: Reading and Listening** (`a99a544f`).
Connect App Store app `com.henrydashwood.hearful` and Google Play app
`com.henrydashwood.magpie`; never ship a RevenueCat Test Store key.

The monthly subscription configuration is:

| Setting | Apple | Google Play |
| --- | --- | --- |
| Product | `magpie_plus_monthly` | `magpie_plus` |
| Base plan | Monthly subscription duration | `monthly`, auto-renewing, P1M |
| UK price | £3.99 including tax | £3.99 including tax |
| RevenueCat product identifier | `magpie_plus_monthly` | `magpie_plus:monthly` |

Use RevenueCat entitlement `magpie_plus` (`entl0c432ec4e8`) and offering
`magpie_plus` (`ofrng3ffb833eb8`), with a monthly package. Both store products
must be attached to the entitlement and monthly package.
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
- `pdf_unlimited`: a database feature flag granting unlimited pages without a
  purchase. Assign it with the [private admin command](feature-flags.md). The
  former `AUDIOREADER_PDF_IMPORT_EMAILS` setting is no longer read.
- `AUDIOREADER_BILLING_SANDBOX_EMAILS=[]` in production. Add only verified, explicitly
  approved test accounts when paid-allowance sandbox testing against production
  is necessary. The owner's unlimited exemption is independent of this list.

Configure one RevenueCat webhook per environment at `/billing/webhook`, with
its corresponding secret Authorization header. Staging receives sandbox events.
Production sandbox access is restricted to explicitly approved test accounts
through `AUDIOREADER_BILLING_SANDBOX_EMAILS`; ordinary production access requires
production purchases. Events refresh authoritative subscriber
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
7. Enable sales only after product configuration, store review and device purchase
   checks succeed. Follow the [mobile release guide](mobile-releases.md) for
   distribution and review submission.

### Apple sandbox device checks

Use separate sandbox payment testers for staging and production checks so a
receipt associated with one RevenueCat identity is not reused for another.
Follow Apple's [sandbox account instructions](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox)
for the installed distribution type. Verify the app's selected backend before
checkout; switch it through Settings and sign in again rather than uninstalling.

`SubscriptionRefundDeviceTests` is a manual Release-device suite, skipped by
default. For `requestSandboxRefund`, explicitly set
`HEARFUL_TEST_SANDBOX_REFUND=1` and
`HEARFUL_TEST_REFUND_ORIGINAL_TRANSACTION` to the verified tester's original
transaction ID. It requires an active sandbox purchase of the monthly product
and refuses real or mismatched purchases. Complete Apple's sheet on the phone,
then separately verify the RevenueCat refund event, webhook delivery, revoked
allowance and continued access to already prepared PDFs.

The read-only `sandboxReceiptIdentity` diagnostic uses
`HEARFUL_TEST_RECEIPT_DIAGNOSTICS=1`, `HEARFUL_TEST_EXPECTED_USER` and
`HEARFUL_TEST_STAGING_TRANSACTION`. It checks the production test session and
rejects the earlier staging receipt lineage. Keep the refund flag unset during
this diagnostic. Neither test runs in ordinary CI or ships in store builds.
