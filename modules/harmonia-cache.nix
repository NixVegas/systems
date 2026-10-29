# Shared patched stream-through harmonia binary cache.
#
# harmonia + our substitute-on-miss patch (pkgs/harmonia/substitute-on-miss.patch;
# spec: docs/superpowers/specs/2026-07-16-harmonia-substitute-on-miss-design.md).
# On a narinfo miss harmonia serves upstream's narinfo rewritten to point at its
# own NAR endpoint; on the NAR request it fetches the upstream .nar.xz once (over
# its own HTTPS), decodes it, and fans the bytes to the client(s) AND into the
# store via the nix daemon — one uplink fetch, no amplification, no stall.
#
# Used by ghostgate (upstream cache.nixos.org) and the VP2420s (upstream
# cache.nixos.lv = ghostgate, so a table's misses hop 2420 -> ghostgate ->
# internet, deduped once at ghostgate). Each host fronts harmonia's [::]:5000
# with its own nginx vhost.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixVegas.harmoniaCache;

  # Patch the source, then vendor from the patched Cargo.lock via
  # cargoLock.lockFile (importCargoLock). The default cargoHash path
  # (fetchCargoVendor) normalizes workspace-internal path deps out of the
  # vendored Cargo.lock, so its consistency check can never match a lock that
  # adds harmonia-store-remote/harmonia-protocol to harmonia-cache ("Cargo.lock
  # is not the same in vendor"). importCargoLock vendors straight from the
  # lockfile with no such diff — and needs no hash, since the patch adds only
  # in-tree path deps, no new registry crates.
  patchedSrc = pkgs.applyPatches {
    name = "harmonia-substitute-on-miss-src";
    inherit (pkgs.harmonia) src;
    patches = [ ../pkgs/harmonia/substitute-on-miss.patch ];
  };
  patchedHarmonia = pkgs.harmonia.overrideAttrs (prev: {
    src = patchedSrc;
    cargoDeps = pkgs.rustPlatform.importCargoLock {
      lockFile = "${patchedSrc}/Cargo.lock";
    };
  });
in
{
  options.nixVegas.harmoniaCache = {
    enable = lib.mkEnableOption "the patched stream-through harmonia binary cache";

    upstreamUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://cache.nixos.org";
      example = "https://cache.nixos.lv";
      description = ''
        Upstream binary cache harmonia stream-through fetches from on a narinfo
        miss. ghostgate points at the real cache.nixos.org; the VP2420 edge
        caches point at cache.nixos.lv (ghostgate) so misses fan in there.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.harmonia = {
      package = patchedHarmonia;
      cache = {
        enable = true;
        settings = {
          # Serve raw NARs: harmonia 3.x otherwise zstd-encodes on the fly for
          # Accept-Encoding: zstd clients. Serve the dedup'd store as-is.
          enable_compression = false;
          # Stream-through cache: on a narinfo miss fetch upstream once, fan the
          # bytes to the client(s) and into the store.
          substitute_on_miss = true;
          miss_upstream_url = cfg.upstreamUrl;
          # In-flight narinfo LRU (low + self-cleaning; entries drop when their
          # NAR job completes).
          miss_narinfo_cache_size = 1024;
          miss_narinfo_cache_ttl = 600;
        };
      };
    };

    # Stock harmonia is serve-only (it only accepts on a socket-activated fd and
    # talks to the nix daemon over AF_UNIX), so its unit is network-sandboxed:
    # PrivateNetwork = true, RestrictAddressFamilies = [ "AF_UNIX" ],
    # IPAddressDeny = "any". The stream-through substitute-on-miss makes outbound
    # HTTPS to the upstream — reqwest can't even socket(AF_INET) under that
    # sandbox, so every miss silently fell back to a stock 404. Open the unit up
    # just enough to reach upstream. (The daemon socket stays AF_UNIX.)
    systemd.services.harmonia.serviceConfig = {
      PrivateNetwork = lib.mkForce false;
      RestrictAddressFamilies = lib.mkForce [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      IPAddressDeny = lib.mkForce "";
    };
  };
}
