# Live talk captions -> OBS overlay + spoken-hotword -> Home Assistant webhooks.
# Runs as a user service in the desktop session (shares the AV mixer with OBS via
# PipeWire), transcribes against citadel's Whisper, serves the overlay on
# localhost.
#
# POST-DEPLOY (operator, on the box -- not Nix):
#   1. Log into the desktop (the service is a *user* service, it starts with the
#      graphical session). Check it: `systemctl --user status live-captions`.
#   2. Find the AV-mixer capture device: `live-captions --list-devices`.
#   3. Set `services.live-captions.device` to that index/name and rebuild (until
#      set it captures the default input, usually the built-in mic).
#   4. OBS -> add a Browser Source -> http://localhost:8090/overlay (transparent).
#   5. Create the matching HA webhook automation(s) at home.nixos.lv (one per
#      trigger webhook_id). Then the hotwords drive the lights.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    optionals
    ;

  cfg = config.services.live-captions;

  # The client reads triggers from a JSON file: one hotword -> one webhook, each
  # with its own cooldown, so different words fire different Home Assistant
  # automations.
  triggersJson = pkgs.writeText "live-captions-triggers.json" (
    builtins.toJSON (
      map (
        t:
        {
          inherit (t) keyword cooldown;
          webhook = t.webhookUrl;
        }
        // lib.optionalAttrs (t.captionFile != null) { caption_file = t.captionFile; }
      ) cfg.triggers
    )
  );

  args = [
    "--whisper-url"
    cfg.whisperUrl
    "--model"
    cfg.model
    "--window"
    (toString cfg.window)
    "--hop"
    (toString cfg.hop)
    "--port"
    (toString cfg.port)
    "--flag-seconds"
    (toString cfg.flagSeconds)
  ]
  ++ optionals (cfg.device != null) [
    "--device"
    cfg.device
  ]
  ++ optionals (cfg.triggers != [ ]) [
    "--triggers-file"
    (toString triggersJson)
  ]
  # File-backed key stays out of the store/argv; inline apiKey is the fallback.
  ++ (
    if cfg.apiKeyFile != null then
      [
        "--api-key-file"
        (toString cfg.apiKeyFile)
      ]
    else
      [
        "--api-key"
        cfg.apiKey
      ]
  );
in
{
  options.services.live-captions = {
    enable = mkEnableOption "live talk captions (OBS overlay) + hotword->Home Assistant triggers";

    package = mkOption {
      type = types.package;
      default = pkgs.live-captions;
      defaultText = lib.literalExpression "pkgs.live-captions";
      description = "The live-captions package.";
    };

    whisperUrl = mkOption {
      type = types.str;
      default = "https://whisper.nixos.lv/v1/audio/transcriptions";
      description = ''
        Whisper OpenAI transcription endpoint. citadel's tt-whisper, fronted by
        nginx (whisper.nixos.lv, onsite split-horizon -> the CTF server) with the
        Bearer token gated behind nginx -- no raw build-net port anymore. Resolves
        onsite via ghostgate; the NOC AV box reaches the CTF net (noc->ctf).
      '';
    };

    apiKey = mkOption {
      type = types.str;
      default = "sk-whisper";
      description = ''
        Bearer token for the whisper endpoint (matches the tt-whisper apiKey).
        WARNING: an inline value lands in the world-readable nix store (the unit's
        ExecStart). Prefer `apiKeyFile`.
      '';
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/etc/live-captions/whisper-api-key";
      description = ''
        Path to a file (on the machine, out of the store) holding the whisper
        Bearer key. Read at runtime, so the secret never enters the store. Must be
        readable by the desktop user running the service. Takes precedence over
        `apiKey`.
      '';
    };

    model = mkOption {
      type = types.str;
      default = "distil-large-v3";
      description = "Whisper model id to request.";
    };

    device = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "USB Audio";
      description = ''
        Audio input device: a sounddevice index (as a string) or a unique name
        substring of the AV-mixer capture device. Run
        `live-captions --list-devices` to enumerate. Null uses the default input.
      '';
    };

    triggers = mkOption {
      default = [ ];
      description = ''
        Hotwords that fire Home Assistant webhooks. Each keyword (case-insensitive,
        whole word) POSTs its own webhook, so different words drive different
        automations. A per-keyword cooldown dedupes the overlapping windows a
        single spoken word appears in. Empty means caption only, no triggers.
      '';
      example = lib.literalExpression ''
        [
          { keyword = "agency"; webhookUrl = "https://home.nixos.lv/api/webhook/agency-flash"; }
        ]
      '';
      type = types.listOf (
        types.submodule {
          options = {
            keyword = mkOption {
              type = types.str;
              description = "Whole word (case-insensitive) that fires this webhook.";
            };
            webhookUrl = mkOption {
              type = types.str;
              description = "Home Assistant webhook URL to POST when the keyword is heard.";
            };
            captionFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "/etc/nixvegas/flag-caption";
              description = ''
                Optional path to a file (on the box, out of the store) whose
                contents are flashed onto the caption overlay as a flag banner when
                this keyword fires. Read live on every fire, so the flag text is
                editable without a rebuild. Combines with webhookUrl (both run).
              '';
            };
            cooldown = mkOption {
              type = types.float;
              default = 6.0;
              description = "Minimum seconds between fires for this keyword.";
            };
          };
        }
      );
    };

    window = mkOption {
      type = types.float;
      default = 6.0;
      description = "Transcription window length in seconds.";
    };

    hop = mkOption {
      type = types.float;
      default = 3.0;
      description = "Seconds between windows (lower = snappier captions, more load).";
    };

    port = mkOption {
      type = types.port;
      default = 8090;
      description = "Port the overlay + SSE server binds to (point OBS Browser Source at /overlay).";
    };

    flagSeconds = mkOption {
      type = types.float;
      default = 10.0;
      description = "How long a flag banner (a trigger's captionFile) stays on the overlay.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the overlay port. Off by default: OBS reads it from localhost.";
    };
  };

  config = mkIf cfg.enable {
    # Put the CLI on PATH so the operator can run `live-captions --list-devices`.
    environment.systemPackages = [ cfg.package ];

    # A USER service, not a system one: on a desktop the AV mixer is owned by the
    # session audio server (PipeWire/PulseAudio), which is where OBS reads it too.
    # PipeWire lets both OBS and this client capture the same device. It starts
    # with the graphical session and the overlay stays on localhost for OBS.
    systemd.user.services.live-captions = {
      description = "Live captions + hotword triggers";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/live-captions ${lib.escapeShellArgs args}";
        Restart = "on-failure";
        RestartSec = "5";
      };
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
