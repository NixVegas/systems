# 2026 onsite site build: parameterized revival

**Date:** 2026-07-16
**Status:** approved

## Purpose

Restore the two-flavor nix.vegas site build for 2026: a **default (offsite)**
build with no NixOS artifacts (Netlify + crystal keep serving this,
unchanged) and an **onsite** build that embeds the onboarding artifacts
(ISOs, VMAs, netboot, channel tarball, manual, pagefind search) and renders
them on `/2026/onsite`, deployed to ghostgate as `nixos.lv` for the event.
The 2025 mechanism was removed in nix.vegas commit `4deb0cb` but is fully
recoverable from history; this revives it parameterized rather than
verbatim.

Two repos are involved:

- **nix.vegas** (github:NixVegas/nix.vegas; local clone
  `~/projects/nix.vegas`, work lands on a branch the user pushes)
- **systems** (this repo: overlay wiring + ghostgate nginx)

## Components

### 1. Site: `pkgs/nix-vegas-site/onsite.nix` (revived, parameterized)

Restored from `4deb0cb^`, an `overrideAttrs` flavor of the base site:

- Parameters: `onboardingArtifacts ? emptyDirectory`,
  `baseUrl ? "https://nixos.lv/"` (new — 2025 hardcoded it).
- `preBuild` (tomlq, as before): set `base_url = baseUrl`,
  `extra.onsite = true`, and discover from the artifacts tree:
  `extra.nixpkgs_rev` (`nixos/rev`), `extra.nixos_version`
  (`nixos/version`), `extra.isos` (`systems/**/*.iso`), `extra.vmas`
  (`systems/**/*.vma.zst`), `extra.manual`, `extra.search` (index.html
  paths), `extra.channel` (`channel/*.tar.xz`).
- `postInstall`: symlink the artifacts as `$out/public/nixos` (this is what
  ghostgate's existing `/boot/*` netboot aliases point into).
- `default.nix`: restore `passthru.onsite = callPackage ./onsite.nix args`.
- `flake.nix`: restore `packages.nixVegasOnsite` and
  `packages.nixVegasOffsite` (alias of default; default unchanged so
  Netlify/crystal need no changes).

### 2. Site: shortcode defaults

Every shortcode that reads `config.extra.*` renders a sensible default when
the value is empty (the offsite build), instead of an empty stump:

- List shortcodes (`nixosIsos`, `nixosProxmoxImages`): if the list is empty,
  render `<em>Available on the event network.</em>` instead of an empty
  `<ul>`.
- Link shortcodes (`nixosDocs`, `getNixpkgs`, `nixpkgsCommitLink`,
  `nixpkgsUrl`, `nixpkgsVerifyUrl`): if the underlying value is empty,
  render the anchor text (or a dash) without a dead link.
- Value shortcodes (`nixpkgsRev`, `nixpkgsVersion`): render `(onsite)` when
  empty.
- `installNix`: audit at implementation time; same principle.

Exact per-shortcode treatment is settled in the plan after reading each
template; the principle is: **the offsite render of /2026/onsite must look
intentional, with no dead links or empty lists.**

### 3. Site: `content/2026/onsite.md`

Port the 2025 body with:

- Version references bumped (25.05 → 26.05 in prose and search.nixos.org
  option links).
- The cache section rewritten for the 2026 split: `cache.nixos.lv` is the
  local (harmonia) cache of the event store; `upstream.cache.nixos.lv` is
  the pull-through mirror of cache.nixos.org — the URL that keeps working
  transparently offsite. (The 2025 claim that cache.nixos.lv itself proxies
  upstream is no longer true.)
- Everything artifact-related stays shortcode-driven.

### 4. Site: no template changes

Navigation/hero/year_home stay flattened as `4deb0cb` left them. Both builds
ship `/2026/onsite`; discoverability onsite is nginx's job (below).

### 5. Systems: overlay + packages

Exactly the 2025 wiring, revived:

```nix
nix-vegas-site-onsite = nix-vegas-site.packages.${system}.nixVegasOnsite.override {
  onboardingArtifacts = nixos-lv-onboarding-artifacts;
};
```

exposed via `packages` (`inherit (pkgs) nix-vegas-site-onsite;`) for direct
`nix build`. `nix-vegas-site` (default) stays for crystal.

### 6. Systems: ghostgate nginx

- `public` switches from `pkgs.nix-vegas-site` to
  `pkgs.nix-vegas-site-onsite` — the `/boot/*` aliases (bzImage, initrd,
  netboot.ipxe) stop dangling.
- New `locations."= /".return = "302 /2026/onsite";` — hitting
  `https://nixos.lv/` lands on the onsite page. All other paths serve the
  site as today.

### 7. Landing sequence

1. Site changes on a branch in `~/projects/nix.vegas`; user reviews/pushes
   (signing + GitHub auth are theirs).
2. Until the branch is on GitHub, systems-side testing builds against the
   local clone path.
3. After push: `nix flake update nix-vegas-site` (input follows the repo's
   default branch — if the branch merges to main, a plain lock bump; the
   input URL is `github:NixVegas/nix.vegas`).
4. Deploy ghostgate.

## Error handling

- Onsite build with empty/partial artifacts: every tomlq discovery is
  already `|| true`-guarded (empty lists/strings) — the page renders with
  the shortcode defaults from §2 instead of failing.
- Offsite build: byte-for-byte unaffected (no config/template changes reach
  it except the shortcode defaults, which only change the empty-value
  render).

## Testing

- Local clone: `nix build .#default` and `nix build .#nixVegasOnsite` (empty
  artifacts) both succeed; onsite output has `public/nixos` symlink,
  rewritten `base_url`, and `/2026/onsite/index.html` renders the shortcode
  defaults (no dead links, no empty `<ul>`).
- Diff check: default build output unchanged vs. pre-change default build
  except the shortcode-default renders.
- Systems: `nix build .#nix-vegas-site-onsite` (heavy — builds ISOs/netboot/
  manual like 2025) and the ghostgate toplevel; verify
  `public/nixos/systems/x86_64-linux/netboot/bzImage` resolves inside the
  built site package and `/2026/onsite/index.html` lists the ISOs.
- Post-deploy: `curl -I https://nixos.lv/` → 302 to `/2026/onsite`; the
  page lists ISOs; `curl -I https://nixos.lv/boot/netboot.ipxe` → 200.

## Out of scope

- Netlify/crystal serving changes (default build is untouched).
- Template/navigation restructuring.
- Onboarding-artifacts content changes (channel set, image types).
- 2025 archive content.
