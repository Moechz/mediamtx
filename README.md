# MediaMTX for TOS 7

A TerraMaster **TOS 7 App Center** package (`.deb`) of
[MediaMTX](https://github.com/bluenviron/mediamtx) — the dependency-free, single-binary
media streaming server that speaks **RTSP / RTMP / HLS / WebRTC / SRT** at the same time.

This repository contains the packaging sources, the public CI recipe that builds the
binary from upstream source, and the reproducible-build material. It does **not** ship
upstream prebuilt binaries.

## What the package does

* Installs MediaMTX as a hardened systemd service running as the dedicated
  unprivileged user `mediamtx`.
* Opens the **media ports** for LAN clients (they are the core function):
  `RTSP 8554/TCP + 8000-8001/UDP`, `RTMP 1935`, `HLS 8888`,
  `WebRTC 8889 + ICE/UDP 8189`, `SRT 8890/UDP`.
* Keeps the **control plane on loopback only**: management API `127.0.0.1:9997`,
  metrics `127.0.0.1:9998`. They are reachable from the TOS desktop route
  `http://<NAS>:8181/mediamtx/` (a small built-in status console) and
  `…/mediamtx/api/`.
* **Anonymous reading**, **authenticated publishing**: a random publisher password is
  generated at install time and stored root-readable in
  `/var/lib/mediamtx/publisher_password.txt`.
* Configuration lives in `/var/lib/mediamtx/mediamtx.yml` and is hot-reloaded.
* `apt remove` keeps `/var/lib/mediamtx` (config + recordings); `apt purge` deletes it.

## Package layout (`/usr/local/mediamtx`)

```
bin/mediamtx              statically linked Go binary (MIT, built from upstream source)
config.ini                TOS App Center metadata (strict JSON)
mediamtx.lang             23-language display strings
images/icons/mediamtx.svg application icon (clean SVG, < 50 elements)
init.d/mediamtx.service   systemd unit (also dropped in /etc/systemd/system)
nginx/mediamtx.conf       TOS nginx route (also dropped in /etc/nginx/conf.d)
mediamtx.yml.example      default config template -> /var/lib/mediamtx/mediamtx.yml
mediamtx.env.example      optional environment file
webui.bz2                 built-in status console (static HTML, no external assets)
privacy-policy.html       privacy policy (required by review item C3)
PROVENANCE.md             audit trail: sources, hashes, exact build recipe
```

## Build

```bash
./build.sh fetch     # download the CI-built tarball + SHA256SUMS, verify against pins
./build.sh stage     # assemble the deb file system tree
./build.sh verify    # spec assertions (config.ini, .lang, unit, nginx, icon, ELF…)
./build.sh deb       # produce out/mediamtx_<ver>_<arch>.deb and the store asset

make arm64           # cross-build the aarch64 package (CI provides the binary)
./build.sh repro     # print the full bit-reproducible build recipe
```

Local packaging with a locally built binary (development only, not submit-able):

```bash
LOCAL_BIN=/path/to/mediamtx ./build.sh all
```

Outputs:

* `out/mediamtx_<upstream>-<release>_<arch>.deb` — full version, for `apt install`
* `out/mediamtx_<x86_64|aarch64>.deb` + `.sha256` — store release assets

## Reproducible source build (V6)

The `.github/workflows/build-upstream.yml` workflow builds the binary **from the upstream
source tag** with a pinned Go toolchain, `CGO_ENABLED=0` (fully static), no UPX and
`-trimpath`, then **builds each architecture twice with independent caches and asserts
the two sha256 sums are equal** before publishing `SHA256SUMS` to a release.

Upstream metadata, embedded-asset hashes (hls.js, mediamtx-rpicamera) and the exact
commands are documented in [`assets/PROVENANCE.md`](assets/PROVENANCE.md).

## License and attribution

* Upstream MediaMTX: MIT, © 2019 aler9 — <https://github.com/bluenviron/mediamtx>
* This TOS package: independent port, maintained by Moechz.
