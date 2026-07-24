{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    types
    ;

  inherit (lib.options)
    mkOption
    ;

  inherit (lib.modules)
    mkIf
    mkMerge
    ;

  inherit (lib.strings)
    optionalString
    ;

  cfg = config.nixVegas.alloy;
  alloyConfig = pkgs.writeText "config.alloy" ''
    // Prometheus exporter for host metrics (CPU, memory, disk, network, systemd)
    // Includes: zfs by default
    prometheus.exporter.unix "local" { }

    // Scrape the local unix exporter
    prometheus.scrape "local" {
      targets = prometheus.exporter.unix.local.targets
      forward_to = [prometheus.remote_write.mimir.receiver]
      scrape_interval = "15s"
    }

    prometheus.scrape "nebula" {
      targets = [{"__address__" = "127.0.0.1:9200", "instance" = constants.hostname}]
      forward_to = [prometheus.remote_write.mimir.receiver]
      scrape_interval = "10s"
      job_name = "nebula"
    }

    // Remote write to Mimir
    prometheus.remote_write "mimir" {
      endpoint {
        // we'll use the grafanaIp instead of the nebulaIp since were local
        url = "http://${cfg.mimirAddress}:${builtins.toString cfg.mimirHttpPort}/api/v1/push"
      }
    }
    ${optionalString (cfg.extraAlloyConfig != "") ''
      // Extra user-provided configuration
      ${cfg.extraAlloyConfig}
    ''}
  '';

in
{
  options.nixVegas = {
    alloy = {
      nebulaCollector = mkOption {
        type = types.bool;
        default = true;
        description = "Enable the Nebula collector";
      };
      mimirAddress = mkOption {
        type = types.str;
        default = config.networking.mesh.plan.hosts.dagoth.nebula.address;
        description = "address of grafana server to push to";
      };
      mimirHttpPort = mkOption {
        type = types.int;
        default = 3200;
        description = "Sets the root for zones.";
      };
      extraAlloyConfig = mkOption {
        type = types.lines;
        default = "";
        description = "extra appended alloy specific config";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.nebulaCollector {
      services.nebula.networks.arena.settings.stats = {
        type = "prometheus";
        listen = "127.0.0.1:9200";
        path = "/metrics";
        subsystem = "nebula";
        lighthouse_metrics = true;
        message_metrics = true;
        interval = "10s";
      };
    })

    {
      services.alloy = {
        enable = true;
        configPath = alloyConfig;
      };
    }
  ];
}
