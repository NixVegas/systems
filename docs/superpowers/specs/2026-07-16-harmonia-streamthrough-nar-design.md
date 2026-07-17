# harmonia stream-through caching NAR endpoint

**Date:** 2026-07-16
**Status:** approved

## Purpose

The shipped substitute-on-miss (302 redirect + background warm) is
non-blocking but **fetch-amplifies**: a first-time miss pulls the NAR from
cache.nixos.org twice — once by the redirected client, once by the daemon
warm. Replace it with an in-process **streaming cache**: a single upstream
fetch per unique path serves every concurrent client *and* imports into
ghostgate's dedup store, with no amplification and no client stall.

This supersedes the redirect/warm mechanism in
`docs/superpowers/specs/2026-07-16-harmonia-substitute-on-miss-design.md`
(v3). The mirror decommission and the ghostgate/citadel/brass nginx
simplification from that spec stand; only the harmonia patch internals and
the `narinfo`/`nar` handlers change.

## Key facts (verified in harmonia 3.1.0 source)

- **narinfo fingerprint** (`harmonia-store-core/src/signature.rs:396`) is
  `1;<store-path>;<nar-hash>;<nar-size>;<refs>` — it does **not** cover
  `URL`, `Compression`, `FileHash`, or `FileSize`. So harmonia can rewrite
  those and re-serve cache.nixos.org's `Sig` unchanged, still valid.
- **`add_to_store_nar`** (`harmonia-store-remote/src/client.rs:583`) takes a
  streaming async reader and imports a NAR into the store via the daemon,
  which verifies the NAR hash against the supplied `ValidPathInfo` and
  enforces trusted-keys. This is the cache-write sink.
- harmonia already streams NARs out with `NarByteStream` + actix
  `SizedStream` (`harmonia-cache/src/nar.rs`); `async-compression` is a dep
  (needs the `xz` feature alongside `bzip2`).

## Behaviour

### narinfo miss (`GET /<hash>.narinfo`)

1. HTTPS GET `<miss_upstream_url>/<hash>.narinfo` (tiny).
2. Rewrite: `URL` → `nar/<outhash>-<narhash>.nar` (nix-serve form, carries
   both the store-path hash and the NAR hash); `Compression: none`;
   `FileHash` = `NarHash`; `FileSize` = `NarSize`. Keep `StorePath`,
   `NarHash`, `NarSize`, `References`, `Deriver`, `Sig` verbatim.
3. **Cache** the parsed upstream narinfo (store path, compressed upstream
   `URL`, and the `ValidPathInfo` fields) in the narinfo LRU (below), keyed
   by the store-path hash — so the NAR request that follows needn't re-fetch.
4. Serve `200`. Instant — only the small narinfo crossed the uplink. No job
   is started here (started lazily on the NAR request).
5. Upstream narinfo 404/error → fall back to the stock 404 (client uses its
   own next substituter).

### nar miss (`GET /nar/<outhash>-<narhash>.nar`, path not in store)

Look up or create a **per-path streaming job** keyed by the store path, then
attach this client to it.

## Components

### narinfo LRU cache
A bounded in-memory `Mutex<LruCache<StorePathHash, CachedNarInfo>>` where
`CachedNarInfo` holds the store path, the upstream compressed `URL`, and the
`ValidPathInfo` fields — everything the job needs to skip its own narinfo
re-fetch. **Configurable max entries and TTL** (`miss_narinfo_cache_size`,
`miss_narinfo_cache_ttl`); entries carry an insertion `Instant` and are
treated as absent past the TTL (checked on read), evicted by LRU past the
size. Populated by the narinfo-miss handler; consulted by the job. Purely an
optimization — a miss/expiry just costs one small re-fetch. No persistence
(lost on restart, by design). Implementation: prefer a minimal dep (e.g. the
`lru` crate + per-entry timestamp) over a heavyweight cache library; settle
in the plan.

### Job registry
`Mutex<HashMap<StorePath, Weak<Job>>>`. The first requester for a path
creates the `Arc<Job>`; concurrent requesters upgrade the `Weak` and attach
to the existing job (coalescing → one upstream fetch). The entry is dropped
when the last `Arc` goes and the job has finished.

### Job (decoupled — the cache is the durable goal)
Owns and runs to completion **regardless of client attach/detach** (converge
even if every client disconnects):

1. Obtain the full `StorePath`, the upstream compressed `URL`
   (`nar/<filehash>.nar.xz`), and the `ValidPathInfo` fields (narHash,
   narSize, references, deriver, ca, sigs): **look them up in the narinfo LRU
   first** (populated by the preceding narinfo request); on a cache miss or
   expiry, re-fetch `<miss_upstream_url>/<outhash>.narinfo` (tiny) and
   backfill the cache.
