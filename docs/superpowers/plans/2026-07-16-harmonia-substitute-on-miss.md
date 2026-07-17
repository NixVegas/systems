# harmonia substitute-on-miss + mirror decommission — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Patch harmonia to asynchronously warm missed store paths via the nix daemon, add an nginx 404 fall-through on cache.nixos.lv straight to cache.nixos.org, and decommission the upstream mirror, per `docs/superpowers/specs/2026-07-16-harmonia-substitute-on-miss-design.md`.

**Architecture:** A new `miss_warm` module in `harmonia-cache` hooks the single narinfo 404 site: it resolves the hash part to a full store path with a hand-rolled plain-HTTP GET against a localhost nginx listener (nginx owns the upstream TLS), then spawns a background `EnsurePath` over `harmonia-store-remote` against the real nix-daemon socket, coalesced by an in-flight set. The patch rides `services.harmonia.package = pkgs.harmonia.overrideAttrs ...` on ghostgate (NOT the overlay — overlayAttrs self-reference recursion). nginx gains a shared upstream-proxy snippet used by both the client-facing `@fallthrough` and the `127.0.0.1:8137` resolver listener.

**Tech Stack:** Rust (actix-web, tokio, harmonia-store-remote), nginx, NixOS.

## Global Constraints

- Harmonia work tree: `~/projects/harmonia`, clone of `github:nix-community/harmonia` at tag `harmonia-v3.1.0`, branch `substitute-on-miss`. Systems repo on its current branch.
- **Commits unsigned in-session**: `git commit --no-gpg-sign` everywhere.
- **No new external crates.** The resolver client is hand-rolled plain HTTP over `tokio::net::TcpStream` (TLS is nginx's job at the localhost listener); the daemon client is the in-workspace `harmonia-store-remote` (adds a workspace dep edge to `harmonia-cache/Cargo.toml` + `Cargo.lock`, but no vendor-hash change since no external packages are added).
- Config keys, exact: `substitute_on_miss` (bool, default false), `miss_resolver_url` (string, e.g. `http://127.0.0.1:8137`), `miss_daemon_socket` (default `/nix/var/nix/daemon-socket/socket`).
- Metric names, exact: `harmonia_narinfo_misses_total`, `harmonia_warms_started_total`, `harmonia_warms_completed_total`, `harmonia_warms_failed_total`.
- Miss responses stay 404, always. Spec refinement (documented here): the resolver URL is the localhost nginx listener that proxies cache.nixos.org, not cache.nixos.org directly — identical semantics, zero TLS code in harmonia.
- nginx upstream-proxy lessons are mandatory in every upstream-facing block: `resolver 127.0.0.1 ipv6=off valid=300s` + variable proxy_pass; `proxy_ssl_verify_depth 4`; nginx size suffixes are k/m only.

---

### Task 1: harmonia work tree + config knobs

**Files:**
- Create: `~/projects/harmonia` (clone), branch `substitute-on-miss`
- Modify: `~/projects/harmonia/harmonia-cache/src/config.rs` (Config struct ~line 97, defaults nearby)

**Interfaces:**
- Produces: `Config.substitute_on_miss: bool`, `Config.miss_resolver_url: Option<String>`, `Config.miss_daemon_socket: PathBuf` — consumed by Task 2/3.

- [ ] **Step 1: Clone and branch**

```bash
git clone https://github.com/nix-community/harmonia ~/projects/harmonia
cd ~/projects/harmonia && git checkout -b substitute-on-miss harmonia-v3.1.0
nix develop -c cargo check -p harmonia-cache   # baseline compiles
```

- [ ] **Step 2: Add config fields**

In `harmonia-cache/src/config.rs`, next to the other default fns:

```rust
fn default_miss_daemon_socket() -> PathBuf {
    PathBuf::from("/nix/var/nix/daemon-socket/socket")
}
```

In `struct Config`, after `enable_compression`:

```rust
    /// On a narinfo miss, ask the nix daemon to substitute the path in the
    /// background so the next request is served locally.
    #[serde(default)]
    pub(crate) substitute_on_miss: bool,
    /// Plain-HTTP endpoint that answers `<hash>.narinfo` for upstream paths
    /// (typically a localhost reverse proxy of the upstream cache); used to
    /// expand a hash part into a full store path for EnsurePath.
    #[serde(default)]
    pub(crate) miss_resolver_url: Option<String>,
    /// The real nix-daemon socket (harmonia-daemon does not substitute).
    #[serde(default = "default_miss_daemon_socket")]
    pub(crate) miss_daemon_socket: PathBuf,
```

- [ ] **Step 3: Test config parse (add to config.rs tests or a new test)**

```rust
#[test]
fn test_substitute_on_miss_defaults() {
    let c: Config = toml::from_str("bind = \"[::]:5000\"").unwrap();
    assert!(!c.substitute_on_miss);
    assert!(c.miss_resolver_url.is_none());
    assert_eq!(
        c.miss_daemon_socket,
        PathBuf::from("/nix/var/nix/daemon-socket/socket")
    );
}
```

(Adjust construction to however existing config tests build a `Config`; if
none exist, deserialize the minimal TOML the struct requires.)

Run: `nix develop -c cargo test -p harmonia-cache config`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd ~/projects/harmonia
git add harmonia-cache/src/config.rs
git commit --no-gpg-sign -m "harmonia-cache: config knobs for substitute-on-miss"
```

---

### Task 2: metrics counters

**Files:**
- Modify: `~/projects/harmonia/harmonia-cache/src/prometheus.rs` (PrometheusMetrics struct + `new()`)

**Interfaces:**
- Produces: `pub narinfo_misses_total: IntCounter`, `pub warms_started_total: IntCounter`, `pub warms_completed_total: IntCounter`, `pub warms_failed_total: IntCounter` on `PrometheusMetrics` (registered on its registry). Consumed by Task 3.

- [ ] **Step 1: Add counters**

Add `IntCounter` to the `use prometheus::{...}` list. In `PrometheusMetrics`:

```rust
    pub narinfo_misses_total: IntCounter,
    pub warms_started_total: IntCounter,
    pub warms_completed_total: IntCounter,
    pub warms_failed_total: IntCounter,
```

In `new()`, before the registrations:

```rust
        let narinfo_misses_total = IntCounter::new(
            "harmonia_narinfo_misses_total",
            "narinfo requests for paths absent from the local store",
        )?;
        let warms_started_total = IntCounter::new(
            "harmonia_warms_started_total",
            "background substitute-on-miss warms started",
        )?;
        let warms_completed_total = IntCounter::new(
            "harmonia_warms_completed_total",
            "background warms that made the path valid",
        )?;
        let warms_failed_total = IntCounter::new(
            "harmonia_warms_failed_total",
            "background warms that failed (resolver, daemon, or substitution)",
        )?;
```

Register all four (`registry.register(Box::new(x.clone()))?;`) and add them
to the struct literal.

- [ ] **Step 2: Compile + commit**

```bash
nix develop -c cargo check -p harmonia-cache
git add harmonia-cache/src/prometheus.rs
git commit --no-gpg-sign -m "harmonia-cache: substitute-on-miss counters"
```

---

### Task 3: the `miss_warm` module

**Files:**
- Create: `~/projects/harmonia/harmonia-cache/src/miss_warm.rs`
- Modify: `~/projects/harmonia/harmonia-cache/src/main.rs` (add `mod miss_warm;` next to `mod narinfo;` at ~line 35)
- Modify: `~/projects/harmonia/harmonia-cache/Cargo.toml` (add `harmonia-store-remote` to the Nix.rs-based crates block, version matching the workspace member's own `Cargo.toml`)

**Interfaces:**
- Consumes: Task 1 config fields, Task 2 counters, `harmonia_store_remote::DaemonClientBuilder` (`connect_unix`, per the crate's lib.rs doc example), `ensure_path`.
- Produces: `pub(crate) fn maybe_warm(config: &web::Data<Config>, metrics: &web::Data<PrometheusMetrics>, hash: &str)` — fire-and-forget, never blocks, never errors. Consumed by Task 4.

- [ ] **Step 1: Write the module**

```rust
//! Async substitute-on-miss: when a narinfo lookup misses, resolve the hash
//! part to a full store path via a (localhost) resolver endpoint, then ask
//! the real nix daemon to EnsurePath it in the background. The request that
//! missed still gets its 404; the next one is served locally.

use std::collections::HashSet;
use std::path::Path;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use actix_web::web;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::config::Config;
use crate::prometheus::PrometheusMetrics;

/// Hash parts with a warm currently in flight (herd control).
static IN_FLIGHT: LazyLock<Mutex<HashSet<String>>> =
    LazyLock::new(|| Mutex::new(HashSet::new()));

const RESOLVER_TIMEOUT: Duration = Duration::from_secs(15);

pub(crate) fn maybe_warm(
    config: &web::Data<Config>,
    metrics: &web::Data<PrometheusMetrics>,
    hash: &str,
) {
    if !config.substitute_on_miss {
        return;
    }
    metrics.narinfo_misses_total.inc();
    let Some(resolver) = config.miss_resolver_url.clone() else {
        tracing::warn!("substitute_on_miss enabled but miss_resolver_url unset");
        return;
    };
    if !IN_FLIGHT.lock().unwrap().insert(hash.to_string()) {
        return; // already warming
    }
    metrics.warms_started_total.inc();
    let hash = hash.to_string();
    let socket = config.miss_daemon_socket.clone();
    let metrics = metrics.clone();
    tokio::spawn(async move {
        let res = warm(&resolver, &socket, &hash).await;
        IN_FLIGHT.lock().unwrap().remove(&hash);
        match res {
            Ok(path) => {
                tracing::info!("substitute-on-miss: {path} is now valid");
                metrics.warms_completed_total.inc();
            }
            Err(e) => {
                tracing::warn!("substitute-on-miss: {hash}: {e}");
                metrics.warms_failed_total.inc();
            }
        }
    });
}

async fn warm(resolver: &str, socket: &Path, hash: &str) -> Result<String, String> {
    let store_path = resolve_store_path(resolver, hash).await?;

    use harmonia_store_remote::DaemonClientBuilder;
    // Follow the connect/handshake shape from harmonia-store-remote's
    // lib.rs doc example; consume the operation's log stream to completion.
    let mut client = DaemonClientBuilder::new()
        .connect_unix(socket)
        .result()
        .await
        .map_err(|e| format!("daemon connect: {e}"))?;
    client
        .ensure_path(
            &store_path
                .as_str()
                .try_into()
                .map_err(|e| format!("bad store path: {e}"))?,
        )
        .result()
        .await
        .map_err(|e| format!("ensure_path: {e}"))?;
    Ok(store_path)
}

/// Plain-HTTP GET of `<resolver>/<hash>.narinfo`; returns the `StorePath:`
/// field. The resolver is expected to be a localhost reverse proxy — TLS to
/// the real upstream is its problem, not ours.
async fn resolve_store_path(resolver: &str, hash: &str) -> Result<String, String> {
    let stripped = resolver
        .strip_prefix("http://")
        .ok_or_else(|| format!("miss_resolver_url must be http:// (got {resolver})"))?;
    let (authority, base_path) = match stripped.split_once('/') {
        Some((a, p)) => (a, format!("/{p}")),
        None => (stripped, String::new()),
    };
    let addr = if authority.contains(':') {
        authority.to_string()
    } else {
        format!("{authority}:80")
    };

    let body = tokio::time::timeout(RESOLVER_TIMEOUT, async {
        let mut stream = TcpStream::connect(&addr)
            .await
            .map_err(|e| format!("resolver connect {addr}: {e}"))?;
        let req = format!(
            "GET {base_path}/{hash}.narinfo HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\nUser-Agent: harmonia-substitute-on-miss\r\n\r\n"
        );
        stream
            .write_all(req.as_bytes())
            .await
            .map_err(|e| format!("resolver write: {e}"))?;
        let mut buf = Vec::with_capacity(4096);
        stream
            .read_to_end(&mut buf)
            .await
            .map_err(|e| format!("resolver read: {e}"))?;
        Ok::<Vec<u8>, String>(buf)
    })
    .await
    .map_err(|_| "resolver timeout".to_string())??;

    let text = String::from_utf8_lossy(&body);
    let (head, rest) = text
        .split_once("\r\n\r\n")
        .ok_or_else(|| "resolver: malformed HTTP response".to_string())?;
    let status = head.lines().next().unwrap_or_default();
    if !status.contains(" 200 ") {
        return Err(format!("resolver: {status}"));
    }
    parse_store_path(rest)
}

fn parse_store_path(narinfo: &str) -> Result<String, String> {
    narinfo
        .lines()
        .find_map(|l| l.strip_prefix("StorePath: "))
        .map(|s| s.trim().to_string())
        .ok_or_else(|| "resolver: no StorePath field".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_store_path() {
        let ni = "StorePath: /nix/store/abc123-hello-2.12\nURL: nar/x.nar.xz\n";
        assert_eq!(
            parse_store_path(ni).unwrap(),
            "/nix/store/abc123-hello-2.12"
        );
        assert!(parse_store_path("URL: nar/x.nar.xz\n").is_err());
    }

    #[tokio::test]
    async fn test_resolver_roundtrip_and_404() {
        use tokio::io::AsyncWriteExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let (mut sock, _) = listener.accept().await.unwrap();
                let mut buf = [0u8; 1024];
                use tokio::io::AsyncReadExt;
                let n = sock.read(&mut buf).await.unwrap();
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let resp = if req.contains("deadbeef") {
                    "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".to_string()
                } else {
                    "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nStorePath: /nix/store/abc123-x\n"
                        .to_string()
                };
                sock.write_all(resp.as_bytes()).await.unwrap();
            }
        });
        let url = format!("http://{addr}");
        assert_eq!(
            resolve_store_path(&url, "abc123").await.unwrap(),
            "/nix/store/abc123-x"
        );
        assert!(resolve_store_path(&url, "deadbeef").await.is_err());
    }
}
```

(The `DaemonClientBuilder` call chain and the `ensure_path` argument type
must be reconciled against the crate at compile time — the lib.rs doc
example and `client.rs:714` are the references; keep the log-consuming
`.result().await` shape used across their codebase.)

- [ ] **Step 2: Wire the module + dep**

`main.rs`: add `mod miss_warm;` beside `mod narinfo;`.
`harmonia-cache/Cargo.toml`, in the "Nix.rs-based crates" block:
```toml
harmonia-store-remote = { version = "3.0.0" }
```
(match the actual version in `harmonia-store-remote/Cargo.toml`; run
`cargo check` and let cargo update `Cargo.lock` — the delta is an internal
edge only.)

- [ ] **Step 3: Test**

```bash
nix develop -c cargo test -p harmonia-cache miss_warm
```
Expected: 2 tests PASS (parse + roundtrip/404).

- [ ] **Step 4: Commit**

```bash
git add harmonia-cache/src/miss_warm.rs harmonia-cache/src/main.rs harmonia-cache/Cargo.toml Cargo.lock
git commit --no-gpg-sign -m "harmonia-cache: async substitute-on-miss warm module"
```

---

### Task 4: hook the narinfo miss site

**Files:**
- Modify: `~/projects/harmonia/harmonia-cache/src/narinfo.rs` (`get()` ~line 191)

**Interfaces:**
- Consumes: `miss_warm::maybe_warm` (Task 3).

- [ ] **Step 1: Extend the handler**

Add the metrics extractor and replace the `some_or_404!` line:

```rust
pub(crate) async fn get(
    hash: web::Path<String>,
    param: web::Query<Param>,
    settings: web::Data<Config>,
    metrics: web::Data<crate::prometheus::PrometheusMetrics>,
) -> crate::ServerResult {
    ...
    let info = match settings.store.query_path_info_by_hash_part(&hash)? {
        Some(info) => info,
        None => {
            crate::miss_warm::maybe_warm(&settings, &metrics, &hash);
            // Reproduce some_or_404!'s response exactly (read the macro in
            // this file / error.rs and return the identical body/status).
            return Ok(HttpResponse::NotFound()
                .insert_header(crate::cache_control_no_store())
                .body("missed hash"));
        }
    };
```

Check what `some_or_404!` actually expands to (grep `macro_rules!
some_or_404` — likely in `main.rs` or `error.rs`) and mirror its exact
response so behavior for non-warming deployments is bit-identical. If a
`cache_control_no_store` helper doesn't exist, use whatever the macro used.

- [ ] **Step 2: Full crate test + clippy**

```bash
nix develop -c cargo test -p harmonia-cache
nix develop -c cargo clippy -p harmonia-cache -- -D warnings
```
Expected: all green (warms are dormant by default; existing tests unaffected).

- [ ] **Step 3: Commit**

```bash
git add harmonia-cache/src/narinfo.rs
git commit --no-gpg-sign -m "harmonia-cache: trigger async warm on narinfo miss"
```

---

### Task 5: carry the patch in the systems repo

**Files:**
- Create: `/home/numinit/systems/pkgs/harmonia/substitute-on-miss.patch`
- Modify: `/home/numinit/systems/devices/ghostgate/default.nix` (harmonia block ~line 1050)

**Interfaces:**
- Consumes: the four harmonia commits (Tasks 1–4).
- Produces: `services.harmonia.package` running the patch on ghostgate; settings enabling it. The nginx side (Task 6) provides `127.0.0.1:8137`.

- [ ] **Step 1: Generate the patch**

```bash
mkdir -p /home/numinit/systems/pkgs/harmonia
git -C ~/projects/harmonia diff harmonia-v3.1.0..substitute-on-miss \
  > /home/numinit/systems/pkgs/harmonia/substitute-on-miss.patch
```

- [ ] **Step 2: Wire it on ghostgate** (package override lives host-side, NOT in overlayAttrs — self-reference there recurses):

```nix
  services.harmonia = {
    enable = true;
    # substitute-on-miss patch (see pkgs/harmonia/substitute-on-miss.patch;
    # spec: docs/superpowers/specs/2026-07-16-harmonia-substitute-on-miss-design.md).
    # Upstream PR to nix-community/harmonia planned post-event.
    package = pkgs.harmonia.overrideAttrs (prev: {
      patches = (prev.patches or [ ]) ++ [ ../../pkgs/harmonia/substitute-on-miss.patch ];
    });
    settings = {
      enable_compression = false;
      substitute_on_miss = true;
      # Plain-HTTP localhost listener (nginx) proxying cache.nixos.org —
      # expands missed hash parts to full store paths.
      miss_resolver_url = "http://127.0.0.1:8137";
    };
  };
```

- [ ] **Step 3: Build the patched package**

```bash
cd /home/numinit/systems
nix build --no-link --print-out-paths --impure --expr \
  '(builtins.getFlake "git+file:///home/numinit/systems").nixosConfigurations.ghostgate.config.services.harmonia.package'
```
Expected: builds. If cargo fails with a frozen-lockfile complaint, the
patch's `Cargo.lock` hunk is inconsistent — regenerate it in the harmonia
tree (`nix develop -c cargo check` updates the lock) and re-export the patch.

- [ ] **Step 4: Commit**

```bash
git add pkgs/harmonia devices/ghostgate/default.nix
git commit --no-gpg-sign -m "ghostgate: harmonia substitute-on-miss"
```

---

### Task 6: nginx — fall-through + resolver listener

**Files:**
- Modify: `/home/numinit/systems/devices/ghostgate/default.nix` — top-level `let` (add the shared snippet) and `services.nginx.virtualHosts` (`cache.nixos.lv` + a new listener vhost).

**Interfaces:**
- Consumes: nothing new; produces `127.0.0.1:8137` (Task 5's resolver) and client-facing fall-through.

- [ ] **Step 1: Shared upstream proxy snippet** in the file's top-level `let`:

```nix
  # Direct proxy to cache.nixos.org, carrying the hard-won fastly lessons:
  # runtime v4-only resolution (an all-AAAA upstream list 502s without a v6
  # route) and verify depth 4 (LE 2026 chain: leaf -> YR2 -> Root YR ->
  # ISRG Root X1 exceeds the nginx default of 1). Used by cache.nixos.lv's
  # @fallthrough and harmonia's miss resolver listener. No proxy_store: the
  # mirror experiment is over, nothing is persisted here.
  cacheUpstreamProxy = ''
    resolver 127.0.0.1 ipv6=off valid=300s;
    set $cache_upstream cache.nixos.org;
    proxy_pass https://$cache_upstream$request_uri;
    proxy_set_header Host cache.nixos.org;
    proxy_ssl_server_name on;
    proxy_ssl_name cache.nixos.org;
    proxy_ssl_verify on;
    proxy_ssl_verify_depth 4;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
  '';
```

- [ ] **Step 2: cache.nixos.lv fall-through** — replace the vhost's `locations`:

```nix
        "cache.nixos.lv" = {
          http2 = true;
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://cache.dc.nixos.lv";
            # A harmonia miss falls through to upstream for THIS request;
            # harmonia's substitute-on-miss warms the path so the next one
            # is served locally.
            extraConfig = ''
              proxy_intercept_errors on;
              error_page 404 = @fallthrough;
            '';
          };
          locations."@fallthrough".extraConfig = cacheUpstreamProxy;
        };
