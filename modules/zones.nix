{
  config,
  pkgs,
  lib,
  extraModules,
  ...
}:

with lib;

let
  cfg = config.zones;

  makeZoneMount = name: "${cfg.zoneRoot}/${name}";
  allZoneMounts =
    (mapAttrsToList (name: value: makeZoneMount name) cfg.zones)
    ++ (map makeZoneMount cfg.extraZoneMounts);

  # Convert an IP into the host gateway address. Just replaces
  # the final octet with 1.
  hostAddress =
    ip:
    with builtins;
    let
      splitIp = split "\\." ip;
    in
    (elemAt splitIp 0) + "." + (elemAt splitIp 2) + "." + (elemAt splitIp 4) + "." + "1";
in
{
  options = {
    zones = {
      externalInterface = mkOption {
        type = with types; nullOr str;
        default = null;
        description = "The external interface, for NAT";
      };
      zoneRoot = mkOption {
        type = types.str;
        default = "/zones";
        description = "Sets the root for zones.";
      };
      zones = mkOption {
        default = { };
        type = types.attrs;
        description = "Zone definitions. These are NixOS containers, but we set more options.";
      };
      immutableZoneMounts = mkOption {
        type = types.bool;
        default = true;
        description = "Set to true if zone mounts should be +i.";
      };
      extraZoneMounts = mkOption {
        description = "Any additional zone mounts to add.";
        default = [ ];
        example = [ "mattermost-postgresql" ];
        type = types.listOf types.str;
      };
    };
  };

  config = mkMerge [
    (mkIf (cfg.externalInterface != null) {
      networking = {
        interfaces.${cfg.externalInterface}.useDHCP = lib.mkDefault (!config.boot.isContainer);
        nat = {
          enable = lib.mkDefault true;
          internalInterfaces = lib.mkDefault [
            "ve-+"
            "vb-+"
          ];
          inherit (cfg) externalInterface;
        };
      };
    })
    {
      system.activationScripts.zones.text = ''
        zone_mounts=(${lib.escapeShellArgs allZoneMounts})
        if [ ''${#zone_mounts[@]} -gt 0 ]; then
          mkdir -p "''${zone_mounts[@]}"
          for zone_mount in "''${zone_mounts[@]}"; do
          ${
            if cfg.immutableZoneMounts then
              "if ! ${pkgs.util-linux}/bin/mountpoint -q $zone_mount; then ${pkgs.e2fsprogs}/bin/chattr +i $zone_mount || true; fi"
            else
              "${pkgs.e2fsprogs}/bin/chattr -i $zone_mount || true"
          }
          done
        fi
      '';

      containers = mapAttrs (
        name: value:
        recursiveUpdate value {
          config = {
            # Useless to enable in a container.
            imports = (value.config.imports or [ ]) ++ extraModules;
          };
          autoStart = true;
          privateNetwork = true;
          hostAddress =
            if builtins.hasAttr "localAddress" value then hostAddress value.localAddress else null;
          bindMounts = {
            "/" = {
              hostPath = makeZoneMount name;
              isReadOnly = false;
            };
          }
          // (
            if
              (
                builtins.hasAttr "networking" value.config
                && builtins.hasAttr "useHostResolvConf" value.config.networking
                && value.config.networking.useHostResolvConf
              )
            then
              {
                "/etc/resolv.conf" = {
                  hostPath = "/etc/resolv.conf";
                  isReadOnly = true;
                };
              }
            else
              { }
          );
        }
      ) cfg.zones;
    }
  ];
}
