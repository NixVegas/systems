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

  publicIpv4 = nebulaIngress;
  publicIpv6 = nebula6Ingress;
  nebulaEgress = publicIpv4;

  nebulaSubnet = config.networking.mesh.plan.constants.nebula.subnet;
in
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/swap.nix
    ../../modules/pretalx
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
    limine.enable = false;
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
    openssl
    net-tools
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
      hostName = "crystal";

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
              address = publicIpv6;
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
    };

  services = {
    immich = {
      enable = true;
      port = 2283;
    };

    immich-public-proxy = {
      enable = true;
      immichUrl = "http://localhost:${toString config.services.immich.port}";
      settings = {
        allowSlugLinks = true;
        downloadOriginalPhoto = false;
        showGalleryTitle = true;
        allowDownload = 1; # follow Immich setting
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
      recommendedBrotliSettings = true;
      recommendedProxySettings = true;
      recommendedUwsgiSettings = true;
      recommendedOptimisation = true;

      upstreams = {
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

      virtualHosts = {
        # Just issue redirects to nix.vegas.
        "nixos.lv" = {
          forceSSL = true;
          enableACME = true;
          locations."/".root = "${pkgs.nix-vegas-site}/public";
        };

        # strip www
        "www.nixos.lv" = {
          addSSL = true;
          enableACME = true;
          globalRedirect = "nixos.lv";
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
          locations."/".root = "${pkgs.nix-vegas-site}/public";
        };

        "relive.nixos.lv" = {
          forceSSL = true;
          enableACME = true;
          globalRedirect = "relive.nix.vegas";
        };

        # relive.nix.vegas is full immich (login-gated) so attendees/speakers can
        # upload, EXCEPT /share/... which stays on immich-public-proxy: IPP owns
        # that URL scheme (e.g. /share/photo/<key>/<id>/preview) and those are
        # the read-only permalinks the blog references. immich itself does not
        # serve /share/... paths, so without this split the blog's photo links
        # 404. immich's own shared links use /s/<slug>, which falls through to
        # the immich upstream below and keeps working. immich's auth gates the
        # app (fail2ban jail covers brute force).
        "relive.nix.vegas" = {
          forceSSL = true;
          enableACME = true;
          locations = {
            # Read-only public galleries + asset permalinks (blog-referenced).
            "/share/" = {
              proxyPass = "http://immich-public-proxy";
              extraConfig = ''
                proxy_read_timeout 600s;
                proxy_buffering off; # stream media instead of buffering to disk
              '';
            };
            # The immich app, its /s/<slug> native shares, /api, uploads.
            "/" = {
              proxyPass = "http://immich";
              proxyWebsockets = true;
              extraConfig = ''
                client_max_body_size 10000m;
                proxy_max_temp_file_size 128m;
                proxy_request_buffering off;
                proxy_read_timeout   600s;
                proxy_send_timeout   600s;
                send_timeout         600s;
              '';
            };
          };
        };

        # strip www
        "www.sophg.one" = {
          addSSL = true;
          enableACME = true;
          globalRedirect = "sophg.one";
        };

        "sophg.one" = {
          forceSSL = true;
          enableACME = true;
          locations."/".root = "${pkgs.sophgone-website}/public";
        };

        ${config.services.pretalx.nginx.domain} = {
          forceSSL = true;
          enableACME = true;
        };

        "cfp.nixos.lv" = {
          forceSSL = true;
          enableACME = true;
          globalRedirect = config.services.pretalx.nginx.domain;
        };
      };

      appendHttpConfig = ''
        geo $source {
          default public;
          ${nebulaSubnet} nebula;
        }
      '';
    };

    pretalx = {
      settings = {
        files.upload_limit = 256;
        mail = {
          from = "cfp@nix.vegas";
          host = "mail.nix.vegas";
          port = 465;
          user = "cfp@nix.vegas";
          ssl = true;
        };
      };
      nginx = {
        enable = true;
        domain = "cfp.nix.vegas";
      };
    };
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "noc@nix.vegas";
  };

  nixpkgs.system = "x86_64-linux";
}