```

- [ ] **Step 3: Resolver listener vhost** (plain HTTP, loopback only):

```nix
        # harmonia's substitute-on-miss resolver: expands a missed hash part
        # by fetching <hash>.narinfo from upstream. Loopback-only.
        "harmonia-miss-resolver" = {
          serverName = "harmonia-miss-resolver";
          listen = [
            {
              addr = "127.0.0.1";
              port = 8137;
            }
          ];
          locations."/".extraConfig = cacheUpstreamProxy;
        };
```

- [ ] **Step 4: Verify by eval**

```bash
nix eval --raw ".#nixosConfigurations.ghostgate.config.services.nginx.virtualHosts.\"cache.nixos.lv\".locations.\"@fallthrough\".extraConfig" | grep -c proxy_ssl_verify_depth
```
Expected: `1`.

- [ ] **Step 5: Commit**

```bash
git add devices/ghostgate/default.nix
git commit --no-gpg-sign -m "ghostgate: cache.nixos.lv falls through to upstream on harmonia miss"
```

---

### Task 7: mirror decommission sweep

**Files:**
- Modify: `/home/numinit/systems/devices/ghostgate/default.nix` (six removals)
- Modify: `/home/numinit/systems/devices/citadel/default.nix` (hosts pin)
- Modify: `/home/numinit/systems/devices/brass/default.nix` (`onsiteBackends`)
- Modify: `/home/numinit/systems/docs/event-network.md`

**Interfaces:** pure removals; Task 6 already replaced the mirror's role.

- [ ] **Step 1: ghostgate removals** — delete each of these blocks/lines added for the mirror:
  1. `fileSystems."/var/cache/nar" = { ... };` + the `systemd.tmpfiles.rules` nar entries + `systemd.services.nginx.serviceConfig.ReadWritePaths`/`unitConfig.RequiresMountsFor` for `/var/cache/nar` (keep the `systemd.services.nginx` attrset only if anything else remains in it — otherwise remove it entirely).
  2. The whole `"upstream.cache.nixos.lv"` virtualHost.
  3. `networking.hosts."127.0.0.1" = [ "upstream.cache.nixos.lv" ];` (and its comment).
  4. The `upstream.cache.${baseDomain}. CNAME ghostgate.${domain}.` zone line.
  5. `"upstream.cache.nixos.lv."` from kresd `ourDomains` (keep the exact-match warning comment).
  6. `nix.settings.substituters = lib.mkAfter [ "https://upstream.cache.nixos.lv?priority=35" ];` + its comment block (the nixpkgs-default `https://cache.nixos.org/` is now the intended direct path).

