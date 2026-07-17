# harmonia stream-through caching NAR endpoint — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace harmonia's 302-redirect+background-warm substitute-on-miss with an in-process stream-through cache: on a narinfo miss serve upstream's narinfo rewritten to point at harmonia's own NAR endpoint; on the NAR request, fetch the upstream `.nar.xz` once, xz-decode, and fan it out to the requesting client(s) and into the store via `add_to_store_nar` — one uplink fetch, no amplification, no stall for the start-of-job cohort. Per `docs/superpowers/specs/2026-07-16-harmonia-streamthrough-nar-design.md`.

**Architecture:** A narinfo LRU (populated on narinfo miss, keyed by store-path hash) feeds a per-path streaming Job (registry of `Weak<Job>`). The Job fetches+decodes the upstream NAR once and fans each chunk to a `tokio::sync::broadcast` (client streams) and to a daemon `add_to_store_nar` sink (the durable priority). The narinfo/nar handlers are the entry points; the redirect/warm module is deleted.

**Tech Stack:** Rust (actix-web, tokio, tokio-rustls, async-compression/xz, harmonia-store-remote), the nix daemon.

## Global Constraints

- Work tree: `~/projects/harmonia`, branch `substitute-on-miss` (continues the branch that currently holds the redirect+warm implementation — this plan *replaces* that mechanism).
- **Commits unsigned in-session:** `git commit --no-gpg-sign`.
- **No blocking the narinfo response.** narinfo miss returns 200 immediately after the tiny upstream narinfo fetch (or LRU hit). Stock 404 when `substitute_on_miss` is off.
- **The store import is the durable priority:** the Job runs to completion regardless of client attach/detach; a lagging client is dropped, never gating the Job.
- **One upstream NAR fetch per unique missed path** under concurrent requests (coalescing via the Job registry).
- Client is served **uncompressed** (`Compression: none`); the store import sink receives every byte.
- Signature: the narinfo rewrite preserves `StorePath`/`NarHash`/`NarSize`/`References`/`Deriver`/`Sig` (the fingerprint `1;path;narhash;narsize;refs`); only `URL`/`Compression`/`FileHash`/`FileSize` change. The daemon verifies the NAR hash on import.
- Config keys (harmonia TOML): `substitute_on_miss` (bool, default false), `miss_upstream_url` (default `https://cache.nixos.org`, must be `https://`), `miss_daemon_socket` (default `/nix/var/nix/daemon-socket/socket`), `miss_narinfo_cache_size` (default 1024), `miss_narinfo_cache_ttl` (secs, default 600).
- Rust build/tests run in `nix develop -c cargo ...` from `~/projects/harmonia`. `harmonia-cache` is a **binary** crate (use `--bins`, not `--lib`). The `retry` integration test is flaky on a loaded box (pre-existing) — exclude it; run `chroot` for integration.
- Verified source anchors: `nar::get` at `harmonia-cache/src/nar.rs:56` (nix-serve route miss → 404 at the `query_path_info_by_hash_part` `None` arm ~line 96); routes at `main.rs:177-200`; `add_to_store_nar(&mut self, info: &ValidPathInfo, source: AR: AsyncBufRead+Send+Unpin, repair: bool, dont_check_sigs: bool)` at `harmonia-store-remote/src/client.rs:583`; `ValidPathInfo { path: StorePath, info: UnkeyedValidPathInfo }`, `UnkeyedValidPathInfo { deriver: Option<StorePath>, nar_hash: NarHash, references: BTreeSet<StorePath>, registration_time, nar_size: u64, ultimate: bool, signatures: BTreeSet<Signature>, ca: Option<ContentAddress>, store_dir: StoreDir }` at `harmonia-protocol/src/valid_path_info.rs:25,40`.

---

### Task 1: Config — narinfo cache knobs

**Files:**
- Modify: `harmonia-cache/src/config.rs`

**Interfaces:**
- Produces: `Config.miss_narinfo_cache_size: usize`, `Config.miss_narinfo_cache_ttl: u64` (secs). (`substitute_on_miss`, `miss_upstream_url`, `miss_daemon_socket` already exist from the redirect work.)

- [ ] **Step 1: Add default fns + fields**

After `default_miss_upstream_url`:
```rust
fn default_miss_narinfo_cache_size() -> usize {
    1024
}

fn default_miss_narinfo_cache_ttl() -> u64 {
    600
}
```
In `struct Config`, after `miss_daemon_socket`:
```rust
    /// Max entries in the in-memory narinfo LRU (upstream narinfos of
    /// in-flight, not-yet-materialized paths). Low on purpose — entries are
    /// deleted when their NAR job completes.
    #[serde(default = "default_miss_narinfo_cache_size")]
    pub(crate) miss_narinfo_cache_size: usize,
    /// TTL (seconds) for narinfo LRU entries; backstop for narinfos whose NAR
    /// is never requested.
    #[serde(default = "default_miss_narinfo_cache_ttl")]
    pub(crate) miss_narinfo_cache_ttl: u64,
```

- [ ] **Step 2: Update the config defaults test** — in the `tests` mod, extend `test_substitute_on_miss_defaults`:
```rust
        assert_eq!(c.miss_narinfo_cache_size, 1024);
        assert_eq!(c.miss_narinfo_cache_ttl, 600);
```

