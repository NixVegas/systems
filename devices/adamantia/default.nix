{
  lib,
  config,
  pkgs,
  modulesPath,
  ...
}:

let
  myHost = config.networking.mesh.plan.hosts.${config.networking.hostName};
  nebulaIp = myHost.nebula.address;
  nebulaIngress = lib.findFirst (lib.strings.hasInfix ".") null myHost.nebula.entryAddresses;
  nebula6Ingress = lib.findFirst (lib.strings.hasInfix ":") null myHost.nebula.entryAddresses;
  nebulaEgress = "185.193.48.236";
  nebulaSubnet = config.networking.mesh.plan.constants.nebula.subnet;
in
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/swap.nix
  ];

  boot = {
    initrd.availableKernelModules = [
      "ata_piix"
      "uhci_hcd"
      "virtio_pci"
      "sr_mod"
      "virtio_blk"
    ];
  };

  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = true;
  };

  boot.loader = {
    systemd-boot.enable = false;
    grub = {
      enable = true;
      device = "/dev/vda";
    };
  };

  boot.zfs = {
    forceImportRoot = true;
    devNodes = "/dev/disk/by-partlabel";
  };

  environment.systemPackages = with pkgs; [
    git
    htop
    nebula
  ];

  environment.etc."fail2ban/filter.d/immich.conf".text = ''
    [INCLUDES]
    before = common.conf
    [Definition]
    _daemon = immich
    failregex = Failed login attempt for user.+from ip address\s?<ADDR>
    [Init]
    journalmatch = _SYSTEMD_UNIT=immich-server.service
  '';

  networking =
    let
      egress = "ens3";
    in
    {
      hostName = "adamantia";

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
              address = "151.236.16.225";
              prefixLength = 24;
            }
            {
              address = "151.236.16.78";
              prefixLength = 24;
            }
            {
              address = "185.193.48.236";
              prefixLength = 24;
            }
          ];
          routes = [
            {
              address = "151.236.16.0";
              prefixLength = 24;
            }
          ];
        };
        ipv6 = {
          addresses = [
            {
              address = "2605:3b80:111:163e::1";
              prefixLength = 64;
            }
          ];
        };
      };
      nameservers = [
        "1.1.1.1"
        "1.0.0.1"
        "2606:4700:4700::1111"
        "2606:4700:4700::1001"
      ];
      mesh = {
        nebula = {
          enable = true;
          networkName = "arena";
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
        allowedUDPPorts = [
          53
          5000
        ];
        interfaces.arena = {
          allowedTCPPorts = [ 1935 ];
          allowedUDPPorts = [
            1935
            5000
          ];
        };
      };

      nat = {
        enable = true;
        extraCommands = ''
          # Flush tables for redeploy.
          iptables -t nat -F

          # NAT gateway for Nebula hosts
          iptables -I FORWARD -s ${nebulaSubnet} -d 0.0.0.0/0 -j ACCEPT
          iptables -t nat -I POSTROUTING -s ${nebulaSubnet} -j MASQUERADE

          # Redirect anything from Nebula and destined for external IPs internal
          iptables -t nat -I PREROUTING -s ${nebulaSubnet} -d ${nebulaIngress} -j REDIRECT
          iptables -t nat -I PREROUTING -s ${nebulaSubnet} -d ${nebulaEgress} -j REDIRECT

          # Redirect Nebula DNS and NTP queries
          iptables -t nat -I PREROUTING -p udp -s ${nebulaSubnet} --dport 53 -j REDIRECT
          iptables -t nat -I PREROUTING -p udp -s ${nebulaSubnet} --dport 123 -j REDIRECT
        '';
      };
    };

  services = {
    avahi.enable = false;
    openntpd = {
      enable = true;
      servers = [
        "time.nist.gov"
        "pool.ntp.org"
      ];
      extraConfig = ''
        listen on ${nebulaIp}
      '';
    };
    unbound =
      let
        yes = "yes";
        no = "no";
        makeLocalData = data: map (x: "\"${x}\"") data;
        extraHosts = pkgs.stdenv.mkDerivation {
          name = "unbound-extra-hosts.conf";
          src = pkgs.writeText "extra-hosts" config.networking.extraHosts;
          phases = [ "installPhase" ];
          installPhase = ''
            ${pkgs.gawk}/bin/awk '{sub(/\r$/,"")} {sub(/^127\.0\.0\.1/,"0.0.0.0")} BEGIN { OFS = "" } NF == 2 && $1 == "0.0.0.0" { print "local-zone: \"", $2, "\" static"}' $src | tr '[:upper:]' '[:lower:]' | sort -u >  $out
          '';
        };

        coreNebulaIp = config.networking.mesh.plan.hosts."adamantia".nebula.address;
        onsiteNebulaIp = config.networking.mesh.plan.hosts."ghostgate".nebula.address;
      in
      {
        enable = true;
        settings.server = {
          # Listen on all interfaces, and allow access from Nebula-related routes.
          interface = [ "0.0.0.0" ];
          access-control = map (subnet: "${subnet} allow") (
            lib.singleton "127.0.0.0/8" ++ config.networking.mesh.plan.nebula.routes
          );

          # Domains that should be allowed to respond with private ranges.
          private-domain = [
            "nixos.lv."
          ];

          # "Private" IP ranges. We're sticking with RFC 1918 for now.
          private-address = [
            "10.0.0.0/8"
            "172.16.0.0/12"
            "192.168.0.0/16"
            "169.254.0.0/16"
          ];

          # Unbound hardening settings
          cache-max-ttl = 14400;
          cache-min-ttl = 300;
          hide-identity = yes;
          hide-version = yes;
          identity = "DNS";
          minimal-responses = yes;
          prefetch = yes;
          prefetch-key = yes;
          qname-minimisation = yes;
          rrset-roundrobin = yes;
          use-caps-for-id = yes;
          aggressive-nsec = yes;
          delay-close = 10000;
          val-clean-additional = yes;
          serve-expired = yes;
          so-reuseport = yes;
          harden-short-bufsize = yes;
          harden-glue = yes;
          harden-large-queries = yes;
          harden-dnssec-stripped = yes;
          harden-below-nxdomain = yes;
          harden-algo-downgrade = yes;
          deny-any = yes;

          local-data = makeLocalData [
            "nixos.lv. IN A ${onsiteNebulaIp}"
            "arena.nixos.lv. IN A ${coreNebulaIp}"
            "live.nixos.lv. IN A ${coreNebulaIp}"
            "adamantia.arena.nixos.lv. IN A ${coreNebulaIp}"
            "ntp.arena.nixos.lv. IN A ${coreNebulaIp}"
            "cache.nixos.lv. IN CNAME cache.dc.nixos.lv."
            "cache.dc.nixos.lv. IN A ${onsiteNebulaIp}"
            "nix.vegas. IN A ${coreNebulaIp}"
            "live.nix.vegas. IN A ${coreNebulaIp}"
            "cache.nix.vegas. IN CNAME cache.dc.nixos.lv."
          ];

          # Includes
          include = [ "${extraHosts}" ];
        };

        # Forward zones
        settings.forward-zone = [
          {
            name = "dc.nixos.lv.";
            forward-addr = [ onsiteNebulaIp ];
          }
          {
            name = ".";
            forward-addr = config.networking.nameservers;
          }
        ];
      };

    owncast = {
      enable = true;
    };

    immich = {
      enable = true;
      port = 2283;
    };

    immich-public-proxy = {
      enable = true;
      immichUrl = "http://localhost:${toString config.services.immich.port}";
      settings = {
        downloadOriginalPhoto = false;
        showGalleryTitle = true;
        allowDownloadAll = 1; # follow Immich setting
        showHomePage = false;
      };
    };

    fail2ban.jails = lib.mkMerge [
      (lib.mkIf config.services.immich.enable {
        immich.settings = {
          enabled = true;
          filter = "immich";
          port = "80,443";
        };
      })
    ];

    nginx = {
      enable = true;

      recommendedTlsSettings = true;
      recommendedGzipSettings = true;
      recommendedZstdSettings = true;
      recommendedBrotliSettings = true;
      recommendedProxySettings = true;
      recommendedUwsgiSettings = true;
      recommendedOptimisation = true;

      upstreams = {
        "ghostgate.dc.nixos.lv" = {
          servers = {
            ${config.networking.mesh.plan.hosts.ghostgate.nebula.address} = { };
          };
        };
        "owncast" = {
          servers = {
            "localhost:${toString config.services.owncast.port}" = { };
          };
        };
        "immich" = {
          servers = {
            "localhost:${toString config.services.immich.port}" = { };
          };
        };
        "immich-public-proxy" = {
          servers = {
            "localhost:${toString config.services.immich-public-proxy.port}" = { };
          };
        };
      };

      virtualHosts =
        let
          proxyLetsEncrypt =
            upstream: options:
            lib.recursiveUpdate {
              locations."/" = {
                extraConfig = "empty_gif;";
              };
              locations."/.well-known/acme-challenge" = {
                proxyPass = "http://${upstream}";
              };
            } options;
        in
        {
          # Useful for setting up split-horizon DNS with Let's Encrypt, little else.
          #"nixos.lv" = proxyLetsEncrypt "ghostgate.dc.nixos.lv" { };
          #"cache.nixos.lv" = proxyLetsEncrypt "ghostgate.dc.nixos.lv" { };

          # Just issue redirects to nix.vegas.
          "nixos.lv" = {
            forceSSL = true;
            enableACME = true;
            locations."/".root = "${pkgs.nix-vegas-site-offsite}/public";
          };

          # strip www
          "www.nixos.lv" = {
            addSSL = true;
            enableACME = true;
            globalRedirect = "nixos.lv";
          };

          # Just issue redirects to c.n.o.
          "cache.nixos.lv" = {
            addSSL = true;
            enableACME = true;
            globalRedirect = "cache.nixos.org";
          };

          # Redirect them to cache.nixos.lv.
          "cache.nix.vegas" = {
            addSSL = true;
            enableACME = true;
            globalRedirect = "cache.nixos.lv";
          };

          # strip www
          "www.nix.vegas" = {
            addSSL = true;
            enableACME = true;
            globalRedirect = "nix.vegas";
          };

          "nix.vegas" = {
            forceSSL = true;
            enableACME = true;
            locations."/".root = "${pkgs.nix-vegas-site-offsite}/public";
          };

          # In case they go here...
          "live.nixos.lv" = {
            forceSSL = true;
            enableACME = true;
            globalRedirect = "live.nix.vegas";
          };

          # We redirect them here.
          "live.nix.vegas" = {
            forceSSL = true;
            enableACME = true;
            locations."/" = {
              proxyPass = "http://owncast";
              proxyWebsockets = true;
            };
          };

          "relive.nixos.lv" = {
            forceSSL = true;
            enableACME = true;
            globalRedirect = "relive.nix.vegas";
          };

          "relive.nix.vegas" = {
            forceSSL = true;
            enableACME = true;
            locations."/" = {
              proxyPass = "http://$upstream";
              proxyWebsockets = true;
              extraConfig = ''
                client_max_body_size 10000m;
                proxy_max_temp_file_size 128m;
                proxy_request_buffering off;
                proxy_read_timeout   600s;
                proxy_send_timeout   600s;
                send_timeout         600s;

                set $upstream immich-public-proxy;
                if ($source = nebula) {
                  set $upstream immich;
                }
              '';
            };
          };
        };

        appendHttpConfig = ''
          geo $source {
            default public;
            ${nebulaSubnet} nebula;
          }
        '';
    };
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "noc@nix.vegas";
  };

  nixpkgs.system = "x86_64-linux";

  system.stateVersion = "25.05";
}
