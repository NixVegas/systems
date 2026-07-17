# harmonia substitute-on-miss (async warm) + mirror decommission

**Date:** 2026-07-16 (v2 — direct-from-upstream, mirror teardown)
**Status:** approved

## Purpose

The storage study is concluded: the dedup+zstd store beats storing upstream
xz NARs (~10% net savings once overheads are counted), so the
`upstream.cache.nixos.lv` pull-through mirror and its dataset are being
decommissioned. `cache.nixos.lv` (harmonia over the store) becomes the one
event cache, with pull-through semantics implemented as:

1. **nginx fall-through (serve it now):** harmonia 404 → nginx retries the
   request directly against `https://cache.nixos.org` (pure proxy, nothing
   stored).
2. **harmonia async warm (own it next time):** patched harmonia resolves the
   missed hash part against `https://cache.nixos.org`, then asks the nix
   daemon to `EnsurePath` the full path in the background. The daemon
   substitutes from its configured chain (now just cache.nixos.org), the
   path lands in the dedup store, and harmonia serves it locally thereafter.

Misses still return 404 from harmonia itself; nginx hides that from
clients. Harmonia never proxies NAR bytes and never blocks on downloads.

## Component 1: harmonia patch (`substitute-on-miss`)

Grounded in harmonia 3.1.0 source:

- **Trigger:** `harmonia-cache/src/narinfo.rs` `get()` — the
  `some_or_404!(query_path_info_by_hash_part(...))` at line ~208 is the sole
  miss site. NAR requests need no handling (clients fetch narinfo first; a
  warmed path's NAR is local by the time it's requested).
- **Hash-part resolution:** `EnsurePath` needs a full store path; the client
  sends only the 32-char hash part. On miss, HTTP GET
  `<miss_resolver_url>/<hashpart>.narinfo` (ghostgate: cache.nixos.org) and
  parse its `StorePath:` field. HTTP client: prefer a crate already in
  harmonia's `Cargo.lock` (actix's `awc` is the likely zero-new-dep option);
  a new dep is acceptable but the patch then carries the `Cargo.lock` delta.
- **Warm:** background task calling `ensure_path` via
  `harmonia-store-remote` (`client.rs:714`) against the **real nix-daemon
  socket** (`/nix/var/nix/daemon-socket/socket`) — not harmonia-daemon,
  which does not substitute. Signature/trusted-key enforcement is the
  daemon's, as for any substitution.
- **Herd control:** process-global in-flight set keyed by hash part; one
  warm per path regardless of concurrent misses; entries clear on task
  completion. Failures logged, not retried (the next miss retries).
- **Config (harmonia TOML via `services.harmonia.settings`):**
  - `substitute_on_miss = false` (default off = current behavior)
  - `miss_resolver_url` (required when enabled)
  - `miss_daemon_socket = "/nix/var/nix/daemon-socket/socket"` (default)
- **Observability:** counters in the existing `prometheus.rs` registry:
  `narinfo_misses_total`, `warms_started_total`, `warms_completed_total`,
  `warms_failed_total`.

**Carrying the patch:** `pkgs/harmonia/substitute-on-miss.patch` in the
systems repo, applied via `overrideAttrs` in the overlay (staticgen
precedent); override `cargoDeps`/`cargoHash` if `Cargo.lock` changes.
Intended for an upstream PR to nix-community/harmonia after the event.

## Component 2: ghostgate nginx — fall-through, direct to upstream

In the `cache.nixos.lv` vhost:

- `locations."/"`: keep `proxyPass` to harmonia; add
  `proxy_intercept_errors on; error_page 404 = @fallthrough;`
- `locations."@fallthrough"`: direct proxy to `https://cache.nixos.org`,
  reusing the hard-won mirror lessons but with **no proxy_store**:
  - `resolver 127.0.0.1 ipv6=off valid=300s;` + variable proxy_pass
    (`set $ft_upstream cache.nixos.org; proxy_pass
    https://$ft_upstream$request_uri;`) — runtime re-resolution, v4-only
    (nginx otherwise builds an all-AAAA list and 502s without a v6 route).
  - `proxy_set_header Host cache.nixos.org; proxy_ssl_server_name on;
    proxy_ssl_name cache.nixos.org; proxy_ssl_verify on;
    proxy_ssl_verify_depth 4;` (LE 2026 chain exceeds the default depth of
    1) `proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;`

URL namespaces don't collide (harmonia `nar/<hash>.nar…` vs upstream
`nar/<filehash>.nar.xz`); narinfo bytes stay correctly signed from either
layer.

## Component 3: ghostgate harmonia settings

```nix
services.harmonia.settings = {
  enable_compression = false;              # existing
  substitute_on_miss = true;
  miss_resolver_url = "https://cache.nixos.org";
};
```

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

- Resolver 404 (path exists nowhere): no warm; the client's fall-through
  404s too — correct.
- Resolver unreachable / daemon error: log + `warms_failed_total`; request
  path unaffected.
- Duplicate misses during a long warm: coalesced by the in-flight set.
- Daemon substitution failure (nothing has the path, sig rejected): logged;
  store unchanged.

## Testing

- Rust: unit test the `StorePath:` parse; integration test with a scratch
  store + canned-narinfo resolver asserting one `EnsurePath` per hash under
  concurrent misses, and that the endpoint still 404s.
- Build: overlay-patched `pkgs.harmonia` builds; ghostgate/citadel/brass
  toplevels build.
- Live: `curl https://cache.nixos.lv/<hash>.narinfo` for a store-absent,
  upstream-present hash → 200 (via fall-through); `nix path-info` shows the
  path arriving in the store shortly after; second request served by
  harmonia; prometheus counters advance. `https://upstream.cache.nixos.lv`
  no longer resolves onsite.

## Out of scope

- Blocking-mode substitution; NAR-endpoint warming; warm retry/backoff.

## Estimate

5 points: patch 3 (5 if cargoHash surgery), nginx + decommission 1,
wiring/verification 1.
