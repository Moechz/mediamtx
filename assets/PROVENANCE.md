# PROVENANCE — MediaMTX for TOS 7

This document records where every executable and embedded asset in this package
comes from, so the package can be audited and rebuilt from public sources.

## 1. Upstream project

| Item | Value |
|---|---|
| Project | MediaMTX |
| Repository | https://github.com/bluenviron/mediamtx |
| License | MIT (Copyright (c) 2019 aler9) |
| Version / tag | v1.21.1 |
| Commit | `048255986f7e04b859b4c4efe651448ec785ecd4` (2026-09-20T16:00:57+00:00) |

The only executable shipped by this package (`/usr/local/mediamtx/bin/mediamtx`)
is compiled **from the source code above**. No prebuilt upstream binary is used.

## 2. Build recipe (bit-reproducible)

The binary is built by the public workflow
[`.github/workflows/build-upstream.yml`](https://github.com/Moechz/mediamtx/blob/main/.github/workflows/build-upstream.yml)
of this packaging repository (Actions logs are public). The exact commands are:

```bash
# 1. source
git clone --branch v1.21.1 https://github.com/bluenviron/mediamtx
cd mediamtx
git checkout 048255986f7e04b859b4c4efe651448ec785ecd4

# 2. generated assets (sha256-pinned inside the upstream source tree)
go generate ./...      # hls.js v1.7.3, mediamtx-rpicamera v2.9.0

# 3. build (same flags as upstream scripts/binaries.mk, plus -trimpath)
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS=-trimpath go build -o mediamtx .
#                                                                  ^ arm64 for aarch64

# 4. reproducible-build assertion: run step 3 twice with independent
#    GOCACHE directories; sha256 of both outputs must be identical.
```

| Toolchain | Version | sha256 of toolchain archive |
|---|---|---|
| Go (linux-amd64) | go1.26.8 | `d0f743b33e8d8945e6b1f432edd15785c70507121d6e2a723b21285eddf8b57b` |

`CGO_ENABLED=0` produces a fully static binary (no libc dependency). **No UPX or
any other packer is applied**, so the ELF keeps complete section headers and is
inspectable with standard tools. The `internal/core/VERSION` string is derived
from the git tag by `go generate`, not from a build timestamp, so builds do not
embed wall-clock time.

## 3. Embedded third-party assets

MediaMTX embeds two upstream-vendored assets, both downloaded by `go generate`
and **sha256-verified against hash files that live in the upstream source tree**
(`internal/servers/hls/hlsjsdownloader/HASH`,
`internal/staticsources/rpicamera/mtxrpicamdownloader/HASH_*`):

| Asset | Version | sha256 (source archive) | Where |
|---|---|---|---|
| hls.js | v1.7.3 | `abbda85f3e9b8325fc6b8dbf4fa612ea87144ebad93c2150594e64aad58ec529` | `internal/servers/hls/hls.min.js` (browser HLS player) |
| mediamtx-rpicamera | v2.9.0 (32-bit) | `73a5cfb546c758fd45a40227fc287308f551dbfc0aaa7ffa821563226579bbbc` | `internal/staticsources/rpicamera/mtxrpicam_32/` |
| mediamtx-rpicamera | v2.9.0 (64-bit) | `9c29b775091915ddabfcd1b021eb05fa12bb5fdbf32891cf6d1dd0b3f8209c2f` | `internal/staticsources/rpicamera/mtxrpicam_64/` |

The rpicamera files are only used when the server runs on a Raspberry Pi; they are
embedded on all platforms because the upstream `//go:embed` declarations are not
build-constrained. All other code in the binary is pure Go compiled from the
upstream module graph pinned by `go.mod` + `go.sum`.

## 4. Package integrity

| Artifact | sha256 |
|---|---|
| `mediamtx-linux-amd64.tar.gz` (CI source build) | printed in the Release `SHA256SUMS` and pinned in `config.env` (`SHA256_TARBALL_AMD64`) |
| `mediamtx-linux-arm64.tar.gz` (CI source build) | release `SHA256SUMS` + `config.env` (`SHA256_TARBALL_ARM64`) |
| `mediamtx` binary (amd64, local reference build) | `ca0d9e52c21d062c645ad2b5adc29375c8a0838357aa0d8d63edb7e7637f59cf` |

Two independent local builds (fresh `GOCACHE`, same toolchain) produced this exact
hash; the CI job repeats the double-build assertion on every release.

## 5. Runtime behaviour

* No online installation, download or self-update is performed by any script in
  this package. The `mediamtx --upgrade` / `--check-version` CLI flags exist
  upstream but are **never invoked** here.
* The service does not initiate outbound connections unless the operator
  explicitly configures a feature that needs one (external auth server,
  redirect/on-demand source, playback server).
* Management API, metrics and playback listeners bind to `127.0.0.1` only.