- [ ] **Step 3: Test**

Run: `nix develop -c cargo test -p harmonia-cache --bins config`
Expected: PASS.

- [ ] **Step 4: Commit**
```bash
git add harmonia-cache/src/config.rs
git commit --no-gpg-sign -m "harmonia-cache: narinfo cache config knobs"
```

---

### Task 2: Cargo deps — xz + lru

**Files:**
- Modify: `harmonia-cache/Cargo.toml`

**Interfaces:**
- Produces: `async-compression` with the `xz` feature; the `lru` crate available.

- [ ] **Step 1: Edit deps**

Change the `async-compression` line to add `xz`:
```toml
async-compression = { version = "0.4.42", features = [ "tokio", "bzip2", "xz" ] }
```
Add under the general deps (near `url`):
```toml
lru = "0.12"
```
(`tokio-rustls`/`webpki-roots` are already present from the redirect work.)

- [ ] **Step 2: Compile check** (resolves the new crate into `Cargo.lock`)

Run: `nix develop -c cargo check -p harmonia-cache`
Expected: compiles; `Cargo.lock` gains `lru` and the xz-decoder deps.

- [ ] **Step 3: Commit**
```bash
git add harmonia-cache/Cargo.toml Cargo.lock
git commit --no-gpg-sign -m "harmonia-cache: async-compression xz feature + lru dep"
```

---

### Task 3: Upstream narinfo model — parse + rewrite

**Files:**
- Create: `harmonia-cache/src/upstream_narinfo.rs`
- Modify: `harmonia-cache/src/main.rs` (add `mod upstream_narinfo;`)

**Interfaces:**
- Produces:
  - `struct UpstreamNarInfo { store_path: String, nar_url: String, rendered_client_narinfo: String, info: ValidPathInfo }` (`nar_url` = upstream compressed `nar/<filehash>.nar.xz`).
  - `fn parse_upstream_narinfo(store_dir: &StoreDir, text: &str) -> Result<UpstreamNarInfo, String>`
  - `fn client_narinfo_text(store_path_hash: &str, nar_hash_bare: &str, up: &ParsedFields) -> String` (the rewritten narinfo served to clients).
- Consumed by Tasks 5, 6.

- [ ] **Step 1: Write the module**

Parse the upstream narinfo's key/value lines into fields, build a `ValidPathInfo` for the daemon import, and render the client-facing rewritten narinfo. Keep signatures byte-exact.

```rust
//! Parse an upstream (cache.nixos.org) narinfo and produce (a) the client-
//! facing narinfo rewritten to point at harmonia's own NAR endpoint with
//! Compression: none, and (b) a ValidPathInfo for add_to_store_nar. The
//! rewrite only touches URL/Compression/FileHash/FileSize, which are NOT in
//! the signature fingerprint (1;path;narhash;narsize;refs), so the upstream
//! Sig lines stay valid.

use std::collections::BTreeSet;

use harmonia_protocol::valid_path_info::{UnkeyedValidPathInfo, ValidPathInfo};
use harmonia_store_core::store_path::{StoreDir, StorePath};

pub(crate) struct UpstreamNarInfo {
    pub store_path: String,          // "/nix/store/<hash>-<name>"
    pub store_path_hash: String,     // "<outhash>" (32 base32)
    pub nar_hash_bare: String,       // NAR hash, bare base32 (no "sha256:")
    pub nar_url: String,             // upstream "nar/<filehash>.nar.xz"
    pub client_narinfo: String,      // rewritten text served to clients
    pub info: ValidPathInfo,         // for add_to_store_nar
}

pub(crate) fn parse_upstream_narinfo(
    store_dir: &StoreDir,
    text: &str,
) -> Result<UpstreamNarInfo, String> {
    let mut store_path = None;
    let mut url = None;
    let mut nar_hash = None; // e.g. "sha256:abc..." or "sha256-..." — keep as-is for parse
    let mut nar_size = None;
    let mut references: Vec<&str> = Vec::new();
    let mut deriver = None;
    let mut ca = None;
    let mut sigs: Vec<&str> = Vec::new();

    for line in text.lines() {
        let Some((k, v)) = line.split_once(": ") else { continue };
        match k {
            "StorePath" => store_path = Some(v.trim().to_string()),
            "URL" => url = Some(v.trim().to_string()),
            "NarHash" => nar_hash = Some(v.trim().to_string()),
            "NarSize" => nar_size = Some(v.trim().to_string()),
            "References" => {
                references = v.split_whitespace().collect();
            }
            "Deriver" => deriver = Some(v.trim().to_string()),
            "CA" => ca = Some(v.trim().to_string()),
            "Sig" => sigs.push(v.trim()),
            _ => {}
        }
    }

    let store_path = store_path.ok_or("upstream narinfo: no StorePath")?;
    let url = url.ok_or("upstream narinfo: no URL")?;
    let nar_hash_raw = nar_hash.ok_or("upstream narinfo: no NarHash")?;
    let nar_size_str = nar_size.ok_or("upstream narinfo: no NarSize")?;
    let nar_size: u64 = nar_size_str.parse().map_err(|e| format!("bad NarSize: {e}"))?;

    let basename = store_path
        .strip_prefix("/nix/store/")
        .ok_or("StorePath not under /nix/store/")?;
    let store_path_hash = basename
        .split_once('-')
        .map(|(h, _)| h.to_string())
        .ok_or("StorePath basename has no '-'")?;

    // NarHash may be "sha256:<base32>" or "sha256-<base64 SRI>"; harmonia's
    // client nar route expects bare base32. Normalize to bare base32 for the
    // rewritten URL. Reuse harmonia's Hash parser (Any<Hash>) to be exact.
    let nar_hash_bare = normalize_nar_hash_bare(&nar_hash_raw)?;

    // Build ValidPathInfo for the daemon import.
    let sp: StorePath = store_dir
        .parse(&store_path)
        .map_err(|e| format!("parse StorePath: {e}"))?;
    let info = build_valid_path_info(
        store_dir, sp, &nar_hash_raw, nar_size, &references, deriver.as_deref(),
        ca.as_deref(), &sigs,
    )?;

    // Rewritten client narinfo: URL -> harmonia nix-serve nar route, no
    // compression, FileHash/FileSize = NarHash/NarSize. Keep Sig lines.
    let mut out = String::new();
    out.push_str(&format!("StorePath: {store_path}\n"));
    out.push_str(&format!(
        "URL: nar/{store_path_hash}-{nar_hash_bare}.nar\n"
    ));
    out.push_str("Compression: none\n");
    out.push_str(&format!("FileHash: {nar_hash_raw}\n"));
    out.push_str(&format!("FileSize: {nar_size}\n"));
    out.push_str(&format!("NarHash: {nar_hash_raw}\n"));
    out.push_str(&format!("NarSize: {nar_size}\n"));
    if !references.is_empty() {
        out.push_str(&format!("References: {}\n", references.join(" ")));
    }
    if let Some(d) = &deriver {
        out.push_str(&format!("Deriver: {d}\n"));
    }
    if let Some(c) = &ca {
        out.push_str(&format!("CA: {c}\n"));
    }
    for s in &sigs {
        out.push_str(&format!("Sig: {s}\n"));
    }

    Ok(UpstreamNarInfo {
        store_path,
        store_path_hash,
        nar_hash_bare,
        nar_url: url,
        client_narinfo: out,
        info,
    })
}
```

