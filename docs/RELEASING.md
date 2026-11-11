# Releasing Desk Draw

Sparkle is pinned in `Package.swift` and `Package.resolved`. Its framework and helpers are embedded
in the app and signed from the inside out by `scripts/sign-app.sh`. Update downloads stay on GitHub
Releases; `SUFeedURL` points to this repository's `main/appcast.xml`. No separate server is needed.

## Signing keys

The Sparkle Ed25519 key lives in the login Keychain under account `de.haga-welt.DeskDraw`. Only its
public key is committed in `Resources/Info.plist`. Both update archives and the feed must be signed;
the app verifies signatures before extracting a download.

`scripts/sparkle-tool.sh` downloads the pinned Sparkle tools and verifies their SHA-256 checksum.
It uses the trusted `generate_keys` tool to create a protected temporary key file for signing tools,
then deletes the file when the command exits. The key is never passed as a command-line value or
written into the repository. A first use of `generate_keys` on another machine may need a Keychain
approval.

Do not regenerate or replace a release key: existing installations trust the committed public key.
Back up the private key securely using Sparkle's `generate_keys --account de.haga-welt.DeskDraw -x`
option, and import it into the login Keychain on another release machine with `-f`. Keep any export
outside the repository and remove it after secure transfer. Never commit it or paste it into chat.

## App signing and notarization

Local builds default to ad-hoc signing, including Sparkle's nested helpers. This supports
cryptographically verified Sparkle updates, but does not provide Apple's Developer ID identity or
notarization. macOS may ask users to allow the app and renew Screen Recording permission.

For Developer ID releases, set `DESKDRAW_SIGN_IDENTITY` to your **Developer ID Application**
certificate's name or fingerprint. To notarize, also set `DESKDRAW_NOTARY_PROFILE` to a profile
already stored with `xcrun notarytool store-credentials`. The build script enables hardened runtime,
signs all nested components, submits the ZIP to Apple, staples the ticket, and verifies it. It refuses
to notarize an ad-hoc build. Apple credentials and signing identities are never committed.

## Prepare a release

1. Update `CFBundleShortVersionString` and increment the numeric `CFBundleVersion` in
   `Resources/Info.plist`. The build number must exceed every version in the published feed.
2. Write Markdown release notes in `Resources/ReleaseNotes/<version>.md`.
3. Run `swift test` and `./scripts/build-app.sh`, then `./scripts/test-updates.py`.
4. Prepare the existing verified app, for example:

   ```sh
   ./scripts/prepare-release.py Resources/ReleaseNotes/0.3.0.md --skip-build
   ```

   Omit `--skip-build` to build first. This checks the Keychain key against the public key embedded
   in the app, verifies the app's code signature, creates the ZIP, embeds release notes in the feed,
   signs the feed and archive, verifies both signatures and the download URL/length, and writes
   `build/releases/v<version>/`. Preparation refuses to overwrite an existing output directory.
   Preserve published bytes; only delete a preparation if it has never been published.

The integration test creates its own app bundles with unique bundle identifiers, test-only HTTP
permissions, and a local server. It verifies a real install/relaunch, then checks that changing a
signed feed or changing a byte in a signed archive leaves the original app installed. It never
updates an installed Desk Draw or changes its preferences.

## Publish

Preparation does not publish, tag, commit, or push. When a release is authorized:

1. Commit the verified source to `main`, tag that commit as `v<version>`, and push both.
2. Create the GitHub Release for that tag, uploading the prepared `Desk-Draw-<version>.zip` and
   `SHA256SUMS`; use its `release-notes.md` as the release body.
3. Verify the published ZIP checksum matches the prepared archive.
4. Copy the prepared `appcast.xml` to the repository root, commit, and push `main`. Publish the ZIP
   **before** the feed so installed apps never see an update whose download is missing.
5. Verify the live feed with `scripts/sparkle-tool.sh sign_update --account de.haga-welt.DeskDraw
   --verify appcast.xml`, and check for updates from an older updater-enabled installation.

Never edit a signed feed or its embedded release notes after preparation; that invalidates its
signature. To make changes, regenerate and re-sign the feed. The initial repository feed is signed
and empty so it can be published before the first updater-enabled release without advertising an
unpublished archive. Users on versions before 0.3.0 need one manual install.