- [ ] **Step 2: citadel** — the hosts pin keeps only harmonia's name:

```nix
    hosts.${ctf.address} = [ "cache.nixos.lv" ];
```
(update the comment: the substituter comes from the cnl plan; misses pull
through cache.nixos.lv itself now.)

- [ ] **Step 3: brass** — remove `"upstream.cache.nixos.lv" = ghostgateNebula;` from `onsiteBackends`.

- [ ] **Step 4: docs/event-network.md** — replace the mirror bullet in Split-horizon DNS with:

```markdown
- `cache.nixos.lv` is harmonia over ghostgate's dedup+zstd store — the study
  winner — with pull-through semantics: nginx retries harmonia 404s directly
  against cache.nixos.org (nothing persisted), while a patched harmonia
  (`pkgs/harmonia/substitute-on-miss.patch`) asks the nix daemon to
  substitute the missed path in the background, so the store converges on
  what the event actually uses. The `upstream.cache.nixos.lv` mirror and the
  `ghostgate-nar` pool are decommissioned.
```

Remove `upstream.cache.nixos.lv` from the onsite-only name list and the
public-DNS deploy-dependency list.

- [ ] **Step 5: Build all three toplevels + zone (kzonecheck runs in-build)**

```bash
for h in ghostgate citadel brass; do
  nix build --no-link .#nixosConfigurations.$h.config.system.build.toplevel || break
done
```
Expected: three clean builds.

