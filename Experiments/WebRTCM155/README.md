# Pinned M155 source preparation

The completed isolated port and acceptance boundaries are recorded in
[`docs/webrtc-m155-port-2026-10-24.md`](../../docs/webrtc-m155-port-2026-10-24.md).
The original guest and prefixed frameworks passed native arm64 Mac and arm64
iOS simulator build/link and loopback gates. That candidate and its evidence are
preserved under `.build/webrtc-m155-port/pre-vt-capability-preservation`.

The current source contract includes a subsequent native Mac H264 capability
repair: hardware VideoToolbox discovery with a conservative Level 3.1 fallback
and the M150 lazy accessor ABI. iOS/simulator keep their existing capability
selection. The changed binaries require fresh qualification; prior live runs
apply only to the preserved binary hashes. Shipping pins and engine defaults
remain unchanged. Native Mac live results and remaining acceptance gates are in
[`the live-validation report`](../../docs/webrtc-m155-live-validation-2026-10-24.md).
Physical iPhone acceptance remains deferred.

This experiment has its own verifier. It does not change or bypass the M150
maintenance and shipping verifiers. The source contract is Jitsi commit
`623fcfe044d5037b3ecd92001c2ef80ca1d932d5`, pristine archive SHA-256
`2b7d74ad4d5a3050ff71a8b2b5af86fadaab7576c24c02ab3a2de2a63692f437`, plus one
locked cumulative `m155-port.patch`.

The included cumulative patch, lock, source manifest, dependency DEPS and gclient
template define this candidate. Source preparation and verification fail on any
identity mismatch. These commands do not download dependencies or build WebRTC.

## Freeze the source contract

Generate the expected content from the existing pristine archive and final patch:

```bash
python3 -B Experiments/WebRTCM155/make-source-manifest.py \
  .build/webrtc-m155-20261024/source.tar.gz \
  Experiments/WebRTCM155/m155-port.patch \
  Experiments/WebRTCM155/source-manifest.json
```

This streams archive files into a temporary Git object store/index, applies the
patch with `git apply --cached`, and writes SHA-256 hashes, executable bits,
symlink targets, and directory entries from the resulting index. It does not
extract or copy a second source tree. The output path must be new.

Create `Experiments/WebRTCM155/m155-lock.json` with this schema. Replace the
descriptive hash placeholders with actual SHA-256 values; helpers reject
mismatched file identities.

```json
{
  "schema_version": 1,
  "source_sha": "623fcfe044d5037b3ecd92001c2ef80ca1d932d5",
  "source_archive_sha256": "2b7d74ad4d5a3050ff71a8b2b5af86fadaab7576c24c02ab3a2de2a63692f437",
  "patch": {"path": "m155-port.patch", "sha256": "PATCH_SHA256"},
  "source_manifest": {"path": "source-manifest.json", "sha256": "MANIFEST_SHA256"},
  "dependencies": {
    "deps": {"path": "DEPS", "sha256": "DEPENDENCY_DEPS_SHA256"},
    "gclient": {"path": "gclient.template", "sha256": "GCLIENT_TEMPLATE_SHA256"},
    "roots": ["build", "third_party/boringssl/src"]
  }
}
```

Paths in the lock are relative to its directory. `dependencies.roots` must list
every actual dependency checkout root explicitly, without wildcards. A root
cannot hide any locked source entry. The example list above is illustrative,
not a complete WebRTC dependency list.

Keep dependency DEPS separate from canonical source: preparation copies the
locked dependency file to `WORKSPACE/DEPS` and the gclient template to
`WORKSPACE/.gclient`, outside `WORKSPACE/src`. The template must name the existing
`src` solution, use `deps_file: "../DEPS"`, and avoid fetching/replacing the source
solution, for example an unmanaged solution with `url: None`. Lock the exact
reviewed template; these tools do not invent or edit its contents.

## Prepare and verify

```bash
python3 -B Experiments/WebRTCM155/prepare-source.py \
  .build/webrtc-m155-20261024/source.tar.gz \
  /absolute/path/to/new-m155-workspace

python3 -B Experiments/WebRTCM155/verify-source.py \
  /absolute/path/to/new-m155-workspace/src
```

Preparation verifies the archive and all locked inputs before extraction,
extracts into a fresh `src`, checks/applies the patch, verifies the complete
result, and writes `source-provenance.json` beside `src`. Existing paths,
including symlinks, are rejected. A failed preparation retains its partial
output for inspection and will not reuse it on a subsequent run.

Verification detects missing/changed/extra entries, executable-bit changes,
and symlink changes. It does not honor `.gitignore`. Only top-level `.git`
metadata and explicit dependency roots are outside source identity; their
sibling files remain checked. Build output must use an explicitly excluded output root (`out` in this lock);
its contents are outside source verification. The verifier reads the lock and manifest at runtime, so replacing
either the patch or manifest without updating its reviewed lock hash fails.

Use `--lock /absolute/path/to/m155-lock.json` to select another copy of the same
pinned source contract. There is no command-line override for the source commit
or pristine archive hash.

## Separate dependency evidence

After a separately authorized dependency sync, record tooling and actual
checkout identities without another sync:

