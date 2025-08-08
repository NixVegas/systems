{
  lib,
  nixpkgs,
  stdenvNoCC,
  symlinkJoin,
  writeText,
  runCommandNoCC,
  sqlite,
  pagefind,
  nixos-pagefind,
  nixos-pagefind-staticgen,
  nix,
}:

let
  initSql = writeText "init.sql" ''
    create table Programs (
        name        text not null,
        system      text not null,
        package     text not null,
        primary key (name, system, package)
    );
  '';

  fake-nixos-channel-index = runCommandNoCC "nixos-channel-index" { } ''
    mkdir -p $out
    ${lib.getExe sqlite} $out/programs.sqlite < ${initSql}
  '';

  nixpkgsWithIndexes = symlinkJoin {
    name = "nixpkgs-with-indexes";
    paths = [
      nixpkgs
      fake-nixos-channel-index
    ];
  };

  pagefindJson = stdenvNoCC.mkDerivation {
    name = "nixos-pagefind-json";

    phases = [
      "configurePhase"
      "buildPhase"
      "installPhase"
    ];

    nativeBuildInputs = [
      nix
      nixos-pagefind-staticgen
    ];

    configurePhase = ''
      runHook preConfigure
      mkdir -p nix/var/nix
      export NIX_STATE_DIR="$(realpath nix)/var/nix"
      export NIX_CONFIG="extra-experimental-features = nix-command flakes"
      export NIX_PATH=nixpkgs=${nixpkgsWithIndexes}
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      staticgen --channel nixpkgs --write-json pagefind.json
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      mv pagefind.json $out/
      runHook postInstall
    '';
  };
in
stdenvNoCC.mkDerivation {
  name = "nixos-pagefind";

  phases = [
    "buildPhase"
    "installPhase"
  ];

  nativeBuildInputs = [
    nixos-pagefind-staticgen
    pagefind
  ];

  buildPhase = ''
    runHook preBuild
    mkdir -p build
    staticgen --from-json ${pagefindJson}/pagefind.json --out build
    cp ${nixos-pagefind}/index.html build/
    pagefind --site build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mv build $out
    runHook postInstall
  '';
}
