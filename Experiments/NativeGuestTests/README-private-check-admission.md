# Private-check admission regression

Run on macOS with Python 3 and the Xcode command-line tools:

```bash
python3 Experiments/NativeGuestTests/run-private-check-admission.py
```

The default repository is the checkout containing the runner. It must include the reviewed private-check admission production change in GuestSystemAudio and both desktop adapters. A checkout predating that change fails extraction rather than substituting cached or copied production logic. No SDK archive, framework, ignored build directory, network access, signing credential or audio device is needed.

To inspect an immutable source snapshot and retain evidence, use a new output directory:

```bash
python3 Experiments/NativeGuestTests/run-private-check-admission.py \
  --repository /absolute/path/to/source-snapshot \
  --evidence-dir /absolute/path/to/new-evidence-directory
```

The runner extracts 22 declarations from four production Swift files. Receipt keys include the source-relative path and declaration prefix, so the two adapters retain distinct start/stop receipts. Whole-source and extracted-declaration hashes, source line numbers, generated Swift, compiler/runtime logs and test results are retained. Sources are checked again after execution to reject concurrent edits. Existing evidence directories are never overwritten. Without --evidence-dir, only the runner's temporary output is removed afterward.

The positive suite checks 134 admission/lifetime assertions. Seven mutation controls cover stale cached selection, deadline removal, missing Sound revocation, unscoped drain, native-entry state validation, an unwired ordinary-entry guard and missing shutdown owner retirement. A mutation passes only when it compiles, exits unsuccessfully and emits its exact intended assertion marker. A compiler failure, timeout, unrelated assertion or crash is a runner failure. Four self-checks exercise that result gate. The entry-validation mutant still performs the native observation but discards its comparison, so the intended native-state drift assertion proves the missing guard. Extracted adapter methods check five assertions in each of standard, VPIO and R6 configurations.

The tests compile production selection, ticket, admission, cancellation, drain, Sound latch, availability, queue/timeout and shutdown code against a memory-only native/HAL boundary, plus adapter methods against permission/transport mocks. They exercise queue waits, initial and final observations, in-flight starts, Sound ABA, cancellation, expiry, Leave, replacement owners, request-scoped rollback and successful/failed shutdown. They do not link or launch the app, open devices or use the native SDK runtime. Passing does not establish physical readiness, remote privacy, playback continuity, the precise native -5001 failure guard or exact Release acceptance. Retain the separate uninstrumented Release UI replay gate.