Plus two helpers — `normalize_nar_hash_bare` (reuse harmonia's `Any<Hash>`
parser exactly as `nar.rs` does: `raw.parse::<Any<Hash>>()?.into_hash().as_base32().as_bare().to_string()`)
and `build_valid_path_info` (parse each reference and the deriver via
`store_dir.parse`, `nar_hash_raw` via the same `Any<Hash>` into a `NarHash`,
`ca` via `ContentAddress`'s FromStr, `sigs` via `Signature::from_str`,
assembling `ValidPathInfo { path, info: UnkeyedValidPathInfo { deriver,
nar_hash, references, registration_time: None, nar_size, ultimate: false,
signatures, ca, store_dir: store_dir.clone() } }`). Match the exact
constructors used elsewhere in the tree (grep `into_hash`, `as_bare`,
`ContentAddress`, `Signature` in `harmonia-store-core`/`nar.rs`).

- [ ] **Step 2: Unit test the rewrite (signature-preserving)**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    // A minimal valid store_dir for /nix/store.
    fn sd() -> StoreDir { StoreDir::default() }

    const SAMPLE: &str = "StorePath: /nix/store/00000000000000000000000000000000-x\nURL: nar/1abc.nar.xz\nCompression: xz\nFileHash: sha256:1abc\nFileSize: 10\nNarHash: sha256:2def\nNarSize: 20\nReferences: 00000000000000000000000000000000-x\nSig: cache.nixos.org-1:AAAA\n";

    #[test]
    fn rewrite_points_at_harmonia_and_keeps_sig() {
        let up = parse_upstream_narinfo(&sd(), SAMPLE).unwrap();
        assert!(up.client_narinfo.contains("URL: nar/00000000000000000000000000000000-"));
        assert!(up.client_narinfo.contains("Compression: none"));
        assert!(up.client_narinfo.contains("Sig: cache.nixos.org-1:AAAA"));
        // NarHash/NarSize unchanged (fingerprint fields).
        assert!(up.client_narinfo.contains("NarSize: 20"));
        assert_eq!(up.nar_url, "nar/1abc.nar.xz");
    }
}
```
(Adjust `SAMPLE`'s hashes to values harmonia's `Any<Hash>` parser accepts; if
`StoreDir::default()` isn't the constructor, use the same one `nar.rs`/tests
use — grep `StoreDir::` in the tree.)

- [ ] **Step 3: Wire the module** — add `mod upstream_narinfo;` in `main.rs` beside `mod narinfo;`.

- [ ] **Step 4: Test**

Run: `nix develop -c cargo test -p harmonia-cache --bins upstream_narinfo`
Expected: PASS (iterate hash literals until the `Any<Hash>` parse accepts them).

- [ ] **Step 5: Commit**
```bash
git add harmonia-cache/src/upstream_narinfo.rs harmonia-cache/src/main.rs
git commit --no-gpg-sign -m "harmonia-cache: parse+rewrite upstream narinfo (sig-preserving)"
```

---

### Task 4: narinfo LRU cache

**Files:**
- Create: `harmonia-cache/src/narinfo_cache.rs`
- Modify: `harmonia-cache/src/main.rs` (`mod narinfo_cache;`)

**Interfaces:**
- Produces: `struct NarInfoCache` with:
  - `fn new(cap: usize, ttl: Duration) -> Self`
  - `fn insert(&self, hash: String, v: Arc<UpstreamNarInfo>)`
  - `fn get(&self, hash: &str) -> Option<Arc<UpstreamNarInfo>>` (None past TTL)
  - `fn remove(&self, hash: &str)`
- Consumed by Tasks 5, 6, 7.

- [ ] **Step 1: Write the cache**

```rust
//! Bounded, TTL'd LRU of upstream narinfos for in-flight (fetched but not yet
//! materialized) paths. Keyed by store-path hash. Entries are normally
//! removed when their NAR job completes; size+TTL are backstops. In-memory,
//! no persistence.

