{
  description = "Nix flake for deploying Distractions infrastructure";

  inputs = {
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-cosmic.url = "github:lilyinstarlight/nixos-cosmic";
    nixpkcs.url = "github:numinit/nixpkcs/v1.2";
    meshos.url = "github:numinit/MeshOS";

    deploy-rs.url = "github:serokell/deploy-rs";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      nixpkgs-unstable,
      nixpkgs-lib,
      nixpkcs,
      nixos-cosmic,
      deploy-rs,
      meshos,
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
            map (nixpkgs: {
              name = lib.versions.majorMinor nixpkgs.lib.version;
              value = nixpkgs;
            }) [ nixpkgs nixpkgs-unstable ]
          );

          # Creates a NixOS system.
          nixosSystem =
            {
              # The NixOS version.
              version,
              # Modules to evaluate.
              modules ? [ ],
              # The build system.
              buildSystem ? "x86_64-linux",
              # The target system.
              targetSystem ? "x86_64-linux",
              # Any extra special args. The flake inputs are automatically provided,
              # as well as a hardcoded `extraModules`.
              specialArgs ? { },
            }:
            let
              extraModules = [ self.nixosModules.default ];
            in
            nixpkgsVersions.${version}.lib.nixosSystem {
              system = buildSystem;
              modules = modules ++ extraModules ++ [
                {
                  nixpkgs = {
                    buildPlatform = buildSystem;
                    hostPlatform = targetSystem;
                  };
                }
              ];
              specialArgs = inputs // {
                inherit extraModules;
              } // specialArgs;
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
                  path = deploy-rs.lib.${config.config.nixpkgs.system}.activate.nixos config;
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
              { nixosConfigurations = {}; deploy.nodes = {}; }
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
                ];
              }
              nixos-cosmic.nixosModules.default
              meshos.nixosModules.default
            ];
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

          devShells.default = pkgs.mkShell {
            buildInputs = [
              deploy-rs.packages.${system}.default
            ];
          };
        };
    };
}
