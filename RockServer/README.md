# Rock room service

This directory contains the Rock’n’Roll public test jam: a small standard-library Go website and token endpoint, a browser participant client, and configuration for a single LiveKit room server. It is used only for `https://rock.glowsoft.ru/jams/test`. The iPhone app uses the native LiveKit SDK for this link. Supported desktop browsers can explicitly publish a screen share; the app can display only that share while keeping jam audio live.

The test room is public, capped at 12 participants, and intentionally has no organizer login, room creation, recording, transcription, or durable member database. The API issues random participant identities and 15-minute room-scoped join tokens. There is a 30-join-per-minute global limit. Do not use this guessable demo link for private sessions.

## Build

```sh
cd site-src && pnpm install --frozen-lockfile && pnpm run build && cd ..
gzip -n -9 -c site/app.js > site/app.js.gz
go test ./...
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o rock-web .
```

`site/app.js` and `site/app.js.gz` are committed build assets so the host does not need Node. The web binary embeds all pages and assets. Its runtime needs `ROOM_API_KEY`, `ROOM_API_SECRET`, and `PUBLIC_ROOM_URL=wss://rock.glowsoft.ru`; keep the matching key and secret out of Git. `/api/jams/test/join` accepts a JSON display name and returns a short-lived token. `/healthz` returns `ok`.

## Running instance

The live instance uses two Podman containers, `rock-room` and `rock-web`, with `--restart=always` and host networking. Their CPU/memory limits are 2 CPUs/2 GiB and 0.5 CPU/128 MiB respectively. The host's enabled `podman-restart.service` restores them after reboot. LiveKit uses TCP 7880 for local signaling (reverse-proxied as `/rtc`), TCP 7881 and UDP 7882 for ICE; the latter two are reachable directly. The Go service listens on loopback port 7878. Nginx's dedicated site file is [nginx-rock.conf](deploy/nginx-rock.conf), installed separately from the existing default virtual host. TLS uses a separate certificate for this hostname. The example room config is [livekit.example.yaml](deploy/livekit.example.yaml).

Secrets live in root-owned files under `/opt/rocknroll` on the server, and the web binary under `/opt/rocknroll/bin`. No room credential, invite or participant name is written to the repository. The nginx site disables access logging; the Go process logs startup/errors but no request or token bodies.

For rollback, restore the previous `/opt/rocknroll/bin/rock-web-linux-amd64` binary and restart only `rock-web`, or disable only the dedicated nginx site and stop only `rock-web` and `rock-room`. Test `nginx -t` before a reload. Do not alter the shared default virtual host or other Podman services. Reboot persistence has been configured and read back, but a node reboot has not been performed for this pilot.
