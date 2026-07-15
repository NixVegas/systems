# nar mirror + harmonia: nixpkgs storage study on ghostgate

**Date:** 2026-07-14
**Status:** approved

## Purpose

Measure, with hard numbers, how ZFS dedup+zstd on a live Nix store compares
against cache.nixos.org's native xz-compressed NARs for storing a full build
of nixpkgs. ghostgate has 2×4TB Samsung NVMe: pool `ghostgate` (existing;
`ghostgate/local/nix` is the dedup+zstd store) and pool `ghostgate-nar` (the
experiment pool). Both get populated in one ingest pass; whichever loses gets
destroyed. The numbers double as a public data point for the NixOS Foundation
on real storage cost of a nixpkgs build.

Two serving endpoints fall out of this:

- `upstream.cache.nixos.lv` — nginx pull-through mirror of
  `https://cache.nixos.org`, storing narinfo/nar **byte-identical** on
  `ghostgate-nar/local/nar` (upstream signatures survive verbatim).
- `cache.nixos.lv` — harmonia serving ghostgate's own `/nix/store`
  (dedup+zstd dataset), **without** on-the-fly zstd. Existing endpoint,
  existing consumers, unchanged semantics.

Only ghostgate's own substituters change. The 2420s, onboarding images,
builders, and brass consumers are untouched.

## Components

### 1. ZFS (devices/ghostgate)

- `fileSystems."/var/cache/nar" = { device = "ghostgate-nar/local/nar";
  fsType = "zfs"; }` — legacy mountpoint, matching the fleet convention
  (cf. `onepunch/local/cache` on saitama). NixOS derives the pool import
  from the entry.
- `boot.supportedFilesystems = [ "zfs" ]`. `networking.hostId` already comes
  from `modules/net.nix` (mkDefault), no new identity config.
- tmpfiles rules: `/var/cache/nar` and `/var/cache/nar/tmp` owned by
  `nginx:nginx`. `proxy_store` writes as the nginx worker;
  `proxy_temp_path` must be on the same filesystem so stores are atomic
  renames, not cross-device copies.
- Operational (manual, not in repo): pool + dataset created by hand;
  recommend `zfs set quota=3.6T ghostgate-nar/local/nar` so a runaway
  ingest can't wedge the pool — there is deliberately no eviction.

### 2. Mirror vhost (devices/ghostgate nginx)

`upstream.cache.nixos.lv`, `enableACME` + `forceSSL` + http2, same shape as
`cache.nixos.lv`:

- `root /var/cache/nar;`
- `location / { try_files $uri @upstream; }`
- `location @upstream`:
  - `proxy_pass https://cache.nixos.org;` with `Host: cache.nixos.org`,
    `proxy_ssl_server_name on`, `proxy_ssl_verify on` against the system CA
    bundle.
  - `proxy_store on; proxy_store_access user:rw group:r all:r;`
  - `proxy_temp_path /var/cache/nar/tmp;`

Properties:

- Stored bytes are exactly upstream's bytes: `nar/<hash>.nar.xz`,
  `<hash>.narinfo`, `nix-cache-info` (Priority 40, WantMassQuery 1) mirror
  verbatim; cache.nixos.org signatures remain valid everywhere.
- Only complete 200 GET responses are stored. 404s and HEADs proxy through
  unstored (no negative caching — acceptable; ghostgate is the only client).
- Serves from disk even if the uplink is down.
- Known limitation: nginx resolves cache.nixos.org (Fastly) once at
  startup/reload. Acceptable; a `resolver` + variable upstream is the fix if
  it ever bites.

### 3. Harmonia (devices/ghostgate)

- `services.harmonia.settings.enable_compression = false;` — harmonia 3.1.0
  otherwise zstd-encodes NARs on the fly for `Accept-Encoding: zstd`
  clients.
- Stays on `localhost:5000` behind the existing `cache.nixos.lv` vhost.
- Signatures unchanged from today: substituted paths re-serve their
  cache.nixos.org sigs from the store db; locally-built paths are unsigned.

### 4. MeshOS / substituters (ghostgate only)

- `networking.mesh.cache.server.enable = false;` — removes ncps, which
  currently fights nginx for :443, and removes the `mkForce` substituter
  that pointed ghostgate at its own harmonia (a no-op loop).
- Cache client stays enabled: ghostgate keeps the gvh-a/gvh-b hydra-mirror
  substituters (saitama/bigzam), `useHydra = false` as today.
- Add `nix.settings.substituters = mkAfter [ "https://upstream.cache.nixos.lv" ]`.
  Effective query order comes from nix-cache-info priorities: gvh harmonia
  (30) before the mirror (40).
- The `mesh.nix` plan entry for ghostgate's cache server **stays** — it is
  static plan data the 2420s' `cnl` client set reads to get
  `https://cache.nixos.lv:443`, which nginx keeps serving.

### 5. DNS + ingress

- knot zone (`devices/ghostgate`): `upstream.cache.nixos.lv. CNAME
  ghostgate.dc.nixos.lv.` (build-time kzonecheck guards the zone).
- brass: add `upstream.cache.nixos.lv` to `onsiteBackends` (public gets the
  302-to-nix.vegas treatment; `acmeFallbackHost` keeps ghostgate's onsite
  cert issuing).
- **Manual deploy dependency:** public DNS record
  `upstream.cache.nixos.lv → 185.193.48.248` (brass), like the other onsite
  names. ACME issuance on ghostgate depends on it.

### 6. Running the experiment (operational)

- Populate both pools in one pass: mass-realise/`nix copy` with
  `--option substituters https://upstream.cache.nixos.lv` — each path lands
  xz-verbatim on `ghostgate-nar` and unpacks into the dedup+zstd store on
  `ghostgate`.
- Measure:
  - `zfs get -p used,logicalused,compressratio ghostgate/local/nix ghostgate-nar/local/nar`
  - `zpool list -o name,size,alloc,dedupratio ghostgate`
  - `logicalused` is the normalizer for the apples-to-apples comparison.

## Error handling

- Upstream down: mirror serves stored files; misses return upstream errors
  to nix, which falls back per its substituter list.
- Partial upstream responses: `proxy_store` only persists complete
  responses; truncated transfers are discarded with the temp file.
- Disk full: writes fail, nginx logs and returns the proxied response
  un-stored; the ZFS quota keeps the pool itself healthy.

## Testing

- `nix build` of ghostgate + brass toplevels (kzonecheck runs in-build).
- Post-deploy: `curl https://upstream.cache.nixos.lv/nix-cache-info` twice —
  first populates, second serves from disk (confirm file exists on the
  dataset, byte-identical to upstream via `curl https://cache.nixos.org/nix-cache-info | cmp`).
- One real path: `nix copy` a small store path via the mirror; verify
  `.narinfo` + `.nar.xz` land under `/var/cache/nar` and `nix store verify`
  accepts the path.
- `curl -H 'Accept-Encoding: zstd' https://cache.nixos.lv/nix-cache-info -v`
  shows no `Content-Encoding: zstd` after the harmonia change.

## Out of scope

- Fleet substituter changes (2420s, onboarding, builders).
- Signing key for harmonia.
- Eviction/retention policy on the mirror (deliberately none).
- The mass-ingest driver script and the final report.
