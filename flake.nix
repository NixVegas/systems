{
  # Based on the Distractions stack we ran from DC30-DC32 — notably the
  # Nebula, MeshOS, and Mattermost config is derived from it.
  description = "Nix flake for deploying Nix Vegas infrastructure";

  inputs = {
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-prev.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkcs.url = "github:numinit/nixpkcs/v1.3";
    meshos.url = "github:numinit/MeshOS";
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    nixpkgs-gold.url = "github:Jaculabilis/nixpkgs-gold";

    hydra = {
      url = "github:NixOS/hydra/hydra.nixos.org";
      inputs = {
        # Neutralize these unused dev inputs by aliasing them to nixpkgs rather
        # than `follows = ""` (follow-the-root). An empty-string follows locks as
        # `[]` -- an edge pointing at the root node, which the `fix` evaluator
        # rejects (InvalidFlakeLock: the root node has no `locked`). Following a
        # concrete input de-dupes them identically and keeps the lock fix-parseable.
        foreman.follows = "nixpkgs";
        treefmt-nix.follows = "nixpkgs";
        nixpkgs.follows = "nixpkgs";
      };
    };

    great-value-hydra = {
      url = "github:NixVegas/great-value-hydra";
      inputs = {
        nixpkgs-prev.follows = "nixpkgs-prev";
        nixpkgs.follows = "nixpkgs";
        nixpkgs-unstable.follows = "nixpkgs-unstable";
      };
    };

    dcwifi = {
      url = "github:NixVegas/dcwifi";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-mailserver = {
      url = "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    freescout = {
      url = "github:NixVegas/freescout-nix-flake";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    nixos-pagefind = {
      url = "github:Jaculabilis/nixos-pagefind";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-vegas-site = {
      url = "github:NixVegas/nix.vegas";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    deploy-rs.url = "github:serokell/deploy-rs";
    flake-parts.url = "github:hercules-ci/flake-parts";

    tenstorrent-nix = {
      url = "github:RossComputerGuy/tenstorrent.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-vegas-ctf = {
      url = "github:NixVegas/ctf-server";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fix = {
      url = "github:psyclyx/fix";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      nixpkgs-unstable,
      nixpkgs-prev,
      nixpkgs-lib,
      nixpkgs-gold,
      hydra,
      great-value-hydra,
      dcwifi,
      nixpkcs,
      deploy-rs,
      nixos-pagefind,
      nix-vegas-site,
      meshos,
      tenstorrent-nix,
      nix-vegas-ctf,
      fix,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        flake-parts.flakeModules.easyOverlay
      ];

      flake =
        let
          inherit (nixpkgs-lib) lib;

          fixProject = import fix { };

          # Maps nixpkgs instances to their version.
          nixpkgsVersions = builtins.listToAttrs (
            map
              (nixpkgs: {
                name = lib.versions.majorMinor nixpkgs.lib.version;
                value = nixpkgs;
              })
              [
                nixpkgs
                nixpkgs-unstable
              ]
          );

          # Creates a NixOS system.
          nixosSystem =
            {
              # The NixOS version.
              version,
              # Modules to evaluate.
              modules ? [ ],
              # Any extra special args. The flake inputs are automatically provided,
              # as well as a hardcoded `extraModules`.
              specialArgs ? { },
            }:
            let
              extraModules = [ self.nixosModules.default ];
            in
            nixpkgsVersions.${version}.lib.nixosSystem {
              modules = modules ++ extraModules;
              specialArgs =
                inputs
                // {
                  inherit extraModules;
                }
                // specialArgs;
            };

          # Creates a system and a deploy config.
          deploySystem =
            {
              # The hostname.
              hostname,
              # The address for deployment. If null, no deploy config will be created.
              address ? null,
              # Any extra options for the system profile.
              profile ? { },
              ...
            }@args:
            let
              config = nixosSystem (
                builtins.removeAttrs args [
                  "hostname"
                  "address"
                  "profile"
                ]
              );
            in
            {
              nixosConfigurations.${hostname} = config;
            }
            // lib.attrsets.optionalAttrs (address != null) {
              deploy.nodes.${hostname} = {
                hostname = address;
                profiles.system = lib.attrsets.recursiveUpdate {
                  user = "root";
                  sshUser = "root";
                  sshOpts = [ "-t" ];
                  path = deploy-rs.lib.${config.pkgs.stdenv.hostPlatform.system}.activate.nixos config;
                } profile;
              };
            };

          # Converts an attrset mapping hostnames to configs into deploySystem calls.
          deploySystems =
            { ... }@args:
            lib.attrsets.foldlAttrs
              (
                acc: _: val:
                lib.attrsets.recursiveUpdate acc val
              )
              {
                nixosConfigurations = { };
                deploy.nodes = { };
              }
              (
                lib.mapAttrs (
                  name: value:
                  deploySystem (
                    value
                    // {
                      hostname = name;
                    }
                  )
                ) args
              );
        in
        {
          inherit (deploySystems (import ./systems.nix inputs)) nixosConfigurations deploy;

          nixosModules.default = {
            disabledModules = [ ];
            imports = [
              {
                nixpkgs.overlays = [
                  self.overlays.default
                  nixpkcs.overlays.default
                  nixpkgs-gold.overlays.gold
                ];
              }
              meshos.nixosModules.default
              # Big nebula socket buffers for every planned nebula host (brass,
              # the sole relay, benefits most). See the module for the measured
              # drop evidence.
              ./modules/nebula-socket-buffers.nix
              tenstorrent-nix.nixosModules.default
              nix-vegas-ctf.nixosModules.default
              hydra.nixosModules.hydra
              dcwifi.nixosModules.default
              fixProject.nixosModules.fix
            ];
            nixpkgs.config.gold = {
              acceptEula = true;
            };
          };
        };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          config,
          system,
          pkgs,
          ...
        }:
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              self.overlays.default
              deploy-rs.overlays.default
            ];
          };

          # let-bound: nix-vegas-site-onsite consumes the artifacts directly —
          # `pkgs.` doesn't see overlayAttrs from inside overlayAttrs, and
          # `rec` would shadow the nix-vegas-site flake input.
          overlayAttrs =
            let
              onboardingArtifacts = pkgs.callPackage ./pkgs/onboarding {
                inherit nixpkgs dcwifi;
              };
            in
            {
              nebula = pkgs.nebula.overrideAttrs (final: prev: {
                version = "1.11.1";
                src = pkgs.fetchFromGitHub {
                  owner = "slackhq";
                  repo = "nebula";
                  tag = "v${final.version}";
                  hash = "sha256-3YxOq9kxNShkIbFZ6P9kCkNl8nraICMlp2jSCBnlSP4=";
                };
                vendorHash = "sha256-I0pV4nosm1j7FqGmgkQWe24umRzBnMb2gvEiZr0uTFo=";
                # Cache the pkcs11 client instead of re-opening the HSM/TPM per
                # DH. Upstream's noiseutil.nistP11Curve.DH opened+initialized+
                # closed the whole PKCS#11 module on every handshake DH, run
                # inline on the single packet-reader goroutine -- so a handshake
                # storm (mesh/relay reconnect churn from the travel routers)
                # blocked the reader in the slow serialized TPM and stalled the
                # WHOLE overlay for seconds-to-minutes (361KB Recv-Q backlog,
                # verified by goroutine dump: reader parked in pkcs11._Cfunc_
                # Initialize). Root cause of the post-DC34 stalls. Upstream PR
                # pending; the diff caches one long-lived client per URI.
                patches = (prev.patches or [ ]) ++ [ ./pkgs/nebula/pkcs11-cache-client.patch ];
              });

              immich-public-proxy = pkgs.immich-public-proxy.overrideAttrs (final: prev: {
                version = "3.2.1";
                src = pkgs.fetchFromGitHub {
                  owner = "alangrainger";
                  repo = "immich-public-proxy";
                  tag = "v${final.version}";
                  hash = "sha256-RA9CzIH6JJucRKDZS+kqqFSZht8OphWQsxLoWnoJA5I=";
                };
                npmDeps = prev.npmDeps.overrideAttrs (prevDeps: {
                  inherit (final) src;
                  outputHash = "sha256-jBn3Vt3S3AHstVp3gy5PaAnMAlHcqgkMdAPEEkC3+b8=";
                });
              });

              nixos-lv-onboarding-artifacts = onboardingArtifacts;
              nix-vegas-site = nix-vegas-site.packages.${system}.default;
              # The event flavor: same site with the onboarding artifacts baked
              # in (ISOs/netboot/manual/search rendered on /2026/onsite) and
              # base_url https://nixos.lv/. ghostgate serves this; crystal and
              # Netlify keep the plain nix-vegas-site above.
              nix-vegas-site-onsite = nix-vegas-site.packages.${system}.nixVegasOnsite.override {
                inherit onboardingArtifacts;
              };
              # 26.05 nixpkgs has packages whose meta.platforms mixes attrset
              # (structured cross) entries with strings; upstream's guard only
              # checks the first element and jinja's sort then dies comparing
              # dict < str. Render just the string platforms.
              nixos-pagefind-staticgen = nixos-pagefind.packages.${system}.staticgen.overrideAttrs (prev: {
                postPatch = (prev.postPatch or "") + ''
                  substituteInPlace src/staticgen/templates/package.jinja \
                    --replace-fail 'pkg.meta.platforms and pkg.meta.platforms[0] is string' 'pkg.meta.platforms | select("string") | list' \
                    --replace-fail 'pkg.meta.platforms | sort' 'pkg.meta.platforms | select("string") | sort'
                '';
              });
              nixos-pagefind-build = pkgs.callPackage ./pkgs/pagefind {
                inherit nixpkgs nixos-pagefind;
              };
              nixos-lv-root-ca = pkgs.callPackage ./pkgs/nixos-lv-root-ca { };
              great-value-hydra = great-value-hydra.packages.${system};
              badapple2ipxe = pkgs.callPackage ./pkgs/badapple-ipxe { };
              live-captions = pkgs.callPackage ./pkgs/live-captions { };
              tt-chat-proxy = pkgs.callPackage ./pkgs/tt-chat-proxy { };
              # `deploy` wrapper that routes deploy-rs's eval through fix (~4x
              # faster). See pkgs/deploy-fix + docs/fix-evaluator.md.
              deploy-fix = pkgs.callPackage ./pkgs/deploy-fix {
                deploy-rs = deploy-rs.packages.${system}.default;
                # The exact fix package the fleet runs (programs.fix), pinned via a
                # host config so it's pure (import fix {} would hit currentSystem).
                fix = self.nixosConfigurations.dragonborn.config.programs.fix.package;
              };
            };

          packages = {
            onboarding-artifacts = pkgs.nixos-lv-onboarding-artifacts;
            inherit (pkgs) nixos-lv-onboarding-artifacts nixos-pagefind-build;
            inherit (pkgs) nix-vegas-site nix-vegas-site-onsite;
            inherit (pkgs) nixos-lv-root-ca;
            inherit (pkgs) badapple2ipxe;
            inherit (pkgs) live-captions;
            inherit (pkgs) tt-chat-proxy;
          };

          devShells.default = pkgs.mkShell {
            buildInputs = [
              # `deploy` here evals with fix (~4x faster); DEPLOY_NO_FIX=1 for stock.
              pkgs.deploy-fix
              pkgs.nixfmt
            ];
          };
        };
    };
}
