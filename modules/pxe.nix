# Shared iPXE/PXE netboot server: a TFTP chainloader + the kea DHCP boot
# classes, used by every router that offers netboot on its LAN (ghostgate and
# the vp2420s). The two-stage flow:
#
#   PXE ROM --DHCP--> (arch class) --TFTP--> ipxe.efi / undionly.kpxe
#   iPXE    --DHCP--> (option 77 = "iPXE") --HTTP--> ipxeScriptUrl -> kernel+initrd
#
# netboot.ipxe references its kernel/initrd by *relative* path, so they are
# fetched from the same host:port as ipxeScriptUrl. Point that at a name that
# resolves to a box already serving /boot (ghostgate's nixos.lv site vhost), or
# at a box's own LAN IP with serveArtifacts = true (the vp2420 edge case).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixVegas.pxe;

  # ASCII banner (pure ASCII — iPXE's console font can't draw box/Unicode glyphs).
  # iPXE `echo` collapses literal whitespace, BUT `${...}` settings expand AFTER
  # tokenising (core/exec.c: split_command then expand_settings per token), so a
  # setting's value keeps its spaces as one argument. The build below hex-encodes
  # each line into setting `L` and emits `echo ${L:string}` — the whitespace-safe
  # idiom from the iPXE forums.
  pxeBanner = ''
                ___   __
         /-\    \  \ /  ;
         \  \    \  v  /
      /---   ----\\   /  /\
     '------------.\  \ /  ;
          /--;      \ //  /_
    _____/  /        '/     \
    \      /,        /  /----
     --/  // \      /__/
      .  / \  \.------------.
       \/  /   \\_____   ___/
          /  ,  \     \  \
          \_/ \__\     \_/
          NIX VEGAS @ DC34
          ESCAPE YOUR FATE
  '';

  # Shell snippet: clear the screen, then emit whitespace-safe iPXE echo lines for
  # each line of $bannerFile. The clear is ANSI ESC[2J (erase-all — the ONLY ED
  # variant iPXE's EFI console accepts; ESC[J/ESC[1J assert-fail) + ESC[H (home,
  # for serial/fbcon terminals that don't home on erase), sent via the same
  # :hex/${:string} trick and printed with `echo -n` so no newline is added.
  bannerToIpxe = ''
    printf 'set L:hex 1b:5b:32:4a:1b:5b:48\n'
    printf 'echo -n ''${L:string}\n'
    while IFS= read -r line; do
      if [ -z "$line" ]; then
        printf 'echo\n'
      else
        hex=$(printf '%s' "$line" | od -An -v -tx1 | tr -s ' \n' ':' | sed 's/^:*//;s/:*$//')
        printf 'set L:hex %s\n' "$hex"
        printf 'echo ''${L:string}\n'
      fi
    done < "$bannerFile"
  '';

  pxeGame = ''
    :intro
    echo
    prompt --timeout 20000 Press any key to play Bad Apple, or wait to boot NixOS... || goto boot
    chain badapple.ipxe || goto boot

    :boot
    echo
    echo Booting NixOS...
    chain netboot.ipxe
  '';

  # autoexec.ipxe is what iPXE's EFI autoexec probe fetches. Crucially, when this
  # image is present iPXE runs it *instead of* its normal autoboot and returns to
  # firmware once it finishes (ipxe() in usr/autoboot.c: `first_image()` ->
  # image_exec -> return). So it must do the boot itself with `autoboot` — an
  # `exit` here drops straight back to EFI setup. autoboot re-DHCPs and boots the
  # iPXE class's URL (menu.ipxe). Serving the file here also stops the EFI
  # autoexec probe from timing out.
  ipxeServe =
    pkgs.runCommand "ipxe-netboot"
      {
        inherit pxeBanner;
        passAsFile = [ "pxeBanner" ];
      }
      ''
        mkdir -p $out
        ln -s ${pkgs.ipxe}/* $out/
        bannerFile="$pxeBannerPath"
        {
          printf '#!ipxe\n\n'
          ${bannerToIpxe}
          printf '\nautoboot\n'
        } > $out/autoexec.ipxe
      '';

  # The HTTP boot script the DHCP iPXE class hands out: title + the adventure,
  # every path chaining the real netboot.ipxe. Reached via autoboot's DHCP, so
  # the console/input are up by the time it runs.
  gameScript =
    pkgs.runCommand "nixvegas-menu.ipxe"
      {
        inherit pxeBanner pxeGame;
        passAsFile = [
          "pxeBanner"
          "pxeGame"
        ];
      }
      ''
        bannerFile="$pxeBannerPath"
        {
          printf '#!ipxe\n\n'
          ${bannerToIpxe}
          printf '\n'
          cat "$pxeGamePath"
        } > $out
      '';

  # Secret branch: the hidden `apple` command in the adventure chains this. The
  # Bad Apple video is fetched at build time and compiled to an iPXE console
  # animation (pkgs/badapple-ipxe) sized/paced for a 115200 serial link (--baud
  # subtracts each frame's transmit time from its delay, holding the frame rate
  # where the link keeps up and degrading to baud-limited on busy frames). The
  # mp4 is a build input only — the runtime closure is just the ASCII script.
  badAppleVideo = pkgs.fetchurl {
    url = "https://github.com/bad-apple-lab/Bad-Apple/raw/refs/heads/main/badapple.mp4";
    hash = "sha256-2DOWQv0zA6DElx4VZFFegvae9htwDOF7aB3rsZQEwjo=";
  };
  movieScript = pkgs.runCommand "badapple.ipxe" { nativeBuildInputs = [ pkgs.badapple2ipxe ]; } ''
    badapple2ipxe --input ${badAppleVideo} \
      --width 64 --height 24 --fps 12 --baud 115200 --overhead-ms 20 \
      --after none --output $out
  '';

  # iPXE's EFI autoexec probe asks for a bare `autoexec.ipxe` / `/autoexec.ipxe`
  # (NOT relative to the store path it loaded ipxe.efi from). in.tftpd only
  # serves paths under the ${ipxeServe} whitelist, so those bare names fall
  # outside it and the client times out. Remap any request ending in
  # autoexec.ipxe onto the farm copy (which IS under the whitelist); the
  # full-path ipxe.efi fetch doesn't match, so it's unaffected.
  tftpRemap = pkgs.writeText "tftp-remap.rules" ''
    r ^.*autoexec\.ipxe$ ${ipxeServe}/autoexec.ipxe
  '';
in
{
  options.nixVegas.pxe = {
    enable = lib.mkEnableOption "iPXE/PXE netboot server (TFTP chainload + kea boot classes)";

    ipxeScriptUrl = lib.mkOption {
      type = lib.types.str;
      example = "http://nixos.lv/boot/menu.ipxe";
      description = ''
        URL handed to a running iPXE client (boot-file-name for the XClient_iPXE
        class). Point it at the menu.ipxe (gameScript) served next to
        netboot.ipxe; the adventure chains netboot.ipxe relative to this URL, and
        netboot.ipxe in turn fetches the kernel/initrd from the same host:port.
      '';
    };

    gameScript = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = gameScript;
      defaultText = lib.literalExpression "<generated Escape Your Fate menu.ipxe>";
      description = ''
        The generated iPXE menu script (banner + "Escape Your Fate" adventure,
        every path chaining netboot.ipxe). serveArtifacts publishes it at
        /boot/menu.ipxe; a host serving /boot itself (ghostgate's site vhost)
        aliases this at the same path. Point ipxeScriptUrl here.
      '';
    };

    movieScript = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = movieScript;
      defaultText = lib.literalExpression "<Bad Apple compiled to badapple.ipxe>";
      description = ''
        The Bad Apple video compiled to an iPXE console animation, chained by the
        adventure's hidden `apple` command. serveArtifacts publishes it at
        /boot/badapple.ipxe; a host serving /boot itself aliases it there too.
      '';
    };

    serveArtifacts = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Serve the netboot artifacts (netboot.ipxe, bzImage, initrd) over HTTP on
        a default :80 vhost, so an iPXE client that reaches this box by IP gets
        them. Leave false on a box that already serves /boot from another vhost
        (e.g. ghostgate's nixos.lv site vhost).
      '';
    };

    artifactsPath = lib.mkOption {
      type = lib.types.str;
      # The netboot-only passthru, NOT the full site: this pulls a ~2GB closure
      # (kernel + initrd + script) instead of the ~9.5GB site bundle (ISOs +
      # manual + pagefind), which a PXE-only router has no use for.
      default = "${pkgs.nixos-lv-onboarding-artifacts.netboot}";
      defaultText = lib.literalExpression ''"''${pkgs.nixos-lv-onboarding-artifacts.netboot}"'';
      description = "Directory holding netboot.ipxe, bzImage, and initrd (only used when serveArtifacts).";
    };
  };

  config = lib.mkIf cfg.enable {
    # TFTP: the PXE ROM fetches the iPXE binary here; iPXE then chainloads
    # ipxeScriptUrl over HTTP. Serves the read-only ${pkgs.ipxe} store path.
    # Bound to 0.0.0.0, but :69 is only reachable on interfaces the per-host
    # firewall trusts (LAN); the uplinks keep it closed.
    users.users.tftpd = {
      isSystemUser = true;
      group = "tftpd";
    };
    users.groups.tftpd = { };

    systemd.services.tftpd = {
      description = "TFTP server (iPXE netboot chainload)";
      after = [ "nftables.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = rec {
        User = "tftpd";
        Group = "tftpd";
        Restart = "always";
        RestartSec = 5;
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = AmbientCapabilities;
        Type = "exec";
        RuntimeDirectory = "tftpd";
        PIDFile = "${RuntimeDirectory}/tftpd.pid";
        ExecStart = "${pkgs.tftp-hpa}/bin/in.tftpd -v -l -a 0.0.0.0:69 -m ${tftpRemap} -P /run/${PIDFile} ${ipxeServe}";
        TimeoutStopSec = 20;
      };
    };

    # kea DHCP boot classes: arch-detect PXE ROMs (option 60) get the matching
    # iPXE binary over TFTP; once iPXE is running (option 77 = "iPXE") it gets
    # the HTTP script URL instead of looping on the binary. `client-classes` is a
    # disjoint key inside kea's freeform settings, so it merges with each host's
    # own subnet4/ddns block.
    services.kea.dhcp4.settings.client-classes = [
      {
        name = "XClient_iPXE";
        test = "substring(option[77].hex,0,4) == 'iPXE'";
        boot-file-name = cfg.ipxeScriptUrl;
      }
      {
        name = "UEFI-64-1";
        test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00007'";
        boot-file-name = "${ipxeServe}/ipxe.efi";
      }
      {
        name = "UEFI-64-2";
        test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00008'";
        boot-file-name = "${ipxeServe}/ipxe.efi";
      }
      {
        name = "UEFI-64-3";
        test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00009'";
        boot-file-name = "${ipxeServe}/ipxe.efi";
      }
      {
        name = "Legacy";
        test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00000'";
        boot-file-name = "${ipxeServe}/undionly.kpxe";
      }
    ];

    # Optional local artifact serving for boxes with no /boot vhost of their own.
    # iPXE connects by IP (no Host match), so this must be the default server.
    services.nginx = lib.mkIf cfg.serveArtifacts {
      enable = true;
      virtualHosts.pxe-netboot = {
        default = true;
        locations = {
          "= /boot/menu.ipxe".alias = "${cfg.gameScript}";
          "= /boot/badapple.ipxe".alias = "${cfg.movieScript}";
          "= /boot/netboot.ipxe".alias = "${cfg.artifactsPath}/netboot.ipxe";
          "= /boot/bzImage".alias = "${cfg.artifactsPath}/bzImage";
          "= /boot/initrd".alias = "${cfg.artifactsPath}/initrd";
        };
      };
    };
  };
}
