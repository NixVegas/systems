# nixpkgs cache storage study — results

Empirical comparison run on ghostgate during nix.vegas 2026: store a full
nixpkgs corpus two ways and measure on-disk size.

- **Upstream xz NARs** — cache.nixos.org's `.nar.xz` files stored verbatim
  (`ghostgate-nar/local/nar`, an nginx `proxy_store` pull-through mirror).
- **Dedup+zstd store** — the unpacked store paths in a ZFS dataset with
  `compression=zstd` + `dedup=on` (`ghostgate/local/nix`; what harmonia serves).

Both datasets on identical 3.62 TiB NVMe. Design/method:
`docs/superpowers/specs/2026-07-14-nar-mirror-study-design.md`.

## Growth series

| Date | Channels | Corpus (unpacked, logical) | Upstream xz NARs (physical) | Dedup+zstd store (physical) | zstd | dedup | Store saving |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-07-15 | 26.05 + ⅓ unstable | 7.68 TB | 2.04 TB | 1.65 TB | 2.63× | 1.94× | 19% |
| 2026-07-16 | 26.05 + unstable | 9.26 TB | 2.49 TB | 1.89 TB | 2.58× | 2.10× | 24% |
| 2026-07-17 | 25.11 + 26.05 + unstable | 13.88 TB | 3.53 TB | 2.77 TB | 2.59× | 2.15× | 22% |

Effective ratio (corpus ÷ physical): xz ~3.7–3.9× throughout; dedup+zstd
4.6× → 4.9× → 5.0×.

Marginal cost of adding 25.11 to the two-channel set (physical): xz +1.04 TB
vs. dedup+zstd +0.88 TB.

## Raw measurements

`zfs get -p used,logicalused,compressratio` (bytes) and
`zpool list -o alloc,cap,dedupratio`:

**2026-07-15** (26.05 done, ~⅓ through unstable)
```
ghostgate-nar/local/nar  used 2037257027584  logicalused 2047440783360  compressratio 1.00
ghostgate/local/nix      used 3207767552000  logicalused 7677311241216  compressratio 2.63
ghostgate      alloc 1.62T  cap 44%  dedup 1.94x
ghostgate-nar  alloc 1.81T  cap 49%  dedup 1.02x
```

**2026-07-16** (26.05 + unstable)
```
ghostgate-nar/local/nar  used 2494227869696  logicalused 2506753973248  compressratio 1.00
ghostgate/local/nix      used 3964940992512  logicalused 9257192118784  compressratio 2.58
ghostgate      alloc 1.86T  cap 51%  dedup 2.10x
ghostgate-nar  alloc 2.20T  cap 60%  dedup 1.03x
```

**2026-07-17** (25.11 + 26.05 + unstable — final)
```
ghostgate-nar/local/nar  used 3534895222784  logicalused 3553255392768  compressratio 1.00
ghostgate/local/nix      used 5951536689152  logicalused 13882483981824  compressratio 2.59
ghostgate      alloc 2.74T  cap 75%  dedup 2.15x
ghostgate-nar  alloc 3.12T  cap 86%  dedup 1.03x
```

## Findings

- Per-NAR xz compresses each NAR *better in isolation* (~3.8× vs zstd ~2.6×),
  but it is blind across NAR boundaries. ZFS dedup recovers the
  cross-channel / cross-package file sharing xz can't see; the dedup ratio
  climbs as related channels accumulate (1.94× → 2.10× → 2.15×), so the
  store's advantage widens with scale.
- Final result (three closely-related branches): the dedup+zstd store holds
  the same corpus in **~0.76 TB (22%) less** than verbatim upstream xz.
- The xz mirror hit 86% of a 4 TB drive at three channels; the dedup+zstd
  store of the same corpus sat at 75% with headroom.

## Methodology notes

- xz physical = dataset `used` (`compressratio 1.00`, so `used ≈ on-disk`;
  xz output is incompressible to zstd and near-undedupable).
- Store physical = dataset `used` ÷ pool `dedupratio` — ZFS charges dataset
  `used` before dedup credit and reports dedup only at the pool level.
  Cross-checked against `zpool list ALLOC` (the whole-pool on-disk figure).
- Corpus (the normalizer) = dataset `logicalused` (uncompressed, undeduped).
- Dedup's cost is RAM (the DDT); capture `zpool status -DD ghostgate` for the
  entry count when quoting the ratio.
