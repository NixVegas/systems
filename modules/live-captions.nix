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

  args =
    [
      "--whisper-url"
      cfg.whisperUrl
      "--api-key"
      cfg.apiKey
      "--model"
      cfg.model
      "--keyword"
      cfg.keyword
      "--window"
      (toString cfg.window)
      "--hop"
      (toString cfg.hop)
      "--keyword-cooldown"
      (toString cfg.keywordCooldown)
      "--port"
      (toString cfg.port)
    ]
    ++ optionals (cfg.device != null) [ "--device" cfg.device ]
    ++ optionals (cfg.webhookUrl != null) [ "--webhook-url" cfg.webhookUrl ];
in
{
  options.services.live-captions = {
    enable = mkEnableOption "live talk captions (OBS overlay) + keyword->Home Assistant trigger";

    package = mkOption {
      type = types.package;
      default = pkgs.live-captions;
      defaultText = lib.literalExpression "pkgs.live-captions";
      description = "The live-captions package.";
    };

    whisperUrl = mkOption {
      type = types.str;
      default = "http://10.4.1.2:8030/v1/audio/transcriptions";
      description = "Whisper OpenAI transcription endpoint (citadel, over the build net).";
    };

    apiKey = mkOption {
      type = types.str;
      default = "sk-whisper";
      description = "Bearer token for the whisper endpoint (matches the tt-whisper apiKey).";
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

    keyword = mkOption {
      type = types.str;
      default = "agency";
      description = "Whole word (case-insensitive) that fires the webhook.";
    };

    webhookUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://ghostgate.build.dc.nixos.lv:8123/api/webhook/agency-flash";
      description = ''
        Home Assistant webhook to POST when the keyword is heard (HA flashes the
        Govee lights). Null captions without the trigger.
      '';
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

    keywordCooldown = mkOption {
      type = types.float;
      default = 6.0;
      description = "Minimum seconds between webhook fires (dedupes overlapping windows).";
    };

    port = mkOption {
      type = types.port;
      default = 8090;
      description = "Port the overlay + SSE server binds to (point OBS Browser Source at /overlay).";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the overlay port. Off by default: OBS reads it from localhost.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.live-captions = {
      description = "Live captions + keyword trigger";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "sound.target"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/live-captions ${lib.escapeShellArgs args}";
        Restart = "on-failure";
        RestartSec = "5";
        DynamicUser = true;
        # Capture from the AV mixer. NOTE: if the laptop's desktop session owns the
        # device through PipeWire/PulseAudio, a system service may not see it, in
        # that case run this in the user session (systemd.user) or expose the mixer
        # as a system-wide ALSA/PipeWire device. `audio` group + /dev/snd covers
        # direct ALSA capture of a USB interface.
        SupplementaryGroups = [ "audio" ];
        DeviceAllow = [ "char-alsa rw" ];
      };
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
