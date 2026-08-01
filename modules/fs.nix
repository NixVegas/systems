{ config, lib, ... }:
let
  cfg = config.nixVegas.zfs;
  inherit (config.networking) hostName;
  # Encrypted hosts (desktops) keep their datasets under a `${hostName}/enc`
  # prefix; the fleet (enc = false) uses the bare `${hostName}` prefix, so this
  # module stays a byte-identical no-op for every existing host.
  prefix = if cfg.enc then "${hostName}/enc" else hostName;
  inherit (lib) types;
  inherit (lib.options) mkEnableOption mkOption;
in
{
  options.nixVegas.zfs = {
    enc = mkEnableOption "the ${hostName}/enc dataset prefix + zfs encryption prompt";
    etc = mkOption {
      type = types.bool;
      default = false;
      description = "mount a /etc zfs dataset (under the active prefix)";
    };
    rootHome = mkOption {
      type = types.bool;
      default = false;
      description = "mount a /root zfs dataset (under the active prefix)";
    };
  };

  config = {
    boot.zfs = {
      forceImportRoot = true;
      # enc hosts prompt for the encryption key; the fleet does not.
      requestEncryptionCredentials = cfg.enc;
      # NB: intentionally NOT setting boot.zfs.devNodes here -- the fleet relies on
      # the NixOS default (/dev/disk/by-id) and an mkDefault here would silently
      # override it. Hosts that need by-partlabel set it themselves (desktop.nix).
    };

    # ZFS requires a stable hostId. Derive it from the hostname and default it
    # here (the zfs module, imported by BOTH the fleet and the desktops) rather
    # than in net.nix, which desktops can't import (it mkForce-disables
    # NetworkManager). mkDefault so a host can still override.
    networking.hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" hostName));

    services.zfs = {
      trim.enable = true;
      autoScrub = {
        enable = true;
        pools = [ hostName ];
      };
    };

    fileSystems = {
      "/" = {
        device = "${prefix}/system/root";
        fsType = "zfs";
      };
      "/boot" = {
        device = "/dev/disk/by-partlabel/${hostName}.boot";
        fsType = "vfat";
        options = [
          "fmask=0022"
          "dmask=0022"
        ];
      };
      "/nix" = {
        device = "${prefix}/local/nix";
        fsType = "zfs";
      };
      "/home" = {
        device = "${prefix}/user/home";
        fsType = "zfs";
      };
      "/var" = {
        device = "${prefix}/system/var";
        fsType = "zfs";
      };
      "/root" = lib.mkIf cfg.rootHome {
        device = "${prefix}/user/root";
        fsType = "zfs";
        options = [ "nofail" ];
      };
      "/etc" = lib.mkIf cfg.etc {
        device = "${prefix}/system/etc";
        fsType = "zfs";
        options = [ "nofail" ];
      };
    };
  };
}
