# CTF "recon" scavenger-hunt flag planter: inject the flag into the iPXE menu
# the netboot chain hands out, as a comment players find by reading the script.
# Pairs with the Recon2 "Chain Loader" challenge in the ctf-server repo.
#
# The menu itself is a build artifact (nixVegas.pxe.gameScript). Rather than bake
# the flag into it (this repo is on the player-facing forgejo), a runtime service
# copies the menu and injects the flag as an iPXE setting (`set <var> <flag>`),
# so it both shows to anyone reading the script and is referenceable later as
# `${<var>}`. The flag is read from an out-of-band on-host file that must match
# the value the Recon2 challenge expects in the ctf-server repo. Point the served
# /boot/menu.ipxe alias at `config.nixVegas.ctfReconIpxe.output`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixVegas.ctfReconIpxe;
in
{
  options.nixVegas.ctfReconIpxe = {
    enable = lib.mkEnableOption "injecting the recon CTF flag into the served iPXE menu";

    menuScript = lib.mkOption {
      type = lib.types.path;
      default = config.nixVegas.pxe.gameScript;
      defaultText = lib.literalExpression "config.nixVegas.pxe.gameScript";
      description = "The base iPXE menu script the flag setting is injected into.";
    };

    variable = lib.mkOption {
      type = lib.types.str;
      default = "flag";
      description = ''
        Name of the iPXE setting the flag is injected as (`set <variable>
        <flag>`), so later script (or a curious player) can reference it as
        `''${<variable>}`.
      '';
    };

    flagFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixctf/flag-recon-ipxe";
      description = ''
        On-host file holding the flag. Provisioned out-of-band and NOT committed;
        it must hold the flag exactly as players should submit it, i.e. `Nix{...}`.
        If the file is absent the menu is served verbatim (netboot keeps working);
        the flag appears once the file is placed.
      '';
    };

    output = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/run/ctf-recon-ipxe/menu.ipxe";
      description = "Runtime path of the flag-injected menu; point the /boot/menu.ipxe alias here.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d /etc/nixctf 0700 root root - -" ];

    systemd.services.ctf-recon-ipxe = {
      description = "Inject the recon CTF flag into the served iPXE menu";
      wantedBy = [ "multi-user.target" ];
      before = [ "nginx.service" ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "ctf-recon-ipxe";
        RuntimeDirectoryMode = "0755";
      };
      # iPXE requires `#!ipxe` on line 1, so inject the flag as a setting right
      # after it: `set <variable> <flag>`, which both shows the flag to anyone
      # reading the script and makes it referenceable later as `${variable}`.
      # (The flag's single spaces survive iPXE's `set` arg-join; a value with
      # runs of whitespace would need the :hex/${:string} idiom instead.) If the
      # flag file is missing, serve the menu unchanged so netboot still works.
      script = ''
        flag="$(cat ${cfg.flagFile} 2>/dev/null || true)"
        if [ -z "$flag" ]; then
          flag=UNKNOWN
        fi
        {
          head -n 1 ${cfg.menuScript}
          printf 'set %s %s\n' '${cfg.variable}' "$flag"
          tail -n +2 ${cfg.menuScript}
        } > ${cfg.output}
      '';
    };

    # Regenerate when the flag file is (re)provisioned on a running host, so no
    # manual restart is needed after dropping the flag in place.
    systemd.paths.ctf-recon-ipxe = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathModified = cfg.flagFile;
        Unit = "ctf-recon-ipxe.service";
      };
    };
  };
}
