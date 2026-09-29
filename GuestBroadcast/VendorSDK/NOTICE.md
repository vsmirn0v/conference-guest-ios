# Guest broadcast SDK component

`JazzSDKScreenShare.xcframework` and `JazzScreenShareResources.bundle` were
copied from the pinned upstream `jazz-ios-sdk` revision
`6d5f92869690fa22bb489a9089aa554d733c6936` (SDK 25.3.1020). The
device framework executable is unchanged (SHA-256
`7c03979a1425e29210f4b45805aa3f5a63c082ee429d16671431421123a9cbbd`).

Upstream ships this component under `Sources/` but omits it from its Swift
package target list. Its generated public Swift interfaces also import private
implementation modules that the package does not expose. In this isolated copy,
only the `*.swiftinterface` files were adjusted: remove those private imports
and add the public `CoreMedia` import required by the exported method signature.
The generated headers have only trailing whitespace removed. The framework
executable, ABI metadata, and resources remain upstream versions. Recheck this
adaptation when updating the pinned SDK revision.

The upstream SDK's `LICENCE.MD` points to the provider's service agreement;
distribution of this component must remain covered by the account holder's SDK
permission.