use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use lru::LruCache;

use crate::upstream_narinfo::UpstreamNarInfo;

pub(crate) struct NarInfoCache {
    inner: Mutex<LruCache<String, (Instant, Arc<UpstreamNarInfo>)>>,
    ttl: Duration,
}

impl NarInfoCache {
    pub(crate) fn new(cap: usize, ttl: Duration) -> Self {
        let cap = NonZeroUsize::new(cap.max(1)).unwrap();
        Self { inner: Mutex::new(LruCache::new(cap)), ttl }
    }

    pub(crate) fn insert(&self, hash: String, v: Arc<UpstreamNarInfo>) {
        self.inner.lock().unwrap().put(hash, (Instant::now(), v));
    }

    pub(crate) fn get(&self, hash: &str) -> Option<Arc<UpstreamNarInfo>> {
        let mut g = self.inner.lock().unwrap();
        match g.get(hash) {
            Some((t, v)) if t.elapsed() < self.ttl => Some(v.clone()),
            Some(_) => {
                g.pop(hash);
                None
            }
            None => None,
        }
    }

    pub(crate) fn remove(&self, hash: &str) {
        self.inner.lock().unwrap().pop(hash);
    }
}
```

- [ ] **Step 2: Unit test size + TTL + remove**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    fn dummy() -> Arc<UpstreamNarInfo> { /* build a minimal UpstreamNarInfo via parse_upstream_narinfo on the SAMPLE from Task 3, wrapped in Arc */ unimplemented!() }

    #[test]
    fn ttl_expires_on_read() {
        let c = NarInfoCache::new(4, Duration::from_millis(0));
        c.insert("h".into(), dummy());
        assert!(c.get("h").is_none()); // ttl 0 => immediately absent
    }

    #[test]
    fn remove_drops_entry() {
        let c = NarInfoCache::new(4, Duration::from_secs(60));
        c.insert("h".into(), dummy());
        assert!(c.get("h").is_some());
        c.remove("h");
        assert!(c.get("h").is_none());
    }
}
```
Replace `dummy()`'s `unimplemented!()` by parsing Task 3's `SAMPLE` and
`Arc::new`-ing it (share a test helper). A size-eviction test: `new(1, 60s)`,
insert "a" then "b", assert `get("a")` is None.

- [ ] **Step 3: Wire + test**
`mod narinfo_cache;` in `main.rs`. Run:
`nix develop -c cargo test -p harmonia-cache --bins narinfo_cache`
Expected: PASS.

- [ ] **Step 4: Commit**
```bash
git add harmonia-cache/src/narinfo_cache.rs harmonia-cache/src/main.rs
git commit --no-gpg-sign -m "harmonia-cache: TTL'd LRU narinfo cache"
```

---

### Task 5: Upstream HTTPS client — one-shot + streaming

**Files:**
- Rename/rewrite: `harmonia-cache/src/miss_warm.rs` → `harmonia-cache/src/upstream.rs` (keep the tokio-rustls setup; drop the redirect/warm/EnsurePath code — this plan replaces it).
- Modify: `harmonia-cache/src/main.rs` (`mod upstream;`, remove `mod miss_warm;` and the `default_service(... redirect_or_404)` line + the narinfo redirect branch will be replaced in Task 6/7).

**Interfaces:**
- Produces:
  - `async fn get_text(upstream: &str, path: &str) -> Result<String, String>` (the one-shot narinfo GET; the existing `https_get`, renamed).
  - `async fn get_stream(upstream: &str, path: &str) -> Result<impl AsyncBufRead + Unpin + Send, String>` — opens the TLS connection, writes the GET, validates `200`, and returns an `AsyncBufRead` positioned at the response body (for the NAR `.nar.xz`). Implement by returning a `tokio::io::BufReader` over the TLS stream after consuming the header bytes (parse Content-Length/close-delimited; cache.nixos.org sends `Connection: close`, so read-to-close is fine).
- Consumed by Tasks 6.