- [ ] **Step 6: Commit**

```bash
git add devices/ghostgate/default.nix devices/citadel/default.nix devices/brass/default.nix docs/event-network.md
git commit --no-gpg-sign -m "treewide: decommission the upstream.cache.nixos.lv mirror"
```

---

### Task 8: site content follow-up

**Files:**
- Modify: `~/projects/nix.vegas/content/2026/onsite.md` (on whatever branch currently carries it — check `git -C ~/projects/nix.vegas branch -a`)

- [ ] **Step 1:** Replace the two mirror paragraphs ("If we don't, …
upstream.cache.nixos.lv …" and the "Heading home?" paragraph's mirror
mention) with:

```markdown
If we don't have something cached yet, cache.nixos.lv fetches it from
[https://cache.nixos.org](https://cache.nixos.org) for you on the fly and
keeps a copy for the next person.

Heading home? cache.nixos.lv is event-only: offsite it just redirects to
nix.vegas, and your Nix will warn and fall back to
[https://cache.nixos.org](https://cache.nixos.org) on its own. Drop it from
your
[substituters](https://search.nixos.org/options?channel=26.05&from=0&size=50&sort=relevance&type=packages&query=nix.settings.substituters)
when you get home to skip the warning.
```

- [ ] **Step 2:** Rebuild the site default flavor, confirm the page renders
and no `upstream.cache` remains:

