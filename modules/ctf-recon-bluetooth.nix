# CTF "recon" scavenger-hunt flag planter: advertise the flag as this host's
# Bluetooth device name so players read it off a nearby BT scan. Pairs with the
# Recon7 "Ghost in the Piconet" challenge in the ctf-server repo.
#
# The flag value is NOT committed here (this repo is on the player-facing
# forgejo). It is read at runtime from an out-of-band on-host file; provision
# that file to match the value the Recon7 challenge expects in the ctf-server repo.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixVegas.ctfReconBluetooth;
in
{
  options.nixVegas.ctfReconBluetooth = {
    enable = lib.mkEnableOption "advertising the recon CTF flag as this host's Bluetooth name";

    flagFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixctf/flag-recon-bluetooth";
      description = ''
        On-host file whose contents become the Bluetooth adapter's advertised
        name. Provisioned out-of-band and deliberately NOT committed; it must
        hold the flag exactly as players should submit it, i.e. `Nix{...}`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d /etc/nixctf 0700 root root - -" ];

    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
    };

    systemd.services.ctf-recon-bluetooth = {
      description = "Advertise the recon CTF flag as the Bluetooth device name";
      wantedBy = [ "multi-user.target" ];
      after = [ "bluetooth.service" ];
      wants = [ "bluetooth.service" ];
      path = [
        pkgs.bluez
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # Set the controller's advertised alias to the flag and make it
      # permanently discoverable. bluetoothctl drives bluez over D-Bus; each
      # invocation runs a single command and exits.
      script = ''
        name="$(cat ${cfg.flagFile})"
        bluetoothctl power on
        bluetoothctl system-alias "$name"
        bluetoothctl discoverable-timeout 0
        bluetoothctl discoverable on
      '';
    };
  };
}
