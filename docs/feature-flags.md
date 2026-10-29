# Per-account feature flags

Flag names belong in code; account targeting belongs in the database. There are
no public write endpoints. The private admin command uses the configured backend
database connection and requires database credentials. Never put real account
identifiers in source, migrations, test fixtures or committed command examples.

## Evaluation and clients

`feature_flags` stores a unique `key`, `description` and `default_enabled`.
`user_feature_flags` stores one boolean override per `(user_id, flag_key)`.
An override wins over the default, including an explicit `false`. Unknown flags
are disabled. Deleting a user or flag cascades its assignments.

The authenticated `GET /me/features` endpoint returns only that account's
evaluated `{key: boolean}` mapping. The same mapping is included as
`user.feature_flags` in Apple/Google sign-in responses and as `feature_flags`
in `GET /me` and AI-consent responses. Account responses do not expose other
users, assignments or email addresses. `GET /me` and `/me/features` use
`Cache-Control: private, no-store`.

iOS `UserInfo.isFeatureEnabled(key)` and Android
`AccountUser.isFeatureEnabled(key)` read the current user's flags. Missing flags
from older backends are disabled. The existing account lifecycle loads them on
sign-in and account refresh, keeps them in memory, and discards them on sign-out.
Clients can retain their last in-memory values during a connection failure; a
cold offline launch has no grants. UI changes become visible after a successful
account refresh; backend checks read the database on every operation.

Hiding controls is not access enforcement. Use
`feature_flags.require_enabled(session, user, key)` on restricted backend
operations. Keep paid entitlements and user consent checks separate from feature
visibility. Linking accounts preserves assignments; if both accounts have an
override, an explicit denial on either account wins.

## Administration

Run from `backend/` with the intended environment's database configured. These
examples use shell variables supplied at runtime; do not commit their values.

```sh
uv run python -m audioreader.admin list
uv run python -m audioreader.admin create new_reader --description 'Experimental reader'
uv run python -m audioreader.admin set-user new_reader on --user-id "$ACCOUNT_ID"
uv run python -m audioreader.admin set-user new_reader off --user-id "$ACCOUNT_ID"
uv run python -m audioreader.admin reset-user new_reader --user-id "$ACCOUNT_ID"
uv run python -m audioreader.admin show-user --user-id "$ACCOUNT_ID"
uv run python -m audioreader.admin set-default new_reader on
```

`set-default` affects all accounts without an override. `reset-user` removes an
override, so the account follows the default; use `set-user ... off` to deny
access regardless of the default. Creation starts disabled. Unknown keys,
missing accounts and duplicate creation fail without committing changes.

The account commands also accept `--email "$VERIFIED_EMAIL"` instead of
`--user-id`. Resolution uses verified linked Apple/Google identities, never
editable profile email, and refuses ambiguous matches. Prefer the stable account
ID once known. Commands print account IDs and evaluated values, not emails or
database credentials. Database failures roll back the transaction.

## Replacing the PDF allowlist

The migration creates `pdf_unlimited`, disabled by default, with no assignments.
`billing.unlimited` now checks this flag. It grants PDF importing without a paid
subscription or monthly page allowance. Operational PDF configuration, storage
limits and per-document limits still apply. Paid subscribers retain their
existing access without this flag; disabling it removes the unlimited exception,
not a valid paid entitlement. The billing sandbox email setting is separate and
unchanged.

`AUDIOREADER_PDF_IMPORT_EMAILS` is no longer read. No account receives a grant
automatically from an old email setting or a source-code default. Before directing
traffic to this backend version, apply the migration and explicitly assign any
previous unlimited accounts using the admin command:

```sh
uv run alembic upgrade head
uv run python -m audioreader.admin set-user pdf_unlimited on --email "$VERIFIED_EMAIL"
uv run python -m audioreader.admin show-user --email "$VERIFIED_EMAIL"
```

The additive migration and command can be run from the new release artifact
while the old backend still serves traffic. Configure the legacy environment's
allowlist during any rollback; database grants are not read by older releases.
Deployment and production assignments are deliberate operator actions, separate
from implementing this change. See [backend releases](backend-releases.md).
