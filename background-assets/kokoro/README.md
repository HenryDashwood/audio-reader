# Kokoro on-demand asset pack

The app bundle deliberately contains neither Kokoro's weights nor its voice
archive. For local packaging, place these ignored files here:

```text
Kokoro/kokoro-v1_0.safetensors
Kokoro/voices.npz
```

From this directory, create the Apple-hosted Background Assets archive with:

```bash
xcrun ba-package package Manifest.json -o Hearful-Kokoro-English-v1.aar
```

The `ba-package 2.0-beta` bundled with the current Xcode 27 beta incorrectly
rejects `.json` manifest paths before parsing them. The manifest can be used
with the release tool once Apple ships the fix; this is an Xcode beta tooling
issue rather than an asset-pack schema error.

Upload the resulting ignored `.aar` to the asset pack whose identifier is
`hearful-kokoro-english-v1` in App Store Connect. Use Apple's
Background Assets mock server to test downloads before an asset pack is
available through TestFlight.

The app and `com.henrydashwood.hearful.BackgroundAssets` extension both use
the `group.com.henrydashwood.hearful` app group. For GitHub's TestFlight job,
create a separate App Store distribution profile for the extension and store
its base64 contents in the
`APPLE_BACKGROUND_ASSETS_PROVISIONING_PROFILE` repository secret. The existing
`APPLE_PROVISIONING_PROFILE` remains the profile for the main app.
