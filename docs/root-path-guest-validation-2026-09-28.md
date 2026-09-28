# Root-path guest invitation validation — 28 September 2026

An alternate compatible meeting site puts its room directly under the HTTPS
origin rather than under `/calls`. The app now accepts both invitation shapes,
keeps the original invitation URL and password, and derives discovery from its
origin. The real invitation parsed and returned the expected discovery endpoint.

The site's TLS chain ends at Russian Trusted Root CA, which the clean iOS 27
simulator did not trust. App discovery failed with `NSURLErrorDomain -1200` and
the system log reported an untrusted root. The root certificate downloaded from
the provider-linked public certificate source matched the root served by the
meeting host (SHA-256 fingerprint
`D2:6D:2D:02:31:B7:C3:9F:92:CC:73:85:12:BA:54:10:35:19:E4:40:5D:68:B5:BD:70:3E:97:88:CA:8E:CF:31`).
It was installed only in a disposable simulator. The app did not disable TLS
validation, and a normal iOS installation still needs this CA to be trusted by
the device for this deployment. The binary SDK exposes a host URL but no custom
CA setting in its public Swift interface.

With that simulator trust setup, the app joined without login in about five
seconds and the browser listed the iOS participant with microphone and camera
off. A focused UI test also joined by entering the link and found the browser
participant. A synthetic browser screen share and camera each produced changing
frames visible in the iOS app. With a synthetic browser microphone tone, the
browser reported active speech and the iOS meeting stayed connected; the
simulator did not provide a reliable audible-output check.

One first-run simulator session aborted in CoreAudio with an RPC timeout shortly
after simultaneous remote mic/camera activation. Separate media checks and a
later combined check remained connected. The failure was not reproduced on the
later run, and physical-device audio behavior was not tested in this run.
