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

  # The Govee lamps the AGENCY flash drives. Single source of truth: used for the
  # pre-flash state snapshot, the flash on/off, and the restore below -- fill in
  # the real entity_ids ONCE here. (Developer Tools -> States, filter `light.`;
  # govee_light_local names them like light.govee_h6076_xxxx.)
  goveeLights = [
    "light.govee_1"
    "light.govee_2"
  ];
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

      # Declarative automations. The "automation manual" key (a labelled domain,
      # not a bare `automation`) keeps the HA UI automation editor usable
      # alongside these -- a bare `automation` here would shadow it.
      "automation manual" = [
        {
          alias = "Flash Govee on AGENCY";
          # Fires on POST to /api/webhook/agency-flash. `webhook` ships in
          # default_config, so no extra component is needed. local_only means
          # only onsite/private-source requests are accepted (nginx forwards the
          # real client IP via X-Forwarded-For, which we already trust above).
          triggers = [
            {
              trigger = "webhook";
              webhook_id = "agency-flash";
              local_only = true;
              allowed_methods = [ "POST" ];
            }
          ];
          actions = [
            # Snapshot the lamps' current state (on/off, color, brightness) into a
            # throwaway scene so we can put them back exactly as they were after
            # the flash -- otherwise the sequence ends on turn_off and leaves them
            # dark. `scene` ships in default_config.
            {
              action = "scene.create";
              data = {
                scene_id = "agency_flash_restore";
                snapshot_entities = goveeLights;
              };
            }
            {
              repeat = {
                count = 3;
                sequence = [
                  {
                    action = "light.turn_on";
                    target.entity_id = goveeLights;
                    data = {
                      rgb_color = [
                        255
                        0
                        0
                      ];
                      brightness_pct = 100;
                    };
                  }
                  { delay = "00:00:00.35"; }
                  {
                    action = "light.turn_off";
                    target.entity_id = goveeLights;
                  }
                  { delay = "00:00:00.35"; }
                ];
              };
            }
            # Restore whatever they were before the flash (lit -> lit, off -> off).
            {
              action = "scene.turn_on";
              target.entity_id = "scene.agency_flash_restore";
            }
          ];
        }
      ];
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