- [ ] **Step 1: Extract the shared TLS setup** — keep `TLS_CONFIG` (LazyLock rustls ClientConfig w/ webpki-roots), the `https://`-parse, TCP connect, TLS connect from the current `miss_warm.rs`.

- [ ] **Step 2: `get_text`** — the current `https_get` body verbatim, renamed. Returns the response body String on `200`.

- [ ] **Step 3: `get_stream`** — connect + handshake + write request, then read and discard the response headers up to `\r\n\r\n`, returning a `BufReader` over the remaining TLS stream (body). Sketch:
```rust
pub(crate) async fn get_stream(
    upstream: &str,
    path: &str,
) -> Result<tokio::io::BufReader<tokio_rustls::client::TlsStream<tokio::net::TcpStream>>, String> {
    let (host, _) = split_host(upstream)?;                 // reuse from get_text
    let mut tls = tls_connect(host).await?;                // TCP+TLS, shared helper
    write_get(&mut tls, host, path).await?;                // GET line + Host + Connection: close
    read_past_headers(&mut tls).await?;                    // read until CRLFCRLF, check "200"
    Ok(tokio::io::BufReader::new(tls))
}
```
`read_past_headers` reads byte-by-byte (or small chunks with a tiny leftover
buffer) until `\r\n\r\n`, asserts the status line contains `" 200 "`, and
leaves the stream at the first body byte. Any leftover already-read body bytes
must be prepended — simplest correct approach: read into a growing `Vec`,
find the `\r\n\r\n`, then return a reader that first yields the leftover body
bytes then the live stream (`tokio::io::AsyncReadExt::chain` a `Cursor` of the
leftover with the `BufReader`). Return that `chain` (adjust the return type to
`impl AsyncBufRead + Unpin + Send` via `tokio::io::BufReader::new(cursor.chain(tls))`).

