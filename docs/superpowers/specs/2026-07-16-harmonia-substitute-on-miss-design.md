# harmonia substitute-on-miss (async warm) + cache.nixos.lv fall-through

**Date:** 2026-07-16
**Status:** approved (design agreed in-session; async-warm variant chosen)

## Purpose

`cache.nixos.lv` (harmonia over ghostgate's dedup+zstd store) currently 404s
any path not already in the store. Two cooperating changes give it
pull-through semantics without ever blocking a client:

1. **nginx fall-through (serve it now):** on a harmonia 404, nginx retries
   the request against `upstream.cache.nixos.lv` (the loopback-pinned mirror
   vhost), so the client is served from the mirror dataset or cache.nixos.org.
2. **harmonia async warm (own it next time):** a patched harmonia notices
   the miss and asks the **nix daemon** to `EnsurePath` the full store path
   in the background. The daemon substitutes through its configured chain
   (mirror at 35 → cache.nixos.org at 40), the path lands in the dedup
   store — the study-winning archive — and harmonia serves it locally from
   the next request on.

The request that misses still returns 404 (the nginx layer hides that from
clients); harmonia never proxies bytes and never blocks on downloads.

## Component 1: harmonia patch (`substitute-on-miss`)

Grounded in harmonia 3.1.0 source:

- **Trigger:** `harmonia-cache/src/narinfo.rs` `get()` — the
  `some_or_404!(query_path_info_by_hash_part(...))` at line ~208 is the sole
  miss site. NAR requests need no handling (clients fetch narinfo first; by
  the time a warmed path's NAR is requested, it's local).
- **Hash-part resolution:** `EnsurePath` needs a full store path; the client
  only sends the 32-char hash part. On miss, HTTP GET
  `<resolver>/<hashpart>.narinfo` (config value; on ghostgate the loopback
  mirror URL) and parse its `StorePath:` field. HTTP client: prefer a crate
  already in harmonia's dependency tree (check `Cargo.lock` — actix's `awc`
  is the likely zero-new-dep option); a new dep is acceptable but costs a
  `Cargo.lock` change carried in the patch.
- **Warm:** spawn a background task calling `ensure_path` via
  `harmonia-store-remote` (`client.rs:714`) **against the real nix-daemon
  socket** (`/nix/var/nix/daemon-socket/socket`) — NOT harmonia-daemon,
  which is a plain store server and does not substitute. The daemon enforces
  signatures/trusted keys as it does for any substitution.
- **Herd control:** a process-global in-flight set (hash part keyed);
  concurrent misses for the same path trigger one warm. Entries clear on
  task completion (success or failure). Failures are logged, not retried
  (the next miss retries naturally).
- **Config (harmonia TOML, via `services.harmonia.settings`):**
  - `substitute_on_miss = false` (default; feature off = current behavior)
  - `miss_resolver_url = "https://..."` (required when enabled)
  - `miss_daemon_socket = "/nix/var/nix/daemon-socket/socket"` (default)
- **Observability:** counters in the existing `prometheus.rs` registry:
  `narinfo_misses_total`, `warms_started_total`, `warms_completed_total`,
  `warms_failed_total`.
- **Response semantics unchanged:** miss still returns 404 immediately.

**Carrying the patch:** `pkgs/harmonia/substitute-on-miss.patch` in the
systems repo, applied via `overrideAttrs` in the overlay (staticgen
precedent). If `Cargo.lock` changes, override `cargoDeps`/`cargoHash`
accordingly. Intended for an upstream PR to nix-community/harmonia after the
event.

## Component 2: ghostgate nginx fall-through

In the `cache.nixos.lv` vhost:

- `locations."/"`: keep `proxyPass` to harmonia; add
  `proxy_intercept_errors on; error_page 404 = @fallthrough;`
- `locations."@fallthrough"`: `proxyPass https://upstream.cache.nixos.lv`
  (loopback hop into the mirror vhost — reuses its dataset `try_files`,
  `proxy_store`, and upstream TLS stack) with `proxy_ssl_server_name on;
  proxy_ssl_name upstream.cache.nixos.lv;`.

Safe to unify: harmonia NAR URLs (`nar/<hash>.nar…`) and upstream NAR URLs
(`nar/<filehash>.nar.xz`) don't collide, and narinfo bytes stay
correctly-signed from whichever layer serves them.

## Component 3: ghostgate harmonia settings

```nix
services.harmonia.settings = {
  enable_compression = false;         # existing
  substitute_on_miss = true;
  miss_resolver_url = "https://upstream.cache.nixos.lv";
};
```

(Resolver resolves to loopback via the existing /etc/hosts pin.)

## Dependency / lifecycle notes

- **`ghostgate-nar` dataset fate:** the fall-through and resolver both point
  at the mirror vhost, which currently fronts the dataset. If/when the
  dataset is destroyed post-study, the mirror vhost must first be reworked
  to a pure passthrough (drop `root`/`try_files`/`proxy_store`, keep the
  upstream proxy). That rework is out of scope here but is a prerequisite to
  destroying the pool without breaking this feature.
- The warm path deliberately reuses the nix daemon's substituters — no URLs
  are duplicated into harmonia config beyond the resolver.

## Error handling

- Resolver 404 (path exists nowhere): no warm, client's nginx fall-through
  also 404s upstream — correct.
- Resolver unreachable / daemon error: log + `warms_failed_total`; request
  path unaffected (already 404'd).
- Duplicate misses during a long warm: coalesced by the in-flight set.
- Daemon substitution failure (no substituter has it, sig rejected): logged;
  store unchanged.

## Testing

- Rust: unit test the narinfo `StorePath:` parse; integration test with a
  scratch store + a fake resolver (serve a canned narinfo) asserting a miss
  triggers exactly one `EnsurePath` per hash under concurrent requests, and
  that the endpoint still 404s.
- Build: overlay-patched `pkgs.harmonia` builds; ghostgate toplevel builds.
- Live (post-deploy): request a hash absent from the store but present
  upstream via `curl https://cache.nixos.lv/<hash>.narinfo` → first request
  404s-but-serves via fall-through (200 at the client), store gains the path
  (`nix path-info /nix/store/<hash>-*`), second request served by harmonia
  (check `x`-less response headers / harmonia logs); prometheus counters
  advance.

## Out of scope

- Blocking-mode substitution.
- NAR-endpoint warming.
- Retry/backoff policy for failed warms.
- The mirror-vhost passthrough rework (tracked as the dataset-destruction
  prerequisite above).

## Estimate

5 points: patch 3 (risk 5 if a new HTTP dep forces cargoHash surgery),
nginx 1, wiring/verification 1.
