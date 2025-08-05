{
  lib,
  nixpkgs,
  stdenv,
  system,
  runCommand,
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
      revCount = "-dc33";
    };
    supportedSystems = systems;
    configuration = import ../../modules/onboarding/onboardee.nix;
  };
  inherit (release) channel;
  inherit (release) iso_minimal iso_graphical sd_image;
  inherit (release) netboot proxmoxImage;
  inherit (release) manualHTML;

  pagefind-build = lib.genAttrs systems (system: nixos-pagefind-build);

  nixpkgs-tarball = runCommand "nixpkgs-${channel.version}-tarball" { } ''
    mkdir -p $out
    GZIP=-9 tar -C ${nixpkgs} -czf $out/nixpkgs-${channel.version}.tar.gz .
  '';

  nixpkgs-tarballs = lib.genAttrs systems (systems: nixpkgs-tarball);

  maybeLink = artifact: system: outPath: systemSpecific:
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
      ${maybeLink nixpkgs-tarballs system "nixpkgs" false}
    '') systems}
    echo "$version" > $out/version
  '';
}