- [ ] **Step 4: Compile check**
Run: `nix develop -c cargo check -p harmonia-cache`
Expected: compiles (handlers referencing the old `miss_warm` are updated in Tasks 6–7; temporarily this task may not compile standalone — fold Tasks 5–7 into one commit if the intermediate state doesn't build).

- [ ] **Step 5: Commit** (may be combined with Task 6/7 if intermediate build fails)
```bash
git add harmonia-cache/src/upstream.rs harmonia-cache/src/main.rs
git rm harmonia-cache/src/miss_warm.rs
git commit --no-gpg-sign -m "harmonia-cache: upstream HTTPS client (one-shot + streaming)"
```

---

### Task 6: The per-path streaming Job + registry

**Files:**
- Create: `harmonia-cache/src/nar_job.rs`
- Modify: `harmonia-cache/src/main.rs` (`mod nar_job;`; construct shared state)

**Interfaces:**
- Consumes: `upstream::get_stream` (Task 5), `NarInfoCache` (Task 4), `UpstreamNarInfo`/`parse_upstream_narinfo` (Task 3), `DaemonClientBuilder`/`add_to_store_nar` (harmonia-store-remote), `Config` (Task 1), metrics (Task 8).
- Produces:
  - `struct JobRegistry { jobs: Mutex<HashMap<String, Weak<Job>>>, cache: Arc<NarInfoCache> }` (key = store-path hash).
  - `enum Attach { Live(BroadcastBody), AlreadyLocal, Parked(JobDone) }`
  - `async fn JobRegistry::attach(&self, cfg, metrics, store_path_hash) -> Attach` — creates or joins a Job (the Job derives the nar hash from the upstream narinfo it fetches), returning either a live broadcast stream (start-of-job cohort), a signal to serve from the store (path already local / job done), or a `Parked` watch to await job completion (mid-stream arrival) then serve from store.
- Consumed by Task 7.

- [ ] **Step 1: Job structure**

The Job owns the fan-out. Use `tokio::sync::broadcast::channel::<bytes::Bytes>(cap)` for live clients and a `tokio::sync::watch`/`Notify` for "done" signalling to parked waiters. The store sink is fed via an `async` pipe: create a `tokio::io::duplex` (or a bounded `mpsc` bridged to an `AsyncBufRead`) whose read half is passed to `add_to_store_nar` and whose write half the fan-out loop writes to (awaited — this is the gate).

```rust
use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};

use bytes::Bytes;
use tokio::sync::{broadcast, watch};

pub(crate) struct Job {
    hash: String,
    // Live subscribers attach here; None once the job has finished.
    tx: broadcast::Sender<Bytes>,
    // false -> in progress, true(ok) / done(err) -> finished; parked waiters await this.
    done: watch::Receiver<JobState>,
    nar_size: u64,
}

#[derive(Clone)]
pub(crate) enum JobState { Running, Ok, Failed }
```

- [ ] **Step 2: The fan-out loop** (the heart)

Spawn a task, owned by the `Arc<Job>` creation, that:
1. `get_or_fetch_upstream()` — LRU `get(hash)`; on miss `upstream::get_text(cfg.miss_upstream_url, "/{hash}.narinfo")` → `parse_upstream_narinfo` → `cache.insert`.
2. Open the daemon: `DaemonClientBuilder::new().connect_unix(cfg.miss_daemon_socket).await?`.
3. `let (store_w, store_r) = tokio::io::duplex(64 * 1024);` — `store_r` (a `DuplexStream`, which is `AsyncRead`; wrap in `BufReader` for `AsyncBufRead`) goes to `add_to_store_nar(&up.info, BufReader::new(store_r), false, false)`. Drive that future concurrently (`tokio::spawn` or `tokio::join!`).
4. `let body = upstream::get_stream(cfg.miss_upstream_url, &format!("/{}", up.nar_url)).await?;`
5. `let mut dec = async_compression::tokio::bufread::XzDecoder::new(body);`
6. Loop reading decoded chunks (`dec.read_buf(&mut buf)` into a reusable `BytesMut`, split to `Bytes`):
   - `store_w.write_all(&chunk).await?` — **awaited: the gate. Every byte must reach the store sink.**
   - `let _ = tx.send(chunk.clone());` — non-blocking broadcast; ignore `SendError` (no receivers is fine).
7. On EOF: `store_w.shutdown().await?`; await the `add_to_store_nar` future → `DaemonResult<()>`. On success set `watch` to `Ok`; on any error set `Failed`.
8. Always: remove `hash` from the registry and `cache.remove(hash)`; bump metrics.

Backpressure note: the fan-out is gated by `store_w.write_all` (duplex buffer, drained by the daemon at disk speed) and by the upstream read (uplink). `broadcast::send` never blocks; a slow client that lags past the broadcast capacity gets `RecvError::Lagged` on its receiver → its body stream ends in error (dropped), Job unaffected.

- [ ] **Step 3: `attach`**

```rust
pub(crate) async fn attach(
    self: &Arc<JobRegistry>,
    cfg: web::Data<Config>,
    metrics: web::Data<Arc<PrometheusMetrics>>,
    store_path_hash: &str,
) -> Attach {
    // Fast path: already local? (caller checks the store first; see Task 7.)
    let mut jobs = self.jobs.lock().unwrap();
    if let Some(job) = jobs.get(store_path_hash).and_then(Weak::upgrade) {
        // Existing job: live if still Running at subscribe time, else parked.
        if matches!(*job.done.borrow(), JobState::Running) {
            let rx = job.tx.subscribe();
            return Attach::Live(BroadcastBody::new(rx, job.nar_size));
        }
        return Attach::Parked(job.done.clone()); // finishing; wait then store-serve
    }
    // Create a new job (spawns the fan-out; returns the Arc<Job>).
    let job = Job::spawn(cfg, metrics, self.clone(), store_path_hash.to_string());
    jobs.insert(store_path_hash.to_string(), Arc::downgrade(&job));
    let rx = job.tx.subscribe();
    Attach::Live(BroadcastBody::new(rx, job.nar_size))
}
```
Race note: subscribe **before** releasing the registry lock isn't possible
across the await in `Job::spawn`; ensure the broadcast `Sender` exists before
the fan-out loop sends its first chunk (create the channel in `Job::spawn`
synchronously, subscribe under the lock, then spawn the loop). This guarantees
the creating client is in the start-of-job cohort.

- [ ] **Step 4: `BroadcastBody`** — a `futures_core::Stream<Item = Result<Bytes, std::io::Error>>` wrapping `broadcast::Receiver<Bytes>`: `poll_next` maps `Ok(bytes)`→`Some(Ok(bytes))`, `Err(Lagged)`→`Some(Err(io::Error::other("lagged")))` (ends the client stream; metrics `nar_clients_dropped_total`), `Err(Closed)`→`None` (clean EOF). Used with `SizedStream::new(nar_size, body)`.

- [ ] **Step 5: Test the coalescing + convergence (integration)**

Add `harmonia-cache/tests/streamthrough.rs`: stand up a fake upstream (a `tokio::net::TcpListener` speaking minimal HTTP, serving a canned `<hash>.narinfo` and a canned `nar/<filehash>.nar.xz` built from a known NAR) — but since the real code hardcodes `https://`, make `miss_upstream_url` injectable to `http://127.0.0.1:<port>` for tests (add an `http://` code path in `upstream.rs` that skips TLS — gate on the scheme). Assert:
- N concurrent `get_stream`-driven jobs for one path → the fake upstream sees exactly **one** `.nar.xz` GET.
- Each client body equals the known decompressed NAR bytes.
- After completion the daemon store (scratch, as in `chroot.rs`) reports the path valid.
- **Lead-client disconnect:** drop the first client's receiver mid-stream; the path still becomes valid (convergence independent of clients).
- **Upstream truncation:** the fake upstream closes the `.nar.xz` early; assert the path is **not** valid afterward (incomplete NAR rejected by `add_to_store_nar`) and clients' bodies end in error.
This is the load-bearing test; budget iteration.

- [ ] **Step 6: Commit** (with Task 5 if needed for a building tree)
```bash
git add harmonia-cache/src/nar_job.rs harmonia-cache/src/main.rs harmonia-cache/tests/streamthrough.rs
git commit --no-gpg-sign -m "harmonia-cache: per-path streaming NAR job with broadcast fan-out + store import"
```

---

### Task 7: Wire the handlers + shared state

**Files:**
- Modify: `harmonia-cache/src/narinfo.rs` (miss branch)
- Modify: `harmonia-cache/src/nar.rs` (miss branch of the nix-serve route)
- Modify: `harmonia-cache/src/main.rs` (build `Arc<NarInfoCache>` + `Arc<JobRegistry>`, register as `app_data`; drop the `default_service` redirect)

**Interfaces:**
- Consumes: Tasks 3–6.

- [ ] **Step 1: Shared state in `main.rs`**

Before the `HttpServer::new` closure:
```rust
let narinfo_cache = std::sync::Arc::new(narinfo_cache::NarInfoCache::new(
    config.miss_narinfo_cache_size,
    std::time::Duration::from_secs(config.miss_narinfo_cache_ttl),
));
let job_registry = std::sync::Arc::new(nar_job::JobRegistry::new(narinfo_cache.clone()));
```
Register in the app builder: `.app_data(web::Data::new(narinfo_cache.clone()))`
and `.app_data(web::Data::new(job_registry.clone()))`. Remove the
`.default_service(web::route().to(miss_warm::redirect_or_404))` line.

- [ ] **Step 2: narinfo miss → fetch/cache/rewrite/serve**

Replace the redirect branch in `narinfo.rs`'s `None` arm:
```rust
None => {
    if settings.substitute_on_miss {
        let cache = /* web::Data<Arc<NarInfoCache>> extractor */;
        let up = match cache.get(&hash) {
            Some(up) => up,
            None => match crate::upstream::get_text(
                &settings.miss_upstream_url, &format!("/{hash}.narinfo")).await
            {
                Ok(text) => match crate::upstream_narinfo::parse_upstream_narinfo(
                    settings.store.store_dir(), &text)
                {
                    Ok(u) => { let a = std::sync::Arc::new(u); cache.insert(hash.clone(), a.clone()); a }
                    Err(_) => return Ok(not_found_missed_hash()),
                },
                Err(_) => return Ok(not_found_missed_hash()), // upstream 404/err -> stock 404
            },
        };
        metrics.narinfo_misses_total.inc();
        return Ok(HttpResponse::Ok()
            .insert_header((http::header::CONTENT_TYPE, "text/x-nix-narinfo"))
            .insert_header(crate::cache_control_no_store())
            .body(up.client_narinfo.clone()));
    }
    return Ok(not_found_missed_hash());
}
```
Add the `web::Data<Arc<NarInfoCache>>` extractor to `narinfo::get`'s
signature, and a small `not_found_missed_hash()` helper reproducing the stock
404 body/headers.

- [ ] **Step 3: nar miss → attach to a job**

In `nar.rs`, the nix-serve route's `query_path_info_by_hash_part` `None` arm
(currently returns 404): when `settings.substitute_on_miss` **and** an
`outhash` was present (nix-serve form), attach to the registry:
```rust
None => {
    if settings.substitute_on_miss {
        match registry.attach(settings.clone(), metrics.clone(), &store_path_hash.to_string()).await {
            Attach::Live(body) => {
                return Ok(HttpResponse::Ok()
                    .insert_header((http::header::CONTENT_TYPE, "application/x-nix-archive"))
                    .insert_header(crate::cache_control_no_store())
                    .body(actix_web::body::SizedStream::new(body.nar_size(), body)));
            }
            Attach::Parked(mut done) => {
                // mid-stream arrival: wait for completion, then fall through to
                // the normal store-serve path below (re-query the store).
                let _ = done.wait_for(|s| !matches!(s, JobState::Running)).await;
                // fall through: re-query store; if valid, serve; else 404.
            }
            Attach::AlreadyLocal => { /* fall through to store-serve */ }
        }
        // Re-query store after park; serve if now valid, else stock 404.
        // (Factor the store-serve tail of nar::get into a helper and call it here.)
    }
    return Ok(HttpResponse::NotFound()
        .insert_header(crate::cache_control_no_store())
        .body("store path not found"));
}
```
Add `web::Data<Arc<JobRegistry>>` and the metrics extractor to `nar::get`.
Factor the existing "serve from store" tail (the `NarByteStream`/`SizedStream`
block) into a helper both the hit path and the post-park path call.

- [ ] **Step 4: Full build + tests + clippy**
```bash
nix develop -c cargo test -p harmonia-cache --bins
nix develop -c cargo test -p harmonia-cache --test chroot -- --test-threads=1
nix develop -c cargo test -p harmonia-cache --test streamthrough -- --test-threads=1
nix develop -c cargo clippy -p harmonia-cache --all-targets -- -D warnings
```
Expected: all green (skip `retry` — pre-existing flaky).

- [ ] **Step 5: Commit**
```bash
git add harmonia-cache/src/narinfo.rs harmonia-cache/src/nar.rs harmonia-cache/src/main.rs
git commit --no-gpg-sign -m "harmonia-cache: wire narinfo rewrite + nar stream-through into the handlers"
```

---

### Task 8: Metrics

**Files:**
- Modify: `harmonia-cache/src/prometheus.rs`

**Interfaces:**
- Produces on `PrometheusMetrics`: `narinfo_misses_total` (exists), `nar_jobs_started_total`, `nar_jobs_completed_total`, `nar_jobs_failed_total`, `nar_clients_attached_total`, `nar_clients_dropped_total` (all `IntCounter`).

- [ ] **Step 1: Replace the old warm counters** — swap the `warms_*` counters for the `nar_jobs_*`/`nar_clients_*` set (same `IntCounter::new` + `registry.register` + struct-field pattern already in the file). Keep `narinfo_misses_total`.

- [ ] **Step 2: Reference them** from Task 6/7 (`.inc()` at job start/complete/fail and client attach/drop). Compile check.

- [ ] **Step 3: Commit**
```bash
git add harmonia-cache/src/prometheus.rs
git commit --no-gpg-sign -m "harmonia-cache: stream-through job/client metrics"
```

---

### Task 9: Systems — patch, settings, build

**Files:**
- Modify: `/home/numinit/systems/pkgs/harmonia/substitute-on-miss.patch` (regenerate)
- Modify: `/home/numinit/systems/devices/ghostgate/default.nix` (harmonia settings)

**Interfaces:** consumes the harmonia branch (Tasks 1–8).

- [ ] **Step 1: Regenerate the patch**
```bash
git -C ~/projects/harmonia diff harmonia-v3.1.0..substitute-on-miss \
  > /home/numinit/systems/pkgs/harmonia/substitute-on-miss.patch
```

- [ ] **Step 2: Settings** — in `services.harmonia.cache.settings`, keep `substitute_on_miss`/`miss_upstream_url`, optionally pin the cache knobs:
```nix
        substitute_on_miss = true;
        miss_upstream_url = "https://cache.nixos.org";
        # narinfo LRU (in-flight narinfos); low + self-cleaning.
        miss_narinfo_cache_size = 1024;
        miss_narinfo_cache_ttl = 600;
```
(nginx is already a plain `proxy_pass` to harmonia from the redirect-work
commit — no nginx change needed.)

- [ ] **Step 3: Build the patched package + ghostgate toplevel**
```bash
cd /home/numinit/systems
git add pkgs/harmonia/substitute-on-miss.patch devices/ghostgate/default.nix
nix build --no-link --impure --expr '(builtins.getFlake "git+file:///home/numinit/systems").nixosConfigurations.ghostgate.config.services.harmonia.package'
nix build --no-link .#nixosConfigurations.ghostgate.config.system.build.toplevel
```
Expected: `importCargoLock` vendors the new `lru`/xz deps from the patched
lock (no cargoHash); both builds succeed.

- [ ] **Step 4: Commit**
```bash
git commit --no-gpg-sign -m "ghostgate: harmonia stream-through caching NAR endpoint"
```

---

### Task 10: Docs

**Files:**
- Modify: `/home/numinit/systems/docs/event-network.md`
- Modify: `/home/numinit/systems/docs/superpowers/specs/2026-07-16-harmonia-substitute-on-miss-design.md` (add a superseded-by pointer)

- [ ] **Step 1: event-network.md** — replace the "302-redirects the client" description of `cache.nixos.lv` with the stream-through behavior:
```markdown
- `cache.nixos.lv` is harmonia over ghostgate's dedup+zstd store. A patched
  harmonia (`pkgs/harmonia/substitute-on-miss.patch`) makes misses a
  stream-through cache: on a narinfo miss it serves upstream's narinfo
  rewritten to point at its own NAR endpoint (signature intact, Compression
  none); on the NAR request it fetches the upstream `.nar.xz` once, decodes
  it, and fans the bytes to the client(s) and into the store — one uplink
  fetch, no amplification. Concurrent requests for the same path coalesce onto
  one job; the store import always completes even if clients drop. See
  `docs/superpowers/specs/2026-07-16-harmonia-streamthrough-nar-design.md`.
```

- [ ] **Step 2: superseded pointer** — top of the v3 substitute-on-miss spec:
```markdown
> **Superseded by** `2026-07-16-harmonia-streamthrough-nar-design.md` (the
> 302-redirect + background warm was replaced by a stream-through cache to
> remove fetch amplification). The mirror-decommission portions of this spec
> still stand.
```

- [ ] **Step 3: Commit**
```bash
git add docs/event-network.md docs/superpowers/specs/2026-07-16-harmonia-substitute-on-miss-design.md
git commit --no-gpg-sign -m "docs: event-network + spec pointer for the stream-through cache"
```

---

### Task 11: Operator deploy + live verification (yours)

- [ ] **Step 1:** Re-sign the systems commits; deploy ghostgate.
- [ ] **Step 2:** Live check from the noc LAN, with a path absent from ghostgate's store but present upstream:
```bash
h=<hashpart-of-a-fresh-unstable-path>
curl -sD- https://cache.nixos.lv/$h.narinfo -o /dev/null   # 200, URL: nar/<h>-... , Compression: none
nix copy --from https://cache.nixos.lv /nix/store/$h-<name>  # streams via harmonia
ssh ghostgate "nix path-info /nix/store/$h-<name>"           # now local (converged)
curl -s https://cache.nixos.lv/metrics | grep -E 'harmonia_nar_jobs|narinfo_misses'
```
- [ ] **Step 3:** Coalescing spot-check: two parallel `nix copy` of the same fresh path → `harmonia_nar_jobs_started_total` advances by 1, not 2.
