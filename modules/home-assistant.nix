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
  # pre-flash state snapshot, the flash on/off, and the restore below. The four
  # H6076 lamps were renamed in HA by position/role (stage_left, stage_right,
  # rear, ctf), so the entity_ids follow those names.
  goveeLights = [
    "light.stage_left"
    "light.stage_right"
    "light.rear"
    "light.ctf"
  ];

  # The resting look both flash automations settle on afterward, so the normal
  # state is defined ONCE. Currently the Govee "snowflake" effect -- the name must
  # match the device's effect_list (Developer Tools -> States -> a govee light).
  restGovee = {
    action = "light.turn_on";
    target.entity_id = goveeLights;
    data.effect = "snowflake";
  };
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
            # End deterministically ON at the resting look (never leaves the
            # lamps dark). Scene-snapshot/restore was unreliable here:
            # govee_light_local is a LAN integration whose cached state lags, so
            # the snapshot often captured a stale `off` and "restored" them off.
            restGovee
          ];
        }
        {
          alias = "Flag capture pattern";
          # POST /api/webhook/flag-capture -- fired by the "escape your fate"
          # hotword (live-captions) when a CTF flag is captured. Distinct green
          # celebration pattern, then settle to the resting look. local_only +
          # the nginx NOC gate on home.nixos.lv restrict who can fire it.
          triggers = [
            {
              trigger = "webhook";
              webhook_id = "flag-capture";
              local_only = true;
              allowed_methods = [ "POST" ];
            }
          ];
          actions = [
            {
              repeat = {
                count = 4;
                sequence = [
                  {
                    action = "light.turn_on";
                    target.entity_id = goveeLights;
                    data = {
                      rgb_color = [
                        0
                        255
                        0
                      ];
                      brightness_pct = 100;
                    };
                  }
                  { delay = "00:00:00.25"; }
                  {
                    action = "light.turn_off";
                    target.entity_id = goveeLights;
                  }
                  { delay = "00:00:00.25"; }
                ];
              };
            }
            # Then hold solid green so the celebration lasts ~15s total (2s flash +
            # 13s hold) -- matches the caption banner's flagSeconds on dragonborn.
            {
              action = "light.turn_on";
              target.entity_id = goveeLights;
              data = {
                rgb_color = [
                  0
                  255
                  0
                ];
                brightness_pct = 100;
              };
            }
            { delay = "00:00:13"; }
            restGovee
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
