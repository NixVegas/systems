# Shared ntpd-rs setup for the event routers (ghostgate and the 2420s): a
# modern, memory-safe NTP server that answers the LANs' redirected udp/123,
# disciplines its own clock from the given upstream sources (and optionally a
# local GPS via gpsd), and exports Prometheus metrics (scraped by alloy — see
# modules/alloy.nix `ntpCollector`).
{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.nixVegas.ntp;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    optional
    ;
  hasGps = cfg.gpsdSock != null;
in
{
  options.nixVegas.ntp = {
    enable = mkEnableOption "ntpd-rs time service (serves :123 for the LANs, exports Prometheus metrics)";

    servers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "time.nist.gov"
        "0.pool.ntp.org"
      ];
      description = ''
        Upstream NTP sources. Entries containing "pool" become pool sources, the
        rest server sources.
      '';
    };

    gpsdSock = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "chrony.ttyUSB0.sock";
      description = ''
        If set, wire the local gpsd into ntpd-rs as a `sock` source. This is the
        chrony-protocol socket filename gpsd writes to; gpsd names it after the
        GPS device basename, so verify it on-site with `ls /run/chrony.*.sock`.
        Enabling this adds the RuntimeDirectory + socket shim + gpsd ordering the
        ntpd-rs GPS/PPS guide requires.
      '';
    };

    metricsPort = mkOption {
      type = types.port;
      default = 9975;
      description = "Localhost port for the ntp-metrics-exporter (scraped by alloy).";
    };

    minimumAgreeingSources = mkOption {
      type = types.ints.positive;
      # With a GPS or only a couple of upstreams there aren't 3 to form a
      # quorum; GPS is hard to spoof so a single agreeing source is acceptable.
      default = if hasGps || lib.length cfg.servers < 3 then 1 else 3;
      defaultText = "1 with a GPS or <3 upstreams, else 3";
      description = "ntpd-rs synchronization.minimum-agreeing-sources.";
    };
  };

  config = mkIf cfg.enable {
    services.ntpd-rs = {
      enable = true;
      metrics.enable = true; # ntp-metrics-exporter, scraped by alloy's ntpCollector
      useNetworkingTimeServers = false; # sources are listed explicitly below
      settings = {
        source =
          (map (s: {
            mode = if lib.strings.hasInfix "pool" s then "pool" else "server";
            address = s;
          }) cfg.servers)
          ++ optional hasGps {
            # GPS (and PPS, if gpsd has it) via gpsd's chrony socket. precision is
            # our estimate of the source's 1-sigma noise; ~1ms suits a USB GPS.
            mode = "sock";
            path = "/run/ntpd-rs/${cfg.gpsdSock}";
            precision = 1.0e-3;
          };
        # Answer the LANs' redirected NTP.
        server = [ { listen = "0.0.0.0:123"; } ];
        observability.metrics-exporter-listen = "127.0.0.1:${toString cfg.metricsPort}";
        synchronization.minimum-agreeing-sources = cfg.minimumAgreeingSources;
      };
    };

    # --- GPS -> ntpd-rs socket plumbing (only when a gpsd sock is configured) --
    # ntpd-rs runs sandboxed and creates its chrony socket under a RuntimeDirectory;
    # gpsd instead looks for /run/chrony.<dev>.sock, so symlink that to the real
    # one, and only start gpsd once ntpd-rs has created the socket.
    systemd.services.ntpd-rs.serviceConfig.RuntimeDirectory = mkIf hasGps "ntpd-rs";

    systemd.services.ntpd-rs-gpsd-shim = mkIf hasGps {
      description = "gpsd chrony-socket shim for ntpd-rs";
      after = [ "ntpd-rs.service" ];
      requires = [ "ntpd-rs.service" ];
      before = [ "gpsd.service" ];
      wantedBy = [ "gpsd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "ntpd-rs-gpsd-shim" ''
          # Wait for ntpd-rs to create the sock-source socket, then expose it
          # where gpsd expects it.
          for _ in $(seq 1 50); do
            [ -S /run/ntpd-rs/${cfg.gpsdSock} ] && break
            sleep 0.2
          done
          exec ${pkgs.coreutils}/bin/ln -sfT /run/ntpd-rs/${cfg.gpsdSock} /run/${cfg.gpsdSock}
        '';
        ExecStop = "${pkgs.coreutils}/bin/rm -f /run/${cfg.gpsdSock}";
      };
    };

    # gpsd must come up after ntpd-rs + the shim so the socket exists. (NixOS
    # gpsd is socket-activated via gpsd.socket — verify the ordering holds.)
    systemd.services.gpsd = mkIf hasGps {
      after = [
        "ntpd-rs.service"
        "ntpd-rs-gpsd-shim.service"
      ];
      wants = [ "ntpd-rs-gpsd-shim.service" ];
    };
  };
}
