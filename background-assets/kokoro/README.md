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

## Test a locally installed build

Apple only serves its hosted copy to TestFlight and App Store installations.
An app installed by `make ios-phone` therefore uses Apple's local mock server.
Hearful runs the stable ARM Linux developer tools in Docker because the
`ba-package 2.0-beta` in the current Xcode beta rejects JSON manifests.

The one-time setup is:

```bash
make ios-assets-license
make ios-assets-setup
```

The setup command prints the generated root certificate and the exact HTTPS
URL for this Mac. Send the `.cer` file to the iPhone, install its downloaded
profile, then enable it in **Settings > General > About > Certificate Trust
Settings**. With Developer Mode enabled, open **Settings > Developer >
Background Assets Testing > Development Overrides** and set **URL Override**
to the printed URL.

For each local development session, keep this running in one terminal:

```bash
make ios-assets-serve
```

Then use `make ios-phone` in another terminal and download the natural voice in
Hearful. The serving command rebuilds the ignored archive only when the
manifest, model, or voices file changed. Set `HEARFUL_BA_FORCE_PACKAGE=1` to
force a rebuild. It reads Apple's `aarch64.zip` from `~/Downloads` by default;
set `HEARFUL_BA_TOOLS_ZIP` if the download is elsewhere. Generated tools,
certificates, private keys, and archives stay under ignored `build/` output.

The app and `com.henrydashwood.hearful.BackgroundAssets` extension both use
the `group.com.henrydashwood.hearful` app group. For GitHub's TestFlight job,
create a separate App Store distribution profile for the extension and store
its base64 contents in the
`APPLE_BACKGROUND_ASSETS_PROVISIONING_PROFILE` repository secret. The existing
`APPLE_PROVISIONING_PROFILE` remains the profile for the main app.
