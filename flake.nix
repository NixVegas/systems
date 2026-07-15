{
  # Based on the Distractions stack we ran from DC30-DC32 — notably the
  # Nebula, MeshOS, and Mattermost config is derived from it.
  description = "Nix flake for deploying Nix Vegas infrastructure";

  inputs = {
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-cosmic.url = "github:lilyinstarlight/nixos-cosmic?ref=pull/863/head";
    nixpkcs.url = "github:numinit/nixpkcs/v1.3";
    meshos.url = "github:numinit/MeshOS";

    nixpkgs-gold.url = "github:Jaculabilis/nixpkgs-gold";

    great-value-hydra = {
      url = "github:NixVegas/great-value-hydra";
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
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      nixpkgs-unstable,
      nixpkgs-lib,
      nixpkgs-gold,
      great-value-hydra,
      nixpkcs,
      nixos-cosmic,
      deploy-rs,
      nixos-pagefind,
      nix-vegas-site,
      meshos,
      tenstorrent-nix,
      nix-vegas-ctf,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        flake-parts.flakeModules.easyOverlay
      ];

      flake =
        let
          deployUser = "deploy";

          inherit (nixpkgs-lib) lib;

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
                  sshUser = deployUser;
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
              nixos-cosmic.nixosModules.default
              meshos.nixosModules.default
              tenstorrent-nix.nixosModules.default
              nix-vegas-ctf.nixosModules.default
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

          overlayAttrs = {
            nixos-lv-onboarding-artifacts = pkgs.callPackage ./pkgs/onboarding {
              inherit nixpkgs;
            };
            nix-vegas-site = nix-vegas-site.packages.${system}.default;
            nixos-pagefind-staticgen = nixos-pagefind.packages.${system}.staticgen;
            nixos-pagefind-build = pkgs.callPackage ./pkgs/pagefind {
              inherit nixpkgs nixos-pagefind;
            };
            great-value-hydra = great-value-hydra.packages.${system};
          };

          packages = {
            onboarding-artifacts = pkgs.nixos-lv-onboarding-artifacts;
            inherit (pkgs) nixos-lv-onboarding-artifacts nixos-pagefind-build;
            inherit (pkgs) nix-vegas-site;
          };

          devShells.default = pkgs.mkShell {
            buildInputs = [
              deploy-rs.packages.${system}.default
            ];
          };
        };
    };
}
