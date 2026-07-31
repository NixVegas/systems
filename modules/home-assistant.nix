# Home Assistant on ghostgate: LAN control of the Govee H6076 lamps
# (govee_light_local, UDP multicast) plus the USB Bluetooth adapter for future
# BLE devices. Onsite-only vhost home.nixos.lv; real LE cert via brass
# ACME-forward (see devices/brass onsiteBackends). Spec:
# docs/superpowers/specs/2026-07-30-home-assistant-govee-design.md
#
# POST-DEPLOY (operator, in the HA web UI -- not Nix):
#   1. First load creates the owner account (onboarding).
#   2. Settings -> System -> Network: select ghostgate's adapter on the lamps'
#      subnet, or govee_light_local's multicast discovery finds nothing (the #1
#      failure mode; ghostgate is multi-homed).
#   3. Add the "Govee LAN" integration -> it auto-discovers the 4 lamps.
#   4. Add the "Bluetooth" integration -> it detects the dongle (hci0).
{ ... }:

let
  baseDomain = "nixos.lv";
in
{
  services.home-assistant = {
    enable = true;
    extraComponents = [
      "default_config"
      "met"
      "govee_light_local"
      "bluetooth"
    ];
    config = {
      default_config = { };
      homeassistant = {
        name = "nix.vegas";
        unit_system = "us_customary";
        time_zone = "America/Los_Angeles";
      };
      http = {
        server_host = "127.0.0.1";
        trusted_proxies = [
          "127.0.0.1"
          "::1"
        ];
        use_x_forwarded_for = true;
      };
    };
  };

  # Dongle for future BLE. The HA module auto-grants the BT capabilities +
  # AF_BLUETOOTH because "bluetooth" is an extraComponent; BlueZ's default D-Bus
  # policy already lets the hass user drive the daemon, so no dbus policy here.
  hardware.bluetooth.enable = true;

  services.nginx.virtualHosts."home.${baseDomain}" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8123";
      proxyWebsockets = true;
    };
  };
}
