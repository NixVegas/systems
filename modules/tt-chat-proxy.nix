# Reasoning-hiding, flag-redacting OpenAI chat proxy.
#
# Sits between the tt-studio console and the vLLM server. A reasoning model
# (Qwen3) emits a chain-of-thought that tt-studio shows in a "thinking process"
# panel; that reasoning can restate a hidden CTF flag verbatim, handing it over
# with no jailbreak. This proxy strips `reasoning_content` from the stream so the
# chain-of-thought never reaches the browser, and redacts anything shaped like a
# flag (default `Nix{...}`) from the answer as a backstop. Thinking stays fully
# on, so the model keeps its quality; only the visible trace is removed.
#
# Point `services.tt-studio.cloudChatUrl` at this proxy, and `upstream` at vLLM.
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
    ;

  cfg = config.services.tt-chat-proxy;
in
{
  options.services.tt-chat-proxy = {
    enable = mkEnableOption "the reasoning-hiding, flag-redacting chat proxy";

    package = mkOption {
      type = types.package;
      default = pkgs.tt-chat-proxy;
      defaultText = lib.literalExpression "pkgs.tt-chat-proxy";
      description = "The tt-chat-proxy package.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address the proxy binds to.";
    };

    port = mkOption {
      type = types.port;
      default = 8009;
      description = "Port the proxy listens on (point cloudChatUrl here).";
    };

    upstream = mkOption {
      type = types.str;
      default = "http://127.0.0.1:8000";
      description = ''
        Base URL of the upstream OpenAI server (the vLLM server). The proxy
        forwards each request's path unchanged to this base, so give scheme,
        host, and port only (no path).
      '';
    };

    stripReasoning = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Remove `reasoning_content` from responses so a reasoning model's
        chain-of-thought never reaches the client. Off leaves it in place (but
        still redacts flag-shaped strings inside it).
      '';
    };

    redactOpen = mkOption {
      type = types.str;
      default = "Nix{";
      description = "Opening literal of the flag shape to redact from answers.";
    };

    redactClose = mkOption {
      type = types.str;
      default = "}";
      description = "Closing literal of the flag shape to redact from answers.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the proxy port. Off by default; it is reached over loopback.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.tt-chat-proxy = {
      description = "Reasoning-hiding, flag-redacting chat proxy";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      # The proxy holds no secret (it hides the whole flag pattern, never the
      # flag itself), touches no device, and binds loopback, so a dynamic user
      # with no extra privilege is enough.
      environment = {
        PROXY_HOST = cfg.host;
        PROXY_PORT = toString cfg.port;
        PROXY_UPSTREAM = cfg.upstream;
        PROXY_REDACT_OPEN = cfg.redactOpen;
        PROXY_REDACT_CLOSE = cfg.redactClose;
        PROXY_STRIP_REASONING = lib.boolToString cfg.stripReasoning;
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/tt-chat-proxy";
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = "5";
      };
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
