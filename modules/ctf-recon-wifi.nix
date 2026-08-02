# CTF "recon" scavenger-hunt flag planter: stand up an OPEN SSID on a spare
# mt76x0u radio and periodically shout the flag as a broadcast UDP packet.
# Pairs with the Recon8 "Free WiFi" challenge in the ctf-server repo.
#
# The AP is standalone (NOT bridged to the arena): clients get no route off this
# segment, so it stays isolated; the flag reaches them only as a broadcast they
# can sniff (monitor mode) or receive after joining. The flag value is NOT
# committed here (this repo is on the player-facing forgejo); it is read at
# runtime from an out-of-band on-host file that must match the value the Recon8
# challenge expects in the ctf-server repo.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixVegas.ctfReconWifi;
in
{
  options.nixVegas.ctfReconWifi = {
    enable = lib.mkEnableOption "the recon CTF open-SSID UDP flag beacon";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wlp0s20f0u8";
      description = "The (mt76x0u) radio to run the open AP on.";
    };

    ssid = lib.mkOption {
      type = lib.types.str;
      default = "NixVegas Free WiFi";
      description = "The open SSID players see and can join.";
    };

    channel = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "2.4GHz channel for the open AP.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.66.66.1";
      description = "Host IP on the isolated open-AP subnet (source of the beacon).";
    };

    prefixLength = lib.mkOption {
      type = lib.types.int;
      default = 24;
      description = "Prefix length of the isolated open-AP subnet.";
    };

    broadcast = lib.mkOption {
      type = lib.types.str;
      default = "10.66.66.255";
      description = "Subnet broadcast address the flag beacon is sent to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1337;
      description = "UDP port the flag beacon is sent to.";
    };

    interval = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Seconds between beacons.";
    };

    flagFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixctf/flag-recon-wifi";
      description = ''
        On-host file holding the flag beacon payload. Provisioned out-of-band
        and deliberately NOT committed; it must hold the flag exactly as players
        should submit it, i.e. `Nix{...}`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d /etc/nixctf 0700 root root - -" ];

    # A second hostapd radio, merged alongside the arena AP. Open (no auth), and
    # deliberately NOT bridged to the arena, so it is an isolated broadcast-only
    # segment. mt76x0u on 2.4GHz (802.11n) for range and universal client support.
    services.hostapd.radios.${cfg.interface} = {
      countryCode = "US";
      band = "2g";
      channel = cfg.channel;
      networks.${cfg.interface} = {
        ssid = cfg.ssid;
        authentication.mode = "none";
      };
    };

    systemd.services.ctf-recon-wifi-beacon = {
      description = "Open-SSID UDP flag beacon (${cfg.interface})";
      wantedBy = [ "multi-user.target" ];
      after = [ "hostapd.service" ];
      wants = [ "hostapd.service" ];
      path = [
        pkgs.iproute2
        pkgs.socat
        pkgs.coreutils
      ];
      serviceConfig = {
        Restart = "always";
        RestartSec = "10s";
      };
      # Give the AP interface an address so there is a subnet to broadcast on,
      # then beacon the flag as a broadcast datagram on a loop. Re-reads the flag
      # file each pass so re-provisioning it needs no restart.
      script = ''
        ip addr replace ${cfg.address}/${toString cfg.prefixLength} dev ${cfg.interface} || true
        ip link set ${cfg.interface} up || true
        while true; do
          flag="$(cat ${cfg.flagFile} 2>/dev/null || true)"
          if [ -n "$flag" ]; then
            printf '%s\n' "$flag" \
              | socat -u - UDP-DATAGRAM:${cfg.broadcast}:${toString cfg.port},broadcast || true
          fi
          sleep ${toString cfg.interval}
        done
      '';
    };
  };
}
