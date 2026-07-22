{
  config,
  pkgs,
  lib,
  modulesPath,
  freescout,
  ...
}:

let
  myHost = config.networking.mesh.plan.hosts.${config.networking.hostName};
  nebulaIp = myHost.nebula.address;
  nebulaIngress = lib.findFirst (lib.strings.hasInfix ".") null myHost.nebula.entryAddresses;
  nebula6Ingress = lib.findFirst (lib.strings.hasInfix ":") null myHost.nebula.entryAddresses;

  publicIpv4 = nebulaIngress;
  publicIpv6 = nebula6Ingress;

  nebulaSubnet = config.networking.mesh.plan.constants.nebula.subnet;

  # IP addresses of some containers.
  mattermostIp = "192.168.100.2";
  freescoutIp = "192.168.102.2";
  vaultwardenIp = "192.168.103.2";
  grafanaIp = "192.168.104.2";

  grafanaHttpPort = 3000;
  mimirHttpPort = 3200;

  nameservers = [
    "1.1.1.1"
    "1.0.0.1"
    "2606:4700:4700::1111"
    "2606:4700:4700::1001"
  ];

  mattermostPostgresZoneMount = "mattermost-postgres";
  freescoutPostgresZoneMount = "freescout-postgres";
  grafanaStateZoneMount = "grafana-state";
  mimirStateZoneMount = "mimir-state";

  externalInterface = "ens3";
