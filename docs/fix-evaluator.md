# `fix` — parallel Nix evaluator (status + gotchas)

[`fix`](https://github.com/psyclyx/fix) is a from-scratch, parallel Nix evaluator
(written in Zig). We carry it as a `flake = false` input (rev `fd675c2` at time of
writing) and it's on `PATH` as `fix`. The draw is **parallel evaluation**: a full
NixOS `system.build.toplevel` that `nix` evaluates single-threaded in ~2m39s,
`fix` does in ~1m8s wall (≈7× CPU parallelism).

As of the investigated revision it is **not** a drop-in replacement for
`nixos-rebuild` / `nix` — see limitations below. Treat it as a fast eval
spot-checker, not the source of truth, and keep using `nix` / `nixos-rebuild` for
actual switches.

## Repo-side requirement: never use `follows = ""`

`fix`'s flake-lock parser rejects the empty-string "follow-the-root" idiom.
`inputs.x.follows = ""` locks as `[]` — a follows edge pointing at the `root`
node, which has no `locked` entry — and `fix` errors:

```
error: evaluating flake: InvalidFlakeLock
```

(`nix` tolerates it; `fix`'s `buildNodeThunk` does not — see
`src/expr/vm/builtins/flakes.zig`.)

**Fix:** alias unused/neutralized inputs to a concrete input instead. This
de-dupes them identically but keeps the lock `fix`-parseable:

```nix
# flake.nix  (hydra input) -- do NOT reintroduce follows = ""
inputs = {
  foreman.follows = "nixpkgs";      # was ""
  treefmt-nix.follows = "nixpkgs";  # was ""
  nixpkgs.follows = "nixpkgs";
};
```

To find any offending edges in the current lock:

```bash
python3 - <<'PY'
import json; L=json.load(open("flake.lock")); N=L["nodes"]
def f(t):
    if isinstance(t,str): return t
    c="root"
    for s in t:
        n=N.get(c)
        if not n or "inputs" not in n or s not in n["inputs"]: return None
        c=f(n["inputs"][s])
        if c is None: return None
    return c
print([(k,name,t) for k,v in N.items() for name,t in (v.get("inputs") or {}).items() if f(t)=="root"] or "clean")
PY
```

## Current limitations (why `fix switch` isn't usable yet)

Two distinct `fix`-vs-`nix` behaviours (verified by evaluating the exact attrs):

**A. `builtins.path` on an already-store path is a no-op in `fix`.** nixpkgs
re-ingests its own flake source — `pkgs.path` is effectively
`builtins.path { path = <nixpkgs store source>; }`. `nix` content-addresses that
into a NEW store path (`/nix/store/grsqj…-6w1nw…-source`, the hash wrapping the
input's basename `6w1nw…-source`); `fix` returns the input path unchanged
(`/nix/store/6w1nw…-source`). Same content, different store path. (`nix`'s value
is a copy; `fix`'s is the raw input — neither uses `~/.cache` here.)

**B. A flake input's `sourceInfo.outPath` isn't a store path in `fix`.** Under
`fix` `nixpkgs.outPath` is `~/.cache/fix/tarball/<h>/source`, not `/nix/store/…`.
(This is a *different* attribute from `pkgs.path` above — it's what bites pure
mode, not the drv divergence.)

Consequences:

1. **Derivations embedding `pkgs.path` diverge (cause A).** Anything doing
   `substitute ${pkgs.path}/…` (e.g. `modules/limine-safepath.nix`) references
   `grsqj…` under `nix` but `6w1nw…` under `fix` → different `.drv`. Confirmed
   with `nix-diff`: the only semantic diffs in citadel's `toplevel` were this path
   and the version date (#3). Our config is correct under `nix`; the `pkgs.path`
   reference just makes the divergence visible (most configs never touch it).
2. **Pure eval forbids the cache paths (cause B).** `fix instantiate` /
   `fix switch` (pure) fail with `access to absolute path '…/.cache/fix/…'
   forbidden in pure evaluation mode`, and on nixpkgs' source-bootstrap
   `import <nix/fetchurl.nix>` (`/__corepkgs__/fetchurl.nix`). `--impure` gets
   past them but see #1/#3.
3. **The store-write path drops `nixpkgs.lastModifiedDate`.** `fix instantiate`
   produced `nixos-system-citadel-26.05.19700101.…` (epoch 0) while `fix eval`
   and `nix` produce `…20260801.…` — an eval-vs-instantiate inconsistency in
   `fix`. (`fix` reads the input's `lastModified` correctly — `1785599192`,
   `20260801154632` — so it's not a lock bug.)

Also: evaluating a full `toplevel` is memory-hungry; **swap must be on** or `fix`
OOMs (exit 137). `dragonborn` now imports `modules/swap.nix`.

## Practical usage today

```bash
# Fast parallel eval spot-check (advisory only -- drv differs from nix; see #1):
fix eval --impure --flake ".#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"

# fix installables use --flake, not a bare `.#…` (that's read as a file path).
```

Do **not** `fix switch`; use `nixos-rebuild` / `nix`. Revisit when `fix`
ingests inputs into the store (that single change fixes #1–#3).

## Upstream report

> Three eval divergences from `nix` on a NixOS `toplevel`:
> (1) `builtins.path { path = <a store path>; }` returns the input unchanged
> instead of re-ingesting it, so `pkgs.path` (nixpkgs re-ingesting its own source)
> is `/nix/store/6w1nw…-source` vs `nix`'s content-addressed
> `/nix/store/grsqj…-6w1nw…-source` — any derivation embedding `pkgs.path` gets a
> different `.drv`.
> (2) A flake input's `sourceInfo.outPath` resolves to `~/.cache/fix/tarball/<h>/
> source` rather than a `/nix/store/…` path, so pure eval forbids it (and
> `import <nix/fetchurl.nix>`).
> (3) The store-write path drops nixpkgs' `lastModifiedDate` (→ `19700101`) that
> the eval path gets right. Separately, the lock parser rejects `follows = ""`
> (`[]` root edge) with `InvalidFlakeLock`.
