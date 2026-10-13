# Guest integration binary overlay

The provider's five wrappers stay at upstream revision
`6d5f92869690fa22bb489a9089aa554d733c6936`. They are fetched locally by
`scripts/prepare-guest-sdk.sh`; they are not republished or modified here.
The generated `VendorSources` symlink points to that independent checkout.

Only open-source WebRTC is replaced with the immutable artifact pinned in
`Package.swift`. Its source recipe, patches, linked notices and provenance are
under `Experiments/GuestSDKRebuild`. The build checks for the native output-lifetime
API and embedded provenance, so a stock binary cannot silently enter a release.

Before resolving/building the project on a fresh checkout:

```sh
scripts/prepare-guest-sdk.sh
xcodegen generate
```
