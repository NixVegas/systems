# nar mirror + harmonia storage study — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up an nginx pull-through mirror of cache.nixos.org storing verbatim nar/narinfo on `ghostgate-nar/local/nar`, and serve harmonia without zstd, per `docs/superpowers/specs/2026-07-14-nar-mirror-study-design.md`.

**Architecture:** One new nginx vhost (`upstream.cache.nixos.lv`) does `try_files` against the ZFS dataset mounted at `/var/cache/nar` and falls back to a `proxy_store` proxy of `https://cache.nixos.org`. Harmonia keeps serving the local store at `cache.nixos.lv` with on-the-fly zstd disabled. MeshOS's ncps cache server is disabled on ghostgate (it fights nginx for :443) and ghostgate's substituters point at the mirror. DNS/ingress: one knot CNAME, one brass `onsiteBackends` entry.

**Tech Stack:** NixOS (nixpkgs 26.05 pin), nginx `proxy_store`, ZFS legacy mounts, harmonia 3.1.0, knot (build-time kzonecheck), deploy-rs.

## Global Constraints

- Repo: `/home/numinit/systems`, branch `feat/ctf-ingress`. NixOS configs; no unit-test framework — verification is `nix eval`/`nix build` (kzonecheck runs inside the zone build) plus post-deploy curls.
- **Commits must be unsigned in-session**: always `git commit --no-gpg-sign` (signing needs a YubiKey touch and will hang). The user re-signs before push.
- Exact names: mirror vhost `upstream.cache.nixos.lv`; harmonia endpoint `cache.nixos.lv` (existing, do not rename); dataset `ghostgate-nar/local/nar` mounted at `/var/cache/nar`.
- knot zone-file comments are `;` — never `#` (a `#` line kills the zone load; kzonecheck in the build catches it).
- Only ghostgate's substituters change. Do NOT touch the 2420s, onboarding defaults, builders, or the `mesh.nix` plan entry for ghostgate's cache server (the 2420s' `cnl` set reads it).
- `nix eval`/`nix build` on the dirty tree works directly (`nix eval .#nixosConfigurations...`); expect a "dirty tree" warning, it's harmless.

---

### Task 1: ZFS mount + nginx write access (storage plumbing)

**Files:**
- Modify: `devices/ghostgate/default.nix` (top-level, after the `users = {...};` block that defines `tftpd`, currently around line 975)

**Interfaces:**
- Produces: `/var/cache/nar` (nginx-owned, mounted from `ghostgate-nar/local/nar`) and `/var/cache/nar/tmp`, writable by the nginx unit. Task 2's vhost depends on these paths and on the nginx unit overrides.

- [ ] **Step 1: Add the storage block**

In `devices/ghostgate/default.nix`, directly after the `users = { ... };` block (the one defining `tftpd`), insert:

```nix
  # Storage-study mirror dataset (see
  # docs/superpowers/specs/2026-07-14-nar-mirror-study-design.md): verbatim
  # cache.nixos.org nar/narinfo files, written by nginx proxy_store. The pool
  # and dataset (mountpoint=legacy) are created by hand.
  fileSystems."/var/cache/nar" = {
    device = "ghostgate-nar/local/nar";
    fsType = "zfs";
  };

  systemd.tmpfiles.rules = [
    "d /var/cache/nar 0755 nginx nginx -"
    # proxy_temp_path: must be on the same filesystem as the store root so
    # completed downloads move into place with an atomic rename.
    "d /var/cache/nar/tmp 0700 nginx nginx -"
  ];

  systemd.services.nginx = {
    # The NixOS nginx unit runs ProtectSystem=strict; proxy_store can't write
    # outside /var/cache/nginx without this.
    serviceConfig.ReadWritePaths = [ "/var/cache/nar" ];
    # Don't let nginx start against the bare mountpoint directory.
    unitConfig.RequiresMountsFor = [ "/var/cache/nar" ];
  };
```

- [ ] **Step 2: Verify by eval**

Run:
```bash
cd /home/numinit/systems
nix eval .#nixosConfigurations.ghostgate.config.fileSystems.\"/var/cache/nar\".device
nix eval .#nixosConfigurations.ghostgate.config.systemd.services.nginx.serviceConfig.ReadWritePaths
```
Expected: `"ghostgate-nar/local/nar"` and a list containing `"/var/cache/nar"`.

- [ ] **Step 3: Commit**

```bash
git add devices/ghostgate/default.nix
git commit --no-gpg-sign -m "ghostgate: mount ghostgate-nar/local/nar for the nar mirror"
```

---

### Task 2: nginx mirror vhost `upstream.cache.nixos.lv`

**Files:**
- Modify: `devices/ghostgate/default.nix` — inside `services.nginx.virtualHosts` (currently around line 930), after the `"cache.nix.vegas"` vhost.

**Interfaces:**
- Consumes: `/var/cache/nar` + `/var/cache/nar/tmp` from Task 1.
- Produces: `https://upstream.cache.nixos.lv` serving stored files first, populating the dataset on miss. Tasks 4 (substituters), 5 (knot), 6 (brass) reference this exact hostname.

- [ ] **Step 1: Add the vhost**

Inside `services.nginx.virtualHosts`, after the `"cache.nix.vegas"` entry, add:

```nix
        # Pull-through mirror of cache.nixos.org for the nixpkgs storage study:
        # serve from the ghostgate-nar dataset if present, otherwise proxy
        # upstream and proxy_store the response verbatim (URL path == file
        # path, bytes == upstream bytes, signatures survive). No eviction by
        # design. cache.nixos.lv (harmonia, the dedup'd local store) is the
        # other half of the experiment.
        "upstream.cache.nixos.lv" = {
          http2 = true;
          enableACME = true;
          forceSSL = true;
          root = "/var/cache/nar";
          locations."/".tryFiles = "$uri @upstream";
          locations."@upstream" = {
            proxyPass = "https://cache.nixos.org";
            extraConfig = ''
              proxy_set_header Host cache.nixos.org;
              proxy_ssl_server_name on;
              proxy_ssl_name cache.nixos.org;
              proxy_ssl_verify on;
              proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
              # Upstream a HEAD as a GET so proxy_store never plants an
              # empty file where a narinfo should be.
              proxy_method GET;
              proxy_store on;
              proxy_store_access user:rw group:r all:r;
              proxy_temp_path /var/cache/nar/tmp;
              # Some nars exceed the 1g default; a truncated temp file is
              # discarded instead of stored.
              proxy_max_temp_file_size 32g;
            '';
          };
        };
```

- [ ] **Step 2: Verify by eval**

```bash
nix eval --raw .#nixosConfigurations.ghostgate.config.services.nginx.virtualHosts.\"upstream.cache.nixos.lv\".locations.\"@upstream\".proxyPass
```
Expected: `https://cache.nixos.org`

- [ ] **Step 3: Commit**

```bash
git add devices/ghostgate/default.nix
git commit --no-gpg-sign -m "ghostgate: upstream.cache.nixos.lv proxy_store mirror of cache.nixos.org"
```

---

### Task 3: harmonia without zstd

**Files:**
- Modify: `devices/ghostgate/default.nix` — the `services.harmonia` block (currently around line 983).

**Interfaces:**
- Produces: harmonia serving raw NARs (no `Content-Encoding: zstd`) on `localhost:5000`, unchanged endpoint `cache.nixos.lv`.

- [ ] **Step 1: Replace the harmonia block**

```nix
  services.harmonia = {
    enable = true;
    settings = {
      # Serve raw NARs: harmonia 3.x otherwise zstd-encodes on the fly for
      # Accept-Encoding: zstd clients. The study serves the dedup'd store as-is.
      enable_compression = false;
    };
  };
```

- [ ] **Step 2: Verify by eval**

```bash
nix eval .#nixosConfigurations.ghostgate.config.services.harmonia.settings.enable_compression
```
Expected: `false`

- [ ] **Step 3: Commit**

```bash
git add devices/ghostgate/default.nix
git commit --no-gpg-sign -m "ghostgate: disable harmonia on-the-fly zstd"
```

---

### Task 4: drop ncps, point ghostgate at the mirror

**Files:**
- Modify: `devices/ghostgate/default.nix` — the `networking.mesh.cache` block (currently around lines 112–122), and a new `nix.settings` line next to it.

**Interfaces:**
- Consumes: hostname `upstream.cache.nixos.lv` (Task 2).
- Produces: ghostgate substituters = gvh mirrors + `https://upstream.cache.nixos.lv`; `services.ncps.enable = false` (ends the ncps-vs-nginx :443 fight).

- [ ] **Step 1: Edit the mesh cache block**

Change `networking.mesh.cache` to:

```nix
    cache = {
      # ncps used to serve here and fought nginx for :443; nginx now owns the
      # cache endpoints (cache.nixos.lv -> harmonia, upstream.cache.nixos.lv ->
      # the study mirror). The mesh.nix plan entry stays: the 2420s' cnl set
      # reads it to find https://cache.nixos.lv:443.
      server = {
        enable = false;
      };
      client = {
        enable = true;
        useHydra = false;
        trustHydra = true;
        useRecommendedCacheSettings = true;
      };
    };
```

- [ ] **Step 2: Add the mirror substituter**

Immediately after the `networking.mesh = { ... };` top-level block, add:

```nix
  # Everything ghostgate substitutes from upstream flows through the mirror,
  # populating the study dataset. Priorities do the routing: gvh mirrors pin
  # 10/20 in their URLs, the mirror pins 35 here, and the direct
  # https://cache.nixos.org/ that nixpkgs' nix module unconditionally appends
  # sits at 40 — so it is only ever a fallback when the mirror itself is down.
  nix.settings.substituters = lib.mkAfter [ "https://upstream.cache.nixos.lv?priority=35" ];
```

> **Deviation note (found during execution):** nixpkgs' `nixos/modules/config/nix.nix`
> unconditionally appends `https://cache.nixos.org/` via `mkAfter`; MeshOS's
> `mkForce` used to mask it. It cannot be removed without `mkForce`ing the
> whole list, so instead the mirror pins `?priority=35` to outrank it (mirror
> nix-cache-info is upstream's verbatim 40, which would tie and lose on list
> order). Direct upstream remains as fallback only.

- [ ] **Step 3: Verify by eval**

```bash
nix eval --json .#nixosConfigurations.ghostgate.config.nix.settings.substituters
nix eval .#nixosConfigurations.ghostgate.config.services.ncps.enable
```
Expected: JSON list **containing** `https://upstream.cache.nixos.lv?priority=35`, **not containing** `https://cache.nixos.lv:443` or `https://cache.nixos.org?priority=10`; a plain `https://cache.nixos.org/` entry is expected (nixpkgs default, outranked by the mirror's 35); gvh `http://10.6.9.x:5000` URLs and cachix entries are fine. ncps eval: `false`.

- [ ] **Step 4: Commit**

```bash
git add devices/ghostgate/default.nix
git commit --no-gpg-sign -m "ghostgate: retire ncps, substitute via the nar mirror"
```

---

### Task 5: knot CNAME for the mirror

**Files:**
- Modify: `devices/ghostgate/default.nix` — `zoneText` inside the `services.knot = erlib.mkKnot { ... }` block (currently around line 846).

**Interfaces:**
- Produces: onsite resolution of `upstream.cache.nixos.lv` → ghostgate.

- [ ] **Step 1: Add the record**

In `zoneText`, directly under the `cache.${baseDomain}. CNAME ghostgate.${domain}.` line, add:

```nix
        upstream.cache.${baseDomain}. CNAME ghostgate.${domain}.
```

(Reminder: `;` for any comment — never `#`.)

- [ ] **Step 2: Verify — build the zone (runs kzonecheck) and grep it**

```bash
Z=$(nix build --no-link --print-out-paths --impure --expr '(builtins.getFlake "git+file:///home/numinit/systems").nixosConfigurations.ghostgate.config.services.knot.settings.template.default.storage')
grep '^upstream' "$Z/nixos.lv.zone"
```
Expected: build succeeds (kzonecheck passes) and prints `upstream.cache.nixos.lv. CNAME ghostgate.dc.nixos.lv.`

- [ ] **Step 3: Commit**

```bash
git add devices/ghostgate/default.nix
git commit --no-gpg-sign -m "ghostgate: resolve upstream.cache.nixos.lv onsite"
```

---

### Task 6: brass onsite ingress for ACME

**Files:**
- Modify: `devices/brass/default.nix` — the `onsiteBackends` attrset in the `let` block (currently lines 37–44).

**Interfaces:**
- Produces: brass 302s public hits on `upstream.cache.nixos.lv` to nix.vegas and forwards unowned ACME tokens to ghostgate, so ghostgate's onsite cert issues.

- [ ] **Step 1: Add the backend**

In `onsiteBackends`, after the `"cache.nix.vegas" = ghostgateNebula;` line:

```nix
    "upstream.cache.nixos.lv" = ghostgateNebula;
```

- [ ] **Step 2: Verify by eval**

```bash
nix eval --raw .#nixosConfigurations.brass.config.services.nginx.virtualHosts.\"upstream.cache.nixos.lv\".acmeFallbackHost
```
Expected: ghostgate's Nebula address, `10.6.7.1`.

- [ ] **Step 3: Commit**

```bash
git add devices/brass/default.nix
git commit --no-gpg-sign -m "brass: onsite-only ingress for upstream.cache.nixos.lv"
```

---

### Task 7: docs + full builds

**Files:**
- Modify: `docs/event-network.md` — the "Public ingress on brass" onsite-name list (item 2), the "Split-horizon DNS" section, and "Deploy dependencies".

**Interfaces:**
- Consumes: everything above; final gate before deploy.

- [ ] **Step 1: Update docs**

In `docs/event-network.md`:

1. In the ingress section's **Onsite-only** list, add `upstream.cache.nixos.lv` to the parenthesized names.
2. In **Split-horizon DNS**, after the bullet about ghostgate's knot zone static records, add:

```markdown
- `upstream.cache.nixos.lv` (ghostgate's knot zone, CNAME → ghostgate) is the
  nginx pull-through mirror of cache.nixos.org for the nixpkgs storage study:
  `try_files` on the `ghostgate-nar/local/nar` dataset (mounted at
  `/var/cache/nar`), miss → `proxy_store` from upstream, bytes verbatim, no
  eviction. `cache.nixos.lv` stays harmonia over the dedup+zstd local store
  (compression off). Only ghostgate substitutes through the mirror.
```

3. In **Deploy dependencies**, add to the public-DNS bullet's name list: `upstream.cache.nixos.lv`.

- [ ] **Step 2: Full builds of both changed hosts**

```bash
nix build --no-link .#nixosConfigurations.ghostgate.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.brass.config.system.build.toplevel
```
Expected: both succeed (this exercises kzonecheck, nginx config generation, harmonia settings serialization, and the MeshOS module changes).

- [ ] **Step 3: Commit**

```bash
git add docs/event-network.md
git commit --no-gpg-sign -m "docs: event-network: nar mirror + storage study"
```

---

### Task 8: deploy + live verification (operator; needs YubiKey + public DNS)

**Files:** none (operational).

- [ ] **Step 1: Public DNS (manual, external):** add `upstream.cache.nixos.lv A 185.193.48.248` (brass) wherever nixos.lv's public DNS lives.

- [ ] **Step 2: Deploy** (order: ghostgate → brass):

```bash
deploy --hostname 10.4.0.1 .#ghostgate   # by IP if names are stale
deploy .#brass
```

- [ ] **Step 3: Set the safety quota** (on ghostgate):

```bash
zfs set quota=3.6T ghostgate-nar/local/nar
```

- [ ] **Step 4: Verify the mirror end-to-end** (from the noc LAN):

```bash
curl -s https://upstream.cache.nixos.lv/nix-cache-info          # populates
curl -s https://cache.nixos.org/nix-cache-info | cmp - <(ssh ghostgate 'cat /var/cache/nar/nix-cache-info')
nix copy --from https://upstream.cache.nixos.lv --to ./tmpstore $(nix eval --raw nixpkgs#hello.outPath)
```
Expected: `cmp` silent (byte-identical); the copy succeeds and `<hash>.narinfo` + `nar/*.nar.xz` appear under `/var/cache/nar`.

- [ ] **Step 5: Verify harmonia is raw**:

```bash
curl -sv -H 'Accept-Encoding: zstd' https://cache.nixos.lv/nix-cache-info 2>&1 | grep -i content-encoding
```
Expected: no `content-encoding: zstd`.

- [ ] **Step 6: Study measurement commands** (for the write-up):

```bash
zfs get -p used,logicalused,compressratio ghostgate/local/nix ghostgate-nar/local/nar
zpool list -o name,size,alloc,cap,dedupratio ghostgate ghostgate-nar
```
