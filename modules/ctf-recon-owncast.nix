# CTF "recon" scavenger-hunt flag planter: post the flag into the Owncast
# stream chat once an hour, on the hour. Pairs with the Recon3 "On the Hour"
# challenge in the ctf-server repo.
#
# Neither the flag nor the Owncast access token is committed here (this repo is
# on the player-facing forgejo). Both are read at runtime from out-of-band
# on-host files. The flag file must match the value the Recon3 challenge expects
# in the ctf-server repo; the token is an Owncast access token with the
# "send chat messages" scope, created in the Owncast admin.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixVegas.ctfReconOwncast;
in
{
  options.nixVegas.ctfReconOwncast = {
    enable = lib.mkEnableOption "the recon CTF hourly Owncast-chat flag post";

    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:${toString config.services.owncast.port}";
      defaultText = lib.literalExpression ''"http://localhost:''${toString config.services.owncast.port}"'';
      description = "Base URL of the Owncast instance to post to (defaults to the local one).";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* *:00:00";
      description = "systemd OnCalendar for the post (default: hourly, on the hour).";
    };

    flagFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixctf/flag-recon-owncast";
      description = ''
        On-host file holding the chat message (the flag). Provisioned
        out-of-band and NOT committed; it must hold the flag exactly as players
        should submit it, i.e. `Nix{...}`.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixctf/owncast-token";
      description = ''
        On-host file holding an Owncast access token with the "send chat
        messages" scope (create it in the Owncast admin). Out-of-band, NOT
        committed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d /etc/nixctf 0700 root root - -" ];

    systemd.services.ctf-recon-owncast = {
      description = "Post the recon CTF flag to Owncast chat";
      after = [
        "owncast.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      path = [
        pkgs.curl
        pkgs.jq
        pkgs.coreutils
      ];
      serviceConfig.Type = "oneshot";
      # Read the flag + token from disk each run (so re-provisioning needs no
      # rebuild), and post as a chat message via the Owncast integration API.
      script = ''
        flag="$(cat ${cfg.flagFile})"
        token="$(cat ${cfg.tokenFile})"
        body="$(jq -nc --arg b "$flag" '{body: $b}')"
        curl -fsS -X POST \
          -H "Authorization: Bearer $token" \
          -H "Content-Type: application/json" \
          -d "$body" \
          ${cfg.apiUrl}/api/integrations/chat/send
      '';
    };

    systemd.timers.ctf-recon-owncast = {
      description = "Hourly recon CTF Owncast chat post";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        # Don't fire a catch-up burst on boot for intervals missed while down.
        Persistent = false;
      };
    };
  };
}