```bash
python3 -B Experiments/WebRTCM155/record-dependencies.py \
  /absolute/path/to/new-m155-workspace \
  /absolute/path/to/depot_tools \
  /absolute/path/to/new-m155-workspace/dependency-provenance.json
```

The recorder first verifies source, external DEPS and `.gclient`. It parses
`.gclient_entries` as literal data and reads each existing Git checkout's actual
revision and tracked changes independently. It also records depot_tools and
launcher hashes. It never invokes gclient: this depot_tools revision reconciles
packages while parsing recursive M155 DEPS even for `revinfo`, which is unsuitable
for a read-only recorder. Non-Git package declarations remain explicitly
unverified; separate toolchain hashes identify the compiler actually used. This
is identity evidence, not certification of every dependency file. Dependency roots are explicitly
reported as unverified by the source verifier.

## Small tests

```bash
python3 -B Experiments/WebRTCM155/test-verifier.py -v
```

Tests use tiny temporary fixtures, including a real temporary Git index and
patch application. They cover valid content; missing/changed/extra source;
gitignored extras; executable and symlink changes; missing/tampered patch;
tampered manifest; wrong pinned identities; dependency-root boundaries; and
fresh-output preparation. A synthetic archive bypass exists only as an
in-process unittest mock; production entry points always check the real hash.
Passing these tests does not validate the final M155 port or its build/runtime.

## Additional acceptance tools

- `PREFIX_OVERLAY.md`: deterministic namespace transformation and verification.
- `LIVEKIT_COMPILE.md`: compile/link original pinned LiveKit sources offline.
- `MAC_METAL_VIEW.md`: actual Mac view construction and GPU draw/readback.
- `run-media-probe.sh OUTPUT_DIR mac|simulator NEW_RESULT_DIR`: loopback,
  resize and atomic sender-policy checks. Set `ROCK_WEBRTC_API=prefixed` for
  `LiveKitWebRTC`, or leave it unset for the guest framework. Each codec sends
  150 synthetic frames, split between two resolutions; these are correctness
  checks, not energy benchmarks. The simulator must already be booted; use
  `ROCK_SIMULATOR=UDID` to choose it explicitly.

Final local evidence is `.build/webrtc-m155-port/accepted-results.json` and the
accepted output directories referenced there. Build logs and earlier failures
remain separate from successful acceptance records.

## Pinned guest wrapper compatibility evidence

Audit an existing arm64 simulator framework without compiling, loading, or
changing it:

```bash
python3 -B Experiments/WebRTCM155/audit-wrapper-abi.py \
  --vendor .build/guest-sdk-vendor \
  --framework .build/webrtc-m155-port/src/out/m155-simulator/WebRTC.framework \
  --output .build/webrtc-m155-port/wrapper-abi/final
```

The tool requires clean pinned vendor commit
`6d5f92869690fa22bb489a9089aa554d733c6936`. It hashes all five wrapper binaries,
the vendor WebRTC binary, and the candidate before the audit, then rejects an
input change during the run. `nm` resolves actual RTC/WebRTC imports against
the candidate and vendor exports, and checks duplicate RTC exports.

For Objective-C methods, it joins `otool` type encodings to `dyld_info` method
identities using implementation address and selector, including categories and
stripped method lists. It compares methods on every exported legacy RTC class
and records whether differing selectors appear in the wrappers. Dynamic
libraries use selector references; static archives use a conservative superset
of method-name strings because `dyld_info` does not decode archive relocations.
Undecodable or conflicting method records fail the audit.

The JSON report retains absent and changed legacy methods even when no audited
wrapper references their selectors. Symbol resolution and selector/type
comparison do not certify receiver classes, dynamically constructed selectors,
C++ layout, ARC ownership, runtime behavior, or device/x86_64 compatibility.
The candidate's arm64 simulator slice is the only architecture checked.

## Mac namespace coexistence

```bash
python3 Experiments/WebRTCM155/run-coexistence.py \
  .build/webrtc-m155-port/src/out/m155-mac/WebRTC.framework \
  .build/webrtc-m155-port/livekit-src/out/m155-mac/LiveKitWebRTC.framework \
  .build/webrtc-m155-port/coexistence-final
```

The runner rejects any shared defined Objective-C class, compiles and loads both
modules, checks real class ownership and per-framework policy exports, and
rejects runtime duplicate-class warnings. Both factories must return audio
capabilities. This is a local compatibility check, not a live conference test.

## Native Mac H264 capability regression

The private parser and query wrapper accept formal VideoToolbox property data;
no device model or SDP-level override determines support. A missing family or
failed query retains the historical Level 3.1 fallback. The first public access
is cached and may query hardware, so avoid it on the main thread during launch.

Run deterministic malformed/missing/partial-family/query-failure checks first:

```bash
bash Experiments/WebRTCM155/run-h264-capability-tests.sh \
  .build/webrtc-m155-port/src /absolute/path/to/new-helper-results
```

After rebuilding, append the actual framework binary and `guest` or `prefixed`.
That also races the two accessors' first calls, verifies both factories consume
the callable API, and requires the current Mac to advertise a level sufficient
for the 1600×1000 fixture. These checks do not replace actual high-resolution
encode/decode and live sharing acceptance.
