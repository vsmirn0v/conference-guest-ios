# Direct Mac releases

The App Store build remains the default. Direct builds use the same sandbox,
app group and CloudKit container, with separate generated update metadata and
Sparkle sandbox exceptions. Release keeps Production CloudKit. Never use a
direct archive for TestFlight or replace the checked-in Info/entitlement files.

Build a new immutable direct archive (choose a new numeric build number):

```sh
python3 NativeMacGuest/build.py --distribution direct --configuration Release \
  --identity 'Apple Development: YOUR EXISTING IDENTITY' \
  --version 0.3.0 --build-number BUILD_NUMBER --archive \
  --allow-provisioning-updates --output-dir .build/native-dmg/build
```

The existing `--install`, development signature and `--check-container` gate
still apply. Reuse one output directory for build caching; existing archives
are never replaced. App Store builds use `--distribution app-store`, without
the framework, compile flag, Sparkle Info keys or mach-lookup exceptions.

The direct dependency is the locally staged official Sparkle 2.10.0 distribution
at `.build/native-dmg/Sparkle/Sparkle.framework`. The builder verifies its version,
build, binary SHA-256 and the downloaded `Sparkle-2.10.0.tar.xz` SHA-256. The
pins and public update key are in `build_support.py`. Sparkle is embedded with
Xcode code signing. Generated files live in `<output-dir>/Spec` and build
evidence records the distribution, dependency and final framework hashes.

Export and notarize through the account already signed into Xcode:

```sh
python3 NativeMacGuest/distribution/release.py export \
  --archive .build/native-dmg/build/RockNRollNativeGuest-0.3.0-BUILD_NUMBER.xcarchive \
  --output .build/native-dmg/export-BUILD_NUMBER
```

This uses `xcodebuild -exportArchive` with `method=developer-id`,
`destination=upload`, automatic signing, team `5V64BP2H3P` and Production
CloudKit; then `-exportNotarizedApp`, app stapling and signature/Gatekeeper
validation. Xcode handles its cloud-managed Developer ID certificate and
notarization credentials. It does not export a private signing key or require
a separate `notarytool` profile. Keep the archive until the notarized app has
been exported. The output directory must be new, so failed/partial runs remain
available for diagnosis.

Notarization is asynchronous. Export retries only Xcode's specific “archive is
processing” diagnostic every 30 seconds, for at most 30 minutes; other errors
stop immediately. Detailed attempt logs stay in the export directory. If Apple
still has the archive queued, resume without another upload:

```sh
python3 NativeMacGuest/distribution/release.py finalize \
  --archive .build/native-dmg/build/RockNRollNativeGuest-0.3.0-BUILD_NUMBER.xcarchive \
  --output .build/native-dmg/export-BUILD_NUMBER
```

Use `--wait-seconds 0` for one immediate finalization attempt, or a value up to
`1800` to bound retries. Successful finalization staples and validates the app
and writes `export-evidence.json` just like the initial export.

Package that verified app:

```sh
python3 NativeMacGuest/distribution/release.py package \
  --app '.build/native-dmg/export-BUILD_NUMBER/App/RockNRoll Native Guest.app' \
  --output .build/native-dmg/package-BUILD_NUMBER
```

The image contains the notarized, stapled app and an Applications symlink. The
tool mounts it read-only and revalidates the packaged app, then writes
`RockNRoll-<version>-<build>-arm64.dmg` and `release.json`. The outer DMG can
optionally be signed with a locally available `--dmg-identity` and separately
notarized using an existing `--notary-profile`; those are not needed to validate
the stapled app inside it. Evidence distinguishes app Gatekeeper acceptance
from outer DMG assessment and notarization. Do not describe the outer image as
notarized when only the contained app has a ticket.

Prepare public metadata for the first stable release:

```sh
python3 NativeMacGuest/distribution/release.py feed \
  --release .build/native-dmg/package-BUILD_NUMBER/release.json \
  --channel stable --output .build/native-dmg/feed-BUILD_NUMBER
```

For later releases, additionally pass both `--previous-feed appcast.xml` and
`--previous-inventory latest.json` from the currently published release. The
previous feed's signature is verified before reuse. Stable entries omit
`sparkle:channel`; beta entries use `beta`. Six releases per channel are kept.
Stable users never opt into beta; beta users can also receive newer stable
releases. The first stable inventory initializes beta to the same artifact.

The tool verifies the DMG digest, checks the existing Keychain public key, signs
and verifies the enclosure, then signs and verifies the complete appcast. It
uses the Keychain account `dev.vsmirn0v.conferenceguest.nativeguest.sparkle`
through Sparkle's `--account` option. It never exports the private Ed25519 key.
Feed signing is required by the app, in addition to archive signing. The JSON
inventory contains only version, build, immutable download URL and SHA-256.

These commands prepare local files only. Publish the immutable DMG first,
verify its public bytes, then atomically replace feed/inventory and channel
symlinks as described in `RockServer/README.md`. The channel aliases are
`/mac/stable/latest.dmg` and `/mac/beta/latest.dmg`; feed enclosures always use
`https://rock.glowsoft.ru/mac/releases/<immutable filename>`.

The repeatable publisher checks local feed/enclosure signatures and package
digests, then performs a read-only SSH preflight by default:

```sh
python3 NativeMacGuest/distribution/publish.py \
  --feed .build/native-dmg/feed-BUILD_NUMBER/appcast.xml \
  --inventory .build/native-dmg/feed-BUILD_NUMBER/latest.json \
  --package .build/native-dmg/package-BUILD_NUMBER
```

Add `--apply` to publish the reviewed files through `root@kachat.app`.
Optionally use `--evidence NEW_FILE.json` to save successful HTTPS readback.
The only public write root is `/var/www/rocknroll/releases`; the private upload,
lock and rollback root is `/var/www/rocknroll/.publish-stage` (0700). Public
directories are 0755 and files are 0644. Existing `/opt/rocknroll` secrets and
permissions are untouched. Immutable collisions fail unless hashes match.
Promotion checks for concurrent metadata changes, retains previous metadata
and symlink targets, atomically replaces aliases/inventory, and replaces the
signed appcast last. It then hashes the immutable HTTPS download, both channel
aliases and both metadata files, and verifies cache policies. This publisher
does not install nginx configuration, change services or replace the web binary.

Tooling checks, without an app build or publication:

```sh
python3 -m py_compile NativeMacGuest/build.py NativeMacGuest/distribution/*.py
python3 -m unittest discover -s NativeMacGuest/distribution -p 'test_*.py'
```
