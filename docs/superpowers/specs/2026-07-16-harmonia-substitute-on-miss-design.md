# harmonia substitute-on-miss (302 redirect + background warm) + mirror decommission

> **Superseded by** `2026-07-16-harmonia-streamthrough-nar-design.md`. The
> 302-redirect + background warm was replaced by an in-process stream-through
> cache to eliminate fetch amplification (the redirect made the client and the
> warm each pull the NAR once). The mirror-decommission portions of this spec
> still stand and were implemented; only the harmonia miss mechanism changed.

**Date:** 2026-07-16 (v3 — non-blocking 302 redirect, harmonia HTTPS, no nginx upstream)
**Status:** superseded

## Purpose

The storage study is concluded: the dedup+zstd store beats storing upstream
xz NARs (~10% net savings once overheads are counted), so the
`upstream.cache.nixos.lv` pull-through mirror and its dataset are being
decommissioned. `cache.nixos.lv` (harmonia over the store) becomes the one
event cache. A miss is handled entirely inside harmonia, non-blocking:

1. **302 redirect (serve it now, never block):** on a narinfo miss harmonia
   returns `302 Found` → `https://cache.nixos.org/<hash>.narinfo`. nix follows
   it; the follow-up NAR (in upstream's `nar/<filehash>.nar.xz` format, which
   matches no harmonia route) is caught by a **catch-all default service** that
   302s it to the same path upstream. The whole NAR transfer stays off
   harmonia's request path.
2. **background warm (own it next time):** in parallel with the redirect,
   harmonia fetches `<hash>.narinfo` from `miss_upstream_url` over its **own
   HTTPS** (tokio-rustls), reads `StorePath:`, and asks the nix daemon to
   `EnsurePath` it. The path lands in the dedup store; the next request for it
   is served locally (no redirect).

nginx is a plain `proxy_pass` to harmonia — no fall-through, no resolver
listener. 302 (not 301) + `Cache-Control: no-store` so nothing caches the
redirect once the path goes local.

## Component 1: harmonia patch (`substitute-on-miss`)

Grounded in harmonia 3.1.0 source:

- **Trigger:** `harmonia-cache/src/narinfo.rs` `get()` — the sole narinfo
  miss site. When `substitute_on_miss` is set, the miss returns 302 to
  `<miss_upstream_url>/<hash>.narinfo` and kicks off the warm; otherwise it
  keeps the stock 404.
- **NAR redirect:** a `default_service` catch-all in `main.rs` 302s any
  unmatched path (notably the post-narinfo `nar/<filehash>.nar.xz`) to the
  same path on `miss_upstream_url`; 404 when the feature is off.
- **Hash-part resolution (for the warm):** `EnsurePath` needs a full store
  path; the client sends only the hash part. The warm HTTPS-GETs
  `<miss_upstream_url>/<hash>.narinfo` (tokio-rustls, Mozilla roots via
  webpki-roots — both vendored through `importCargoLock`, no cargoHash) and
  parses `StorePath:`.
- **Warm:** background task calling `ensure_path` via
  `harmonia-store-remote` (`client.rs:714`) against the **real nix-daemon
  socket** (`/nix/var/nix/daemon-socket/socket`) — not harmonia-daemon,
  which does not substitute. Signature/trusted-key enforcement is the
  daemon's, as for any substitution.
- **Herd control:** process-global in-flight set keyed by hash part; one
  warm per path regardless of concurrent misses; entries clear on task
  completion. Failures logged, not retried (the next miss retries).
- **Config (harmonia TOML via `services.harmonia.cache.settings`):**
  - `substitute_on_miss = false` (default off = stock 404 behavior)
  - `miss_upstream_url = "https://cache.nixos.org"` (redirect target + warm
    fetch source; must be `https://`)
  - `miss_daemon_socket = "/nix/var/nix/daemon-socket/socket"` (default)
- **Observability:** counters in the existing `prometheus.rs` registry:
  `narinfo_misses_total`, `warms_started_total`, `warms_completed_total`,
  `warms_failed_total`.

**Carrying the patch:** `pkgs/harmonia/substitute-on-miss.patch` in the
systems repo, applied via `applyPatches` on the source + `cargoDeps =
rustPlatform.importCargoLock { lockFile = ...; }` (the default fetchCargoVendor
path normalizes workspace path deps out of its lock consistency check;
importCargoLock vendors from the lockfile directly, no cargoHash — and it
vendors the new `tokio-rustls`/`webpki-roots` registry crates automatically
from the patched `Cargo.lock`). Intended for an upstream PR to
nix-community/harmonia after the event.

