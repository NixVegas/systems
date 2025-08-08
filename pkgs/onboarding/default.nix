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
  release = import "${nixpkgs}/nixos/release.nix" {
    nixpkgs = {
      outPath = nixpkgs;
      inherit (nixpkgs) shortRev;
      stableRelease = true;
      # We don't have a rev count, but do have a lastModifiedDate
      revCount = nixpkgs.revCount or nixpkgs.lastModifiedDate;
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
