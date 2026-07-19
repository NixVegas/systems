{
  lib,
  nixpkgs,
  stdenv,
  system,
  nixos-pagefind-build,
}:

let
  systems = [
    system
  ];

  # release.nix builds the version suffix as `revCount - <offset>`, where
  # <offset> is the absolute revCount at the point this release branched off
  # (a magic constant that gets bumped every release, so the suffix counts
  # "commits since the branch"). A GitHub flake input carries no revCount, so
  # we have no real commit count to feed it. Rather than hand it a bare
  # lastModifiedDate (which then gets `- <offset>` applied and turns into a
  # nonsensical near-timestamp), scrape the exact offset back out of release.nix
  # and pre-add it, so the subtraction cancels and the suffix ends up as the
  # honest lastModifiedDate. Gross, but self-correcting: if nixpkgs changes the
  # constant the regex follows it, and it falls back to 0 (today's behaviour)
  # if the line ever stops matching.
  releaseNixText = builtins.readFile "${nixpkgs}/nixos/release.nix";
  revCountOffset =
    let
      line = lib.findFirst (l: lib.hasInfix "revCount - " l) "" (lib.splitString "\n" releaseNixText);
      m = builtins.match ".*revCount - ([0-9]+).*" line;
    in
    if m == null then 0 else lib.toInt (builtins.head m);

  release = import "${nixpkgs}/nixos/release.nix" {
    # A released channel: gives a "26.05.<n>" suffix, not "26.05beta<n>". This
    # is the top-level arg release.nix actually reads (a `stableRelease` inside
    # the `nixpkgs` set below was silently ignored).
    stableBranch = true;
    nixpkgs = {
      outPath = nixpkgs;
      inherit (nixpkgs) shortRev;
      # No revCount from a GitHub flake input; feed lastModifiedDate plus the
      # offset release.nix will subtract, so the suffix lands on the raw
      # lastModifiedDate (see revCountOffset above).
      revCount = nixpkgs.revCount or (lib.toInt nixpkgs.lastModifiedDate + revCountOffset);
    };
    supportedSystems = systems;
    configuration = import ../../modules/onboarding/nix-vegas-defaults.nix;
  };
  inherit (release) channel;
  inherit (release) iso_minimal iso_graphical sd_image;
  inherit (release) netboot proxmoxImage;
  inherit (release) manualHTML;

  pagefind-build = lib.genAttrs systems (system: nixos-pagefind-build);

  nixpkgs-channels = lib.genAttrs systems (systems: channel);

  maybeLink =
    artifact: system: outPath: systemSpecific:
    if lib.hasAttr system artifact then
      ''
        mkdir -p $out/systems/${system}
        ln -s ${artifact.${system}} $out/systems/${system}/${outPath}
        ${lib.optionalString (!systemSpecific) ''
          if [ ! -e $out/${outPath} ]; then
            # Create a version that doesn't have the system attached
            ln -s $out/systems/${system}/${outPath} $out/${outPath}
          fi
        ''}
      ''
    else
      "true";
in
stdenv.mkDerivation {
  pname = "nixos-lv-onboarding-artifacts";
  inherit (channel) version;
  inherit (nixpkgs) rev;

  phases = [ "installPhase" ];

  installPhase = ''
    ${lib.concatMapStringsSep "\n" (system: ''
      ${maybeLink iso_minimal system "iso-minimal" true}
      ${maybeLink iso_graphical system "iso-graphical" true}
      ${maybeLink sd_image system "sd-image" true}
      ${maybeLink netboot system "netboot" true}
      ${maybeLink proxmoxImage system "proxmox" true}
      ${maybeLink manualHTML system "manual" false}
      ${maybeLink pagefind-build system "search" false}
      ${maybeLink nixpkgs-channels system "channel" false}
    '') systems}
    echo "$version" > $out/version
    echo "$rev" > $out/rev
  '';
}