in
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/swap.nix
    ../../modules/lasuite-meet.nix
    #../../services/prometheus-exporter
    #../../services/prometheus-exporter/arena.nix
  ];

  boot.loader = {
    limine.enable = false;
    grub = {
      enable = true;
      device = "/dev/vda";
    };
  };

  boot.zfs.devNodes = "/dev/disk/by-partlabel";

  fileSystems."/zones/gitea" = {
    device = "dagoth/user/zones/gitea";
    fsType = "zfs";
    options = [
      "rw"
      "nofail"
    ];
  };

  fileSystems."/zones/mattermost" = {
    device = "dagoth/user/zones/mattermost";
    fsType = "zfs";
    options = [
      "rw"
      "nofail"
    ];
  };

  fileSystems."/zones/mattermost-postgres" = {
    device = "dagoth/user/zones/mattermost/postgres";
    fsType = "zfs";
    options = [
      "rw"
      "nofail"
    ];
  };

  zones = {
    extraZoneMounts = [
      mattermostPostgresZoneMount
      freescoutPostgresZoneMount
      grafanaStateZoneMount
      mimirStateZoneMount
    ];
    inherit externalInterface;
  };

  networking =
    let
      egress = externalInterface;
    in
    {
      hostName = "dagoth";
      defaultGateway = {
        address = "151.236.16.1";
        interface = egress;
      };
      defaultGateway6 = {
        address = "2605:3b80:111::1";
        interface = egress;
      };
      interfaces.${egress} = {
        useDHCP = false;
        ipv4 = {
          addresses = [
            {
              address = publicIpv4;
              prefixLength = 24;
            }
          ];
        };
        ipv6 = {
          addresses = [
            {
              address = publicIpv6;
              prefixLength = 64;
            }
          ];
        };
      };

      inherit nameservers;
      mesh = {
        nebula = {
          enable = true;
          networkName = "arena";
          localDNSPort = 5353;
          localSSHPort = 2222;
        };
      };

      firewall = {
        enable = true;
        allowPing = true;
        allowedTCPPorts = [
          22
          80
          443
        ];
      };

      nat.extraCommands = ''
        # Flush the chains for redeploys
        iptables -t nat -F

        # Let containers get out
        iptables -t nat -I POSTROUTING -o ${externalInterface} -j MASQUERADE

        # NAT gateway for Nebula hosts
        iptables -I FORWARD -s ${nebulaSubnet} -d 0.0.0.0/0 -j ACCEPT
        iptables -t nat -I POSTROUTING -s ${nebulaSubnet} -j MASQUERADE

        # Redirect anything from Nebula and destined for the external IP internal
        iptables -t nat -I PREROUTING -p udp -s ${nebulaSubnet} -d ${nebulaIngress} -j REDIRECT

        # Redirect Nebula DNS and NTP queries
        iptables -t nat -I PREROUTING -p udp -s ${nebulaSubnet} --dport 53 -j REDIRECT
        iptables -t nat -I PREROUTING -p udp -s ${nebulaSubnet} --dport 123 -j REDIRECT

        # Allow shipping metrics via alloy to mimir from nebula
        iptables -t nat -I PREROUTING -p tcp -s ${nebulaSubnet} \
          --dport ${builtins.toString mimirHttpPort} -j DNAT --to-destination ${grafanaIp}:${builtins.toString mimirHttpPort}
      '';
    };

  environment.systemPackages = with pkgs; [
    wget
    vim
    htop
    git
    curl
    tmux
    nebula
    bind
  ];

  services.prometheus = {
    enable = false;
    port = 9001;
  };

  nixVegas.alloy = {
    mimirAddress = grafanaIp;
  };

  services.prometheus.scrapeConfigs = [
    {
      job_name = "node";
      static_configs = [
        {
          targets = [
            "${myHost.nebula.address}:${toString config.services.prometheus.exporters.node.port}"
            #"${config.networking.mesh.plan.hosts.whitegold.nebula.address}:${toString config.services.prometheus.exporters.node.port}"
          ];
        }
      ];
    }
    {
      job_name = "zfs";
      static_configs = [
        {
          targets = [
            "${myHost.nebula.address}:${toString config.services.prometheus.exporters.zfs.port}"
            #"${config.networking.mesh.plan.hosts.whitegold.nebula.address}:${toString config.services.prometheus.exporters.zfs.port}"
          ];
        }
      ];
    }
    {
      job_name = "nixos";
      static_configs = [
        {
          targets = [
            "${myHost.nebula.address}:9300"
            #"${config.networking.mesh.plan.hosts.whitegold.nebula.address}:9300"
          ];
        }
      ];
    }
    {
      job_name = "nebula";
      static_configs = [
        {
          targets = [
            "${myHost.nebula.address}:9200"
            #"${config.networking.mesh.plan.hosts.whitegold.nebula.address}:9200"
          ];
        }
      ];
    }
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  services.openntpd = {
    enable = true;
    servers = [
      "time.nist.gov"
      "pool.ntp.org"
    ];
    extraConfig = ''
      listen on ${nebulaIp}
    '';
  };

  services.fail2ban = {
    enable = lib.mkDefault true;
    ignoreIP =
      let
        subnet = config.networking.mesh.plan.constants.nebula.subnet or null;
      in
      lib.mkIf (subnet != null) [ subnet ];
    bantime-increment = {
      enable = true;
      rndtime = "4m";
    };
  };

  services.nginx =
    let
      letsEncryptEndpoint =
        options:
        lib.recursiveUpdate {
          forceSSL = true;
          enableACME = true;
        } options;
    in
    {
      enable = true;
      clientMaxBodySize = "256m";

      virtualHosts."chat.nix.vegas" = letsEncryptEndpoint {
        http2 = true;
        locations."/" = {
          proxyPass = "http://${mattermostIp}:8065";
          proxyWebsockets = true;
        };
      };

      # Legacy distractions.tw infra
      virtualHosts."chat.distractions.tw" = letsEncryptEndpoint {
        enableACME = true;
        forceSSL = true;
        globalRedirect = "chat.nix.vegas";
      };

      virtualHosts."webmail.nix.vegas" = letsEncryptEndpoint {
        http2 = true;
        locations."/" = {
          proxyPass = "http://${freescoutIp}:80";
          proxyWebsockets = true;
        };
      };

      virtualHosts."vault.nix.vegas" = letsEncryptEndpoint {
        http2 = true;
        locations."/" = {
          proxyPass = "http://${vaultwardenIp}:8222";
          proxyWebsockets = true;
        };
      };

      virtualHosts."grafana.nix.vegas" = letsEncryptEndpoint {
        http2 = true;
        locations."/" = {
          proxyPass = "http://${grafanaIp}:${builtins.toString grafanaHttpPort}";
          proxyWebsockets = true;
        };
      };

      virtualHosts."meet.nix.vegas" = letsEncryptEndpoint { };

      appendHttpConfig = ''
        geo $source {
          default public;
          ${nebulaSubnet} nebula;
        }
        server {
          listen 80 default_server;
          server_name _;
          location / {
            empty_gif;
          }
        }
      '';

      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
    };

  services.lasuite-meet =
    let
      meet = "meet.nix.vegas";
      kanidm = "auth.nix.vegas";
    in
    {
      domain = meet;
      settings = {
        LIVEKIT_API_URL = "https://${meet}/livekit/";
        LOGIN_REDIRECT_URL = "https://${meet}";
        LOGIN_REDIRECT_URL_FAILURE = "https://${meet}";
        OIDC_OP_AUTHORIZATION_ENDPOINT = "https://${kanidm}/ui/oauth2";
        OIDC_OP_JWKS_ENDPOINT = "https://${kanidm}/oauth2/openid/lasuite-meet/public_key.jwk";
        OIDC_OP_TOKEN_ENDPOINT = "https://${kanidm}/oauth2/token";
        OIDC_OP_USER_ENDPOINT = "https://${kanidm}/oauth2/openid/lasuite-meet/userinfo";
        OIDC_RP_CLIENT_ID = "lasuite-meet";
        OIDC_RP_SCOPES = "openid email profile";
        OIDC_RP_SIGN_ALGO = "ES256";
      };
    };

  security.acme = {
    acceptTerms = true;
    defaults.email = "noc@nix.vegas";
  };

  zones.zones = {
    mattermost = {
      config = {
        imports = [ ../../containers/mattermost.nix ];
        services.mattermost = {
          siteName = "Nix Vegas";
          siteUrl = "https://chat.nix.vegas";
        };
        networking = {
          useHostResolvConf = false;
          inherit nameservers;
        };
        system.stateVersion = "26.05";
      };
      privateNetwork = false;
      localAddress = mattermostIp;
      bindMounts = {
        "/var/lib/postgresql" = {
          hostPath = "${config.zones.zoneRoot}/${mattermostPostgresZoneMount}";
          isReadOnly = false;
        };
      };
    };

    freescout = {
      config = {
        imports = [
          freescout.nixosModules.freescout
          ../../containers/mail/freescout.nix
        ];
        networking = {
          useHostResolvConf = false;
          inherit nameservers;
        };
        services.freescout = {
          domain = "webmail.nix.vegas";
        };
        system.stateVersion = "26.05";
      };
      privateNetwork = false;
      localAddress = freescoutIp;
      bindMounts = {
        "/var/lib/postgresql" = {
          hostPath = "${config.zones.zoneRoot}/${freescoutPostgresZoneMount}";
          isReadOnly = false;
        };
      };
    };

    vaultwarden = {
      config = {
        imports = [
          ../../containers/vaultwarden.nix
        ];
        networking = {
          useHostResolvConf = false;
          inherit nameservers;
        };
        services.vaultwarden = {
          domain = "vault.nix.vegas";
          config = {
            ROCKET_ADDRESS = vaultwardenIp;
            SMTP_HOST = "mail.nix.vegas";
            SMTP_PORT = 465;
            SMTP_SECURITY = "force_tls";
            SMTP_FROM = "noreply@nix.vegas";
            SMTP_FROM_NAME = "Nix Vegas Vault";
            SSO_AUTHORITY = "https://auth.nix.vegas/oauth2/openid/vaultwarden";
            SSO_PKCE = true;
            SSO_CLIENT_ID = "vaultwarden";
          };
        };
        system.stateVersion = "26.05";
      };
      privateNetwork = false;
      localAddress = vaultwardenIp;
    };

    grafana = {
      config = {
        networking = {
          useHostResolvConf = false;
          inherit nameservers;

          firewall = {
            enable = true;
            allowPing = true;
            allowedTCPPorts = [
              grafanaHttpPort
              mimirHttpPort
            ];
          };
        };

        systemd.services.mimir.serviceConfig.DynamicUser = lib.mkForce false;

        services = {
          grafana = {
            enable = true;

            settings = {
              server = {
                domain = "grafana.nix.vegas";
                http_addr = "0.0.0.0";
                http_port = 3000;
                protocol = "http";
                root_url = "https://%(domain)s/grafana/";
                serve_from_sub_path = true;
              };
              security = {
                secret_key = "$__file{/var/lib/grafana/secret_key}";
                # bootstrap admin user pass
                admin_password = "$__file{/var/lib/grafana/admin.pass}";
              };
            };
            provision = {
              enable = true;

              datasources.settings.datasources = [
                {
                  name = "Mimir";
                  type = "prometheus";
                  access = "proxy";
                  url = "http://127.0.0.1:3200/prometheus";
                  isDefault = true;
                }
              ];
            };
          };
          mimir = {
            enable = true;

            configuration = {
              multitenancy_enabled = false;

              server = {
                grpc_listen_port = 9096;
                http_listen_port = mimirHttpPort;
              };

              common = {
                storage = {
                  backend = "filesystem";
                  filesystem = {
                    dir = "/var/lib/mimir/data";
                  };
                };
              };

              blocks_storage = {
                storage_prefix = "blocks";
                tsdb = {
                  dir = "/var/lib/mimir/tsdb";
                };
              };

              compactor = {
                data_dir = "/var/lib/mimir/compactor";
                compaction_interval = "30m";
              };

              ingester = {
                ring = {
                  replication_factor = 1;

                  kvstore = {
                    store = "inmemory";
                  };
                };
              };
            };
          };
        };
        system.stateVersion = "26.05";
      };
      privateNetwork = false;
      localAddress = grafanaIp;
      bindMounts = {
        "/var/lib/grafana" = {
          hostPath = "${config.zones.zoneRoot}/${grafanaStateZoneMount}";
          isReadOnly = false;
        };
        "/var/lib/mimir" = {
          hostPath = "${config.zones.zoneRoot}/${mimirStateZoneMount}";
          isReadOnly = false;
        };
      };
    };
  };

  nixpkgs.system = "x86_64-linux";
}
