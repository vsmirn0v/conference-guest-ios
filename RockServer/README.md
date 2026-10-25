# Rock room service

This directory contains the Rock’n’Roll public test jam: a small standard-library Go website and token endpoint, a browser participant client, and configuration for a single LiveKit room server. It is used only for `https://rock.glowsoft.ru/jams/test`. The iPhone app uses the native LiveKit SDK for this link. Supported desktop browsers can explicitly publish a screen share. The room also offers a synthetic demo card and a short test tone, so screen viewing, zoom and speaking status can be checked without sharing private content or granting microphone access.

The test room is public, capped at 12 participants, and intentionally has no organizer login, room creation, recording, transcription, or durable member database. The API issues random participant identities and 15-minute room-scoped join tokens. There is a 30-join-per-minute global limit. Do not use this guessable demo link for private sessions.

## Build

```sh
cd site-src && pnpm install --frozen-lockfile && pnpm test && pnpm run build && cd ..
gzip -n -9 -c site/app.js > site/app.js.gz
go test ./...
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o rock-web .
```

`site/app.js` and `site/app.js.gz` are committed build assets so the host does not need Node. The web binary embeds all pages and assets. Its runtime needs `ROOM_API_KEY`, `ROOM_API_SECRET`, and `PUBLIC_ROOM_URL=wss://rock.glowsoft.ru`; keep the matching key and secret out of Git. `/api/jams/test/join` accepts a JSON display name and returns a short-lived token. `/healthz` returns `ok`.

## Running instance

The live instance uses two Podman containers, `rock-room` and `rock-web`, with `--restart=always` and host networking. Their CPU/memory limits are 2 CPUs/2 GiB and 0.5 CPU/128 MiB respectively. The host's enabled `podman-restart.service` restores them after reboot. LiveKit uses TCP 7880 for local signaling (reverse-proxied as `/rtc`), TCP 7881 and UDP 7882 for ICE; the latter two are reachable directly. The Go service listens on loopback port 7878. Nginx's dedicated site file is [nginx-rock.conf](deploy/nginx-rock.conf), installed separately from the existing default virtual host. TLS uses a separate certificate for this hostname. The example room config is [livekit.example.yaml](deploy/livekit.example.yaml).

Secrets live in root-owned files under `/opt/rocknroll` on the server, and the web binary under `/opt/rocknroll/bin`. No room credential, invite or participant name is written to the repository. The nginx site disables access logging; the Go process logs startup/errors but no request or token bodies.

For rollback, restore the previous `/opt/rocknroll/bin/rock-web-linux-amd64` binary and restart only `rock-web`, or disable only the dedicated nginx site and stop only `rock-web` and `rock-room`. Test `nginx -t` before a reload. Do not alter the shared default virtual host or other Podman services. Reboot persistence has been configured and read back, but a node reboot has not been performed for this pilot.

## Native Mac distribution

The homepage links to the Apple Silicon Mac disk image and the existing iPhone/iPad TestFlight beta. The Mac app requires macOS 13 or later. Its stable and beta update channels use one Sparkle feed at `https://rock.glowsoft.ru/mac/appcast.xml`; stable items omit `sparkle:channel`, and beta items include `<sparkle:channel>beta</sparkle:channel>`. The Mac app selects the channel in Settings. A beta channel can initially offer the same release as stable.

Nginx serves these files directly, outside the Go embed and Podman containers. The dedicated site configuration exposes only the exact metadata/channel paths and versioned Apple Silicon `.dmg` filenames; other `/mac/` paths return 404. It does not execute release-directory files or list directories. No Go handler, credential, tracking parameter or participant information is needed to download an update.

| Public path | File on host | Cache policy |
| --- | --- | --- |
| `/mac/appcast.xml` | `/var/www/rocknroll/releases/appcast.xml` | `no-store` |
| `/mac/latest.json` | `/var/www/rocknroll/releases/latest.json` | `no-store` |
| `/mac/stable/latest.dmg` | `/var/www/rocknroll/releases/stable/latest.dmg` | `no-store` |
| `/mac/beta/latest.dmg` | `/var/www/rocknroll/releases/beta/latest.dmg` | `no-store` |
| `/mac/releases/RockNRoll-<version>-<build>-arm64.dmg` | `/var/www/rocknroll/releases/releases/RockNRoll-<version>-<build>-arm64.dmg` | One year, immutable |

The channel `.dmg` files are symlinks to `../releases/<immutable filename>`. They serve the same artifact bytes as the versioned URL; their names are stable and their responses are not cached. Both aliases may point to the stable artifact until a separate beta exists. Sparkle enclosure URLs must always use the immutable versioned URL, never a channel alias.

`latest.json` is a small public release inventory, with `schemaVersion: 1` and `stable`/`beta` objects. Each contains string fields `version`, `build`, `downloadURL` (the absolute immutable HTTPS URL), and `sha256` (the lowercase artifact digest). It contains release metadata only. The website and update client do not need it to serve or select an update.

Only the root-owned publication process writes `/var/www/rocknroll/releases`; nginx reads it. Public directories use mode 0755 and files use 0644. Private staging, locks and rollback metadata stay under `/var/www/rocknroll/.publish-stage` with mode 0700, outside the exposed tree. Keep signing keys, credentials, temporary build files and logs outside the public tree. `/opt/rocknroll` retains its private permissions for existing room-service secrets. Publish a Developer ID signed, notarized and stapled app inside a DMG at its new immutable path first, verify its bytes, then atomically replace the signed-enclosure appcast, release inventory and channel symlinks using temporary siblings and rename. Never overwrite an existing versioned artifact. Do not publish an appcast enclosure before its artifact is readable. Save the previous metadata and channel targets outside the public tree for rollback.

Deployment requires replacing only the dedicated rock nginx site with [nginx-rock.conf](deploy/nginx-rock.conf), testing with `nginx -t`, and reloading nginx. Rebuild and replace only the `rock-web` binary for homepage changes; the room container and shared default site need no changes. Read back the live homepage, feed, inventory and both aliases, compare channel and immutable DMG hashes, and check cache headers before declaring publication complete. These configuration files do not establish that a Mac artifact has been published or notarized.
