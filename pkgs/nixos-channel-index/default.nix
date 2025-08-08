{
  nixpkgs,
  stdenvNoCC,
  nix-index,
  nss_wrapper,
  resolv_wrapper,
  nix,
}:

# This doesn't work. Even if we have literally everything in /nix/store we still have to hit a binary cache.
stdenvNoCC.mkDerivation {
  name = "nixos-channel-index";

  phases = [
    "configurePhase"
    "buildPhase"
    "installPhase"
  ];

  nativeBuildInputs = [
    nix-index
    nix
  ];

  configurePhase = ''
    runHook preConfigure
    mkdir -p nix/var/nix
    export NIX_STATE_DIR="$(realpath nix)/var/nix"
    export NIX_CONFIG="extra-experimental-features = nix-command flakes"
    runHook postConfigure
  '';

  # from https://github.com/NixOS/nixos-channel-scripts/blob/master/mirror-nixos-branch.pl#L260
  buildPhase = ''
    runHook preBuild

    # Due to a nix bug, the command only completes the second time.
    args=(-f ${nixpkgs} -s x86_64-linux -s aarch64-linux)
    (
      export HOME="$(pwd)"
      export NSS_WRAPPER_HOSTS="$HOME/.fakehosts"
      export RESOLV_WRAPPER_HOSTS="$HOME/.fakedns"
      echo "127.0.0.1 cache.nixos.org" > "$NSS_WRAPPER_HOSTS"
      echo "A cache.nixos.org 127.0.0.1" > "$RESOLV_WRAPPER_HOSTS"
      export LD_PRELOAD="${nss_wrapper}/lib/libnss_wrapper.so:${resolv_wrapper}/lib/libresolv_wrapper.so"
      set -x
      nix-channel-index "''${args[@]}" || nix-channel-index "''${args[@]}"
      set +x
    )

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    mv programs.sqlite debug.sqlite $out/
    runHook postInstall
  '';
}