2. HTTPS GET `<miss_upstream_url>/nar/<filehash>.nar.xz` (streaming).
3. `async-compression` xz-decode the stream.
4. Per decoded chunk, **fan-out**:
   - **store sink** — write to the `add_to_store_nar` daemon reader
     (awaited; gates the job at disk speed). This is the priority; it must
     receive every byte.
   - **broadcast** — `tokio::sync::broadcast::Sender<Bytes>` (bounded ring);
     non-blocking send. Live client streams subscribe.
5. On completion: `add_to_store_nar` returns, the daemon has verified the NAR
   hash and made the path valid. Job marks done; late/parked arrivals now
   serve from the local store via the normal harmonia path.

The job's pace is gated only by the upstream read (uplink) and the store
sink (disk) — never by a client.

### Client response
A `SizedStream` (content-length = `NarSize`, `Compression: none`) fed from a
`broadcast::Receiver` mapped to `Stream<Item = Result<Bytes>>`. Live clients
get bytes as the job produces them (no stall). A client slower than the
uplink `Lagged`s past the ring capacity → its stream is dropped (it errors
and retries against its own next substituter); **the job is unaffected**.

## Error handling

- **Upstream fetch fails / truncates:** job errors; each client `SizedStream`
  ends short of `NarSize` → clients error and retry. `add_to_store_nar` gets
  an incomplete NAR → hash check fails → **nothing partial in the store**.
  The registry entry is removed so the next request re-elects a lead.
- **Daemon import error** (e.g. sig rejected, disk full): logged, path not
  imported; client streams still complete from the broadcast (they got a
  valid NAR). Convergence is simply retried on the next miss.
- **All clients disconnect:** job continues; store still converges (the
  stated priority — "lose the clients, keep the cache").
- **Lead client disconnects:** no effect; the job is not owned by any client.

## Config (`services.harmonia.cache.settings`)
Unchanged surface from v3:
- `substitute_on_miss = false` (default off = stock 404).
- `miss_upstream_url = "https://cache.nixos.org"` (narinfo + NAR source; must
  be `https://`).
- `miss_daemon_socket = "/nix/var/nix/daemon-socket/socket"` (default; the
  `add_to_store_nar` target).
- `miss_narinfo_cache_size` (max entries in the narinfo LRU; default e.g.
  `8192`).
- `miss_narinfo_cache_ttl` (entry TTL, seconds; default e.g. `3600`).

## Observability
Extend the existing prometheus counters:
`narinfo_misses_total`, `nar_jobs_started_total`, `nar_jobs_completed_total`,
`nar_jobs_failed_total`, `nar_clients_attached_total`,
`nar_clients_dropped_total` (lagged).

## Metrics of success
- One upstream NAR fetch per unique missed path under N concurrent clients
  (assert in test).
- Client never blocks on the narinfo; NAR streams as it downloads (no stall).
- Store converges for a missed path even if all clients disconnect.
- A mid-stream upstream truncation leaves the store unchanged.

## Testing
- **Unit:** narinfo rewrite (URL/compression/filehash swapped; fingerprint
  fields + Sig byte-preserved); `ValidPathInfo` assembly from a canned
  narinfo (references/deriver/ca/sig parsed); narinfo LRU (size eviction, TTL
  expiry-on-read, backfill).
- **Integration** (scratch store + a fake HTTPS/HTTP upstream serving a known
  `.nar.xz`): N concurrent `GET /nar/<outhash>-<narhash>.nar` → exactly one
  upstream fetch (coalescing); every client body byte-identical to the known
  NAR; `nix path-info` shows the path valid afterward; a lead-client
  disconnect still leaves the path valid; a truncated-upstream case leaves
  the store unchanged and errors clients.
- **Build/gates:** `applyPatches` + `importCargoLock` `pkgs.harmonia` builds;
  chroot integration + clippy `-D warnings` clean; ghostgate toplevel builds.
- **Live:** `nix copy --from https://cache.nixos.lv <store-absent path>`
  succeeds served by harmonia; `nix path-info` shows it local afterward;
  prometheus `nar_jobs_*` advance; a second client during the first's stream
  triggers no second upstream fetch (watch the job counter).

## Carrying the patch
Same as v3: `pkgs/harmonia/substitute-on-miss.patch` via `applyPatches` +
`cargoDeps = importCargoLock { lockFile }` (vendors the `xz`-featured
`async-compression` and any new registry deps straight from the patched
lock, no cargoHash). Upstream PR to nix-community/harmonia after the event.

## Out of scope
- Serving the client zstd/xz-compressed (LAN is free; uncompressed is the
  natural tee point).
- Persisting jobs across harmonia restarts (a restart mid-stream just errors
  in-flight clients; the next request restarts the job).
- Range requests / resumable NAR downloads.
