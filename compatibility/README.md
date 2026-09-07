# Released iOS client compatibility

`ios-v1.4.1/` contains byte-for-byte copies from release commit
`2a77d2798d47b51119fa8060bc2b93ded2e62ca3`:

- `ios/Hearful/API/APIModels.swift`
- `ios/Hearful/API/HearfulAPI.swift`
- `ios/Hearful/Voice/Conversation.swift`

The manifest records their SHA-256 hashes. These files are intentionally independent
of the current app: updating both the server and current client must not update what
we expect an installed release to understand. Do not format or refactor these copies.

`ClientSupport.swift` replaces only app configuration, Keychain access and the filing
UI enum so the unchanged client can compile as a small macOS executable.
`CheckClient.swift` checks the released client's requests and decoded behaviour against
HTTP exchanges exported from `backend/tests/test_released_client_contract.py`.
The API, database operations and serialization are real; authentication identity and
external services are mocked. No credentials or listener data appear in fixtures.

Run `make backend-compatibility` on macOS. CI also runs it before staging deployment.
To add a supported release, copy its exact files into a new directory, record the
source commit and checksums, and extend the runner/harness to execute **both** baselines.
Do not overwrite the old one. Removing a baseline requires an explicit decision to
end support for that app version, documented in `docs/backend-releases.md`.

When adding an API feature, add a relevant exchange/behaviour assertion. A new endpoint
can have current-client tests without changing older baselines. When changing an
existing endpoint, keep the old exchange and add the new behaviour separately.
