# Physical preview cadence experiment

See [device findings](../../docs/preview-cadence-device-2026-10-11.md).

Generate the isolated project with `python3 Experiments/PreviewCadence/build_lab.py`.
Then build-for-testing `.build/preview-cadence/PreviewExperiment.xcodeproj`, scheme
`PreviewExperiment`, configuration Debug, with the existing package cache and a
physical iPhone destination. The separate bundle identifier preserves the app
under test and its data. Explicit `ROCK_PREVIEW_EXPERIMENT=1` activates the lab;
all fixture, override and metric code is excluded from Release.

Run `profile_device.py --help` for the paired capture options. Each camera run is
bounded below five minutes. Do not accept a successful xctrace exit alone:
verify its actual interval covers both phases, cadence matches and nonzero
system power is available when comparing battery use. Charging reports zero
system consumption. Instrumented callback/enqueue timestamps exclude final
screen presentation. The exporter distinguishes independent CPU/display/GPU
streams and never treats missing metrics as zero.

The 2026-10-11 wireless trace failure remains unresolved. Use on-device Power
Profiler recording or a qualified wireless connection for the next battery run.
