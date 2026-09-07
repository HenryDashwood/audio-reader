# Backend releases

A push to `main` is a staging candidate. Production advances only when someone
runs **Promote backend to production** with the Railway deployment ID they tested.
Apple review and users installing an update are independent of backend releases:
every production change must continue to work with supported installed apps.

## Environments

| Environment | Address | Data and behaviour |
| --- | --- | --- |
| Local | `http://localhost:8000` | Existing `make backend-dev` workflow |
| Staging | `https://audio-reader-staging.up.railway.app` | Separate Postgres volume and backup bucket; test accounts |
| Production | `https://audio-reader-production.up.railway.app` | Real listeners and their library |

Railway project, service and environment IDs are recorded in `deploy/railway.json`.
Keep the production address stable: already-installed apps use it.

Staging requires ordinary Sign in with Apple. The development auth bypass stays
disabled. Its Apple revocation credentials and inbound newsletter integration are
blank, so deleting a staging account cannot revoke the app's production Apple
authorization and staging cannot receive production newsletters. Background polling
and Logfire reporting are disabled. The existing LLM vendor keys are shared for
interactive testing; their use still incurs vendor charges. Use dedicated staging
vendor keys if separate budgets become useful. No production database dump is used.

## Release a backend change

1. Open a PR. CI runs backend checks, current iOS tests, and the frozen released
   client's compatibility tests.
2. Merge to `main`. After all three checks pass, the CI staging job deploys that
   exact commit. It waits for Railway `SUCCESS`, verifies the reported commit and
   checks `/health` and that unauthenticated `/me` returns 401. The job summary
   includes the staging deployment ID.
3. Test staging with both the released app and the upcoming app. Check sign-in,
   library loading, listening/resuming, article reading, and voice commands.
   Keep production newsletter checks separate because staging email is disabled.
4. Open GitHub Actions → **Promote backend to production** → **Run workflow**.
   Select `main` and paste the tested staging deployment ID. It must still be
   a successful, running staging deployment. If staging has moved on, test the
   new candidate or restage the desired commit before promotion.
5. The workflow checks the deployment's project, service, environment and full
   commit SHA, verifies that it belongs to `main` and its latest main CI run
   succeeded with all four release jobs (including released-client compatibility and
   staging deployment), then deploys precisely that SHA to production. It never substitutes
   the latest branch head. Wait for the production job to finish successfully.
6. Submit/release the app when ready. Old app behaviour remains supported while
   Apple reviews it and after the new version becomes available.

Both Railway GitHub push triggers should be disabled; GitHub Actions owns deployment
ordering. Main CI runs and production promotions are serialized and are not cancelled
mid-deployment. PR validation can still cancel superseded runs. Direct Railway manual
deploys remain an emergency operator capability, outside the normal workflow.

## Test on an iPhone

`make ios-phone-staging` builds and installs the current app in Release and launches
it against staging. It uses the existing `HEARFUL_API_URL` override; no bundle ID,
signing, version, entitlement, or App Store configuration changes are needed.
The override is remembered between launches. Staging uses its own sign-in session;
a production session token does not authenticate against staging.

For a released source checkout, use the existing command with the staging address:

```sh
IOS_DEVICE_API_URL=https://audio-reader-staging.up.railway.app make ios-phone
```

Do this in a separate checkout at the release commit if testing an older release.
Install through the normal Release device workflow; never uninstall to switch servers.
The same bundle ID replaces the installed build, so a dedicated test phone is preferable.

To return to production, use Settings' existing server reset or run `make ios-phone`.
Sign in again if prompted. App Store and TestFlight builds still default to production;
this work does not silently redirect beta testers to staging. A remembered override
on a development phone can survive an app update, so clear it when finished testing.

## Compatibility policy

The initial automated baseline is **v1.4.1**, commit
`2a77d2798d47b51119fa8060bc2b93ded2e62ca3`. Earlier app releases are not yet certified
by this suite. A release tag identifies the source; it does not establish which
version is currently approved in the App Store.

- Add response fields and endpoints while preserving existing fields, types,
  paths, status codes and behaviour.
- New request fields must have defaults appropriate for clients that omit them.
- Gate new client actions on explicit capabilities, as with
  `supports_compound_actions`. An old client must not silently lose an action.
- For an incompatible redesign, serve a new endpoint/API version alongside the old
  one. Do not move the existing unversioned endpoints out from under installed apps.
- Keep compatibility until a deliberate support decision is made using app adoption
  evidence. Apple approval alone is never the retirement criterion.
- Use additive database migrations: add/backfill before switching reads, and remove
  old columns only in a later release after the rollback/support window closes.
  Old and new backend processes may overlap during deployment.

`make backend-compatibility` runs on macOS with Swift 6/Xcode. It sends frozen-release
requests to today's real FastAPI routes using mocks and in-memory SQLite, then feeds
those real HTTP responses through the unmodified v1.4.1 Swift HTTP client and decoder.
The harness also verifies that the old client's encoded requests match the backend
requests exercised. It covers library/episode loading, article text, search, playback
position, dismissal/restoration, play/speed commands, streamed question envelopes, speakable errors, newsletter
address/listing, consent, clearing Latest and unsubscribing.

The ordinary backend gate includes the server half and source checksum validation.
The macOS compatibility CI job includes the actual released Swift client. Device/UI
integration, Apple's live sign-in/revocation services, streaming transport timing and
external newsletter delivery still need their own tests; this is not a substitute
for testing the released app on a phone.

Do not edit or replace `compatibility/ios-v1.4.1/*.swift` to make a breaking change
pass. See `compatibility/README.md` for baseline maintenance.

## GitHub configuration

Create two GitHub environments, `backend-staging` and `backend-production`, each
restricted to the `main` branch. Each holds a secret named `RAILWAY_TOKEN`: a Railway
**project token scoped to that one environment**, not an account token. The staging
validation job never receives the production token. `GH_TOKEN` is the workflow's
ordinary short-lived GitHub token with read-only contents/actions permissions.

Repository workflows are effective only after these changes reach `main`. The initial
staging bootstrap can use the current committed backend while the workflow PR is being
reviewed. The promotion gate rejects a bootstrap whose commit has not passed the new
compatibility and staging CI jobs.

## Failures and recovery

A workflow reports success only for its own deployment ID, with the expected commit,
Railway `SUCCESS`, and passing HTTP smoke checks. A failed build, skipped deployment,
required Railway approval, timeout or API error fails the job. A network error after
submitting a deployment is ambiguous: inspect the printed deployment ID (or Railway
history if submission returned no ID) before retrying. The script never automatically
resubmits a deployment mutation or rolls back a database.

If a backend change breaks an installed app, restore the previous compatible backend
or ship a compatible backend fix immediately; do not wait for Apple approval. Check
database compatibility before rollback: the Docker startup command runs Alembic
migrations, and deploying old code does not undo applied migrations. Production PITR
is recovery tooling, not a routine rollback mechanism.