```bash
cd ~/projects/nix.vegas
D=$(nix build .#default --no-link --print-out-paths)
grep -c 'upstream.cache' "$D/public/2026/onsite/index.html" || echo clean
```
Expected: `clean`.

- [ ] **Step 3: Commit** (user pushes with the rest of the site branch):

```bash
git add content/2026/onsite.md
git commit --no-gpg-sign -m "content/2026: cache.nixos.lv pulls through on its own now"
```

---

### Task 9: operator deploy + live verification

- [ ] **Step 1:** Re-sign systems commits; deploy ghostgate → citadel → brass.
- [ ] **Step 2:** Remove the public `upstream.cache.nixos.lv` DNS record.
- [ ] **Step 3:** Live pull-through test from the noc LAN, with a hash that's upstream but not in ghostgate's store (grab any from `curl -s https://cache.nixos.org/nix-cache-info`-adjacent narinfo you know, e.g. a fresh nixpkgs-unstable path):

```bash
curl -sw '%{http_code}\n' https://cache.nixos.lv/<hash>.narinfo | tail -1   # 200 via fall-through
ssh ghostgate 'journalctl -u harmonia -n 5 | grep substitute-on-miss'
sleep 30 && curl -sI https://cache.nixos.lv/<hash>.narinfo | head -1        # served by harmonia now
curl -s https://cache.nixos.lv/metrics | grep harmonia_warms
```
- [ ] **Step 4:** Capture study artifacts, then destroy the pool:

```bash
zpool status -DD ghostgate > ~/nar-study-ddt.txt
zfs list -o space ghostgate/local/nix ghostgate-nar/local/nar >> ~/nar-study-ddt.txt
zpool destroy ghostgate-nar
```
(Deploy the decommissioned config **before** destroying the pool — the old
generation's nginx holds `RequiresMountsFor` on it.)
