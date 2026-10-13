#!/bin/bash
# Keep provider wrappers at their upstream revision; replace only open WebRTC.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
revision=6d5f92869690fa22bb489a9089aa554d733c6936
checkout="$repo_dir/.build/guest-sdk-vendor"
if [[ ! -d "$checkout/.git" ]]; then
  mkdir -p "$checkout"
  git -C "$checkout" init --quiet
  git -C "$checkout" remote add origin https://github.com/salute-developers/jazz-ios-sdk.git
fi
if ! git -C "$checkout" rev-parse --verify HEAD >/dev/null 2>&1; then
  # An existing checkout can supply the immutable objects without downloading
  # another copy. Fetch copies objects; no alternates or external symlinks remain.
  source_repository="${1:-https://github.com/salute-developers/jazz-ios-sdk.git}"
  if [[ -d "$source_repository" ]]; then source_repository="$(cd "$source_repository" && pwd)"; fi
  git -C "$checkout" fetch --depth 1 "$source_repository" "$revision"
  git -C "$checkout" -c advice.detachedHead=false checkout --detach --quiet "$revision"
fi
[[ "$(git -C "$checkout" rev-parse HEAD)" == "$revision" ]] || {
  echo "Unexpected guest wrapper revision; refusing to modify the checkout" >&2; exit 1;
}
[[ -z "$(git -C "$checkout" status --porcelain)" ]] || {
  echo "Guest wrapper checkout has changes; refusing to use it" >&2; exit 1;
}
for name in JazzSDK LibSberCast JazzCore JazzScreenShareImpl SDSoup; do
  [[ -f "$checkout/Sources/$name.xcframework/Info.plist" ]] || {
    echo "Missing wrapper $name (check Git LFS availability)" >&2; exit 1;
  }
done
link="$repo_dir/Dependencies/guest-sdk/VendorSources"
if [[ -L "$link" ]]; then
  [[ "$(readlink "$link")" == ../../.build/guest-sdk-vendor/Sources ]] || {
    echo "Unexpected VendorSources symlink" >&2; exit 1;
  }
elif [[ -e "$link" ]]; then
  echo "VendorSources must be a generated symlink" >&2; exit 1
else
  ln -s ../../.build/guest-sdk-vendor/Sources "$link"
fi
echo "Guest wrappers ready at $revision"
