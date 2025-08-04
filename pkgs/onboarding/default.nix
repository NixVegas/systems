{
  lib,
  nixpkgs,
  stdenv,
}:

let
  systems = [
    "x86_64-linux"
    "aarch64-linux"
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
  inherit (release) manualHTML;
in
stdenv.mkDerivation {
  pname = "nixos-lv-onboarding-artifacts";
  inherit (channel) version;

  phases = [ "installPhase" ];

  installPhase = ''
    mkdir $out
    ${lib.concatMapStringsSep "\n" (system: ''
      ln -s ${iso_minimal.${system}} $out/$version
    '') systems}
  '';
}