## Component 2: ghostgate nginx — plain proxy

harmonia handles the miss itself (302 + catch-all), so nginx is just:

```nix
"cache.nixos.lv".locations."/".proxyPass = "http://cache.dc.nixos.lv";
```

No fall-through, no resolver listener, no `cacheUpstreamProxy` snippet — all
removed. (The v4-only-resolver and verify-depth-4 lessons now live in
harmonia's own HTTPS client instead.)

## Component 3: ghostgate harmonia settings

```nix
services.harmonia.cache.settings = {
  enable_compression = false;              # existing
  substitute_on_miss = true;
  miss_upstream_url = "https://cache.nixos.org";
};
```
(`services.harmonia.package` carries the patch; see Component 1.)

## Component 4: mirror decommission (systems repo)

Remove, in one sweep (each was added this week; reverse of the mirror
plan):

- ghostgate: the `upstream.cache.nixos.lv` nginx vhost; the
  `fileSystems."/var/cache/nar"` mount, tmpfiles rules, and the nginx unit's
  `ReadWritePaths`/`RequiresMountsFor` for it; the
  `networking.hosts."127.0.0.1"` pin; the knot zone CNAME; the kresd
  `ourDomains` entry; the `nix.settings.substituters` mkAfter line (the
  nixpkgs-default `https://cache.nixos.org/` remains and is now the intended
  direct path).
- citadel: drop `upstream.cache.nixos.lv` from the ctf-address hosts pin
  (keep `cache.nixos.lv`).
- brass: drop `upstream.cache.nixos.lv` from `onsiteBackends`.
- docs: event-network.md — replace the mirror bullet with the
  harmonia-pull-through description; drop the name from the onsite list and
  the public-DNS deploy dependency.
- **Site repo follow-up:** `content/2026/onsite.md` currently tells
  attendees about `upstream.cache.nixos.lv` — reword that paragraph to
  describe cache.nixos.lv's transparent pull-through instead (separate
  commit on the site branch/main).
- Operator (not in repo): remove the public `upstream.cache.nixos.lv` DNS
  record; after deploy, `zpool destroy ghostgate-nar` (capture
  `zpool status -DD ghostgate` and `zfs list -o space` for the write-up
  first).

Ordering note: deploy the decommission + patched harmonia together; nothing
depends on the mirror once the vhost and substituter entry go.

## Error handling

- Redirect always succeeds (it's just a `Location` header) — the client is
  served by upstream regardless of warm outcome, so a miss never fails the
  client path.
- Warm: upstream narinfo 404/unreachable, TLS failure, or daemon error → log
  + `warms_failed_total`; no store change; the next miss retries.
- Duplicate misses during a warm: coalesced by the in-flight set.
- Daemon substitution failure (nothing has the path, sig rejected): logged;
  store unchanged.

## Testing

- Rust: unit tests for the `StorePath:` parse and the `redirect_target` URL
  builder; bin unit + chroot integration suites pass; clippy `-D warnings`
  clean. (The `retry` integration test is flaky on a loaded box — proven
  pre-existing on pristine v3.1.0, unrelated to these changes.)
- Build: `applyPatches` + `importCargoLock` `pkgs.harmonia` builds;
  ghostgate/citadel/brass toplevels build.
- Live: `curl -sD- https://cache.nixos.lv/<hash>.narinfo` for a store-absent,
  upstream-present hash → `302` with `Location: https://cache.nixos.org/...`;
  `nix path-info` shows the path arriving in the store shortly after (warm);
  a second request is served `200` by harmonia; prometheus `harmonia_warms_*`
  counters advance. `https://upstream.cache.nixos.lv` no longer resolves
  onsite. A real `nix copy --from https://cache.nixos.lv <store-absent path>`
  succeeds (client follows the 302s to upstream).

## Out of scope

- Blocking-mode / inline-download substitution; warm retry/backoff.

## Estimate

5 points: patch 3, nginx + decommission 1, wiring/verification 1. (The
cargoHash risk resolved via importCargoLock; the redirect design removed the
nginx-upstream complexity entirely.)
