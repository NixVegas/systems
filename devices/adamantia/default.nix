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

  kanidmCertsGroup = "certs-kanidm";
in
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/swap.nix
    ../../modules/kanidm.nix
    ../../modules/mail
    ../../modules/unbound.nix
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
    config.services.kanidm.package
    great-value-hydra.cachePkgs
    great-value-hydra.cacheUnstablePkgs
  ];

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
        interfaces.arena = {
          allowedTCPPorts = [ 1935 ];
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
    kanidm =
      let
        domain = "auth.nix.vegas";
        certsDir = config.security.acme.certs.${domain}.directory;
      in
      {
        serverSettings = {
          inherit domain;
          origin = "https://${domain}";
          tls_chain = "${certsDir}/fullchain.pem";
          tls_key = "${certsDir}/key.pem";
        };

        clientSettings = {
          uri = "https://${domain}";
        };

        provision = {
          enable = true;
          adminPasswordFile = "/etc/kanidm/admin.pass";
          idmAdminPasswordFile = "/etc/kanidm/admin.pass";
        };
      };
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
        "ghostgate.dc.nixos.lv" = {
          servers = {
            ${config.networking.mesh.plan.hosts.ghostgate.nebula.address} = { };
          };
        };
      };

      virtualHosts = {
        "mail.nix.vegas" = {
          enableACME = true;
          forceSSL = true;
          globalRedirect = "webmail.nix.vegas";
        };

        "mail.nixos.lv" = {
          forceSSL = true;
          enableACME = true;
          globalRedirect = "webmail.nix.vegas";
        };

        "auth.nix.vegas" = {
          forceSSL = true;
          enableACME = true;

          locations."/" = {
            proxyPass = "https://${config.services.kanidm.serverSettings.bindaddress}";
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

  mailserver =
    let
      tld = "nix.vegas";
    in
    {
      stateVersion = 3;
      fqdn = "mail.${tld}";
      domains = [ tld ];

      # We already have unbound
      localDnsResolver = false;

      # A list of all login accounts. To create the password hashes, use
      # nix-shell -p mkpasswd --run 'mkpasswd -s'
      loginAccounts = {
        "noc@${tld}" = {
          hashedPasswordFile = "/etc/mail/noc.pass";
          aliases = [
            "admin@${tld}"
            "postmaster@${tld}"
            "abuse@${tld}"
          ];
        };
        "cfp@${tld}" = {
          hashedPasswordFile = "/etc/mail/cfp.pass";
        };
        "sponsor@${tld}" = {
          hashedPasswordFile = "/etc/mail/sponsor.pass";
        };
        "media@${tld}" = {
          hashedPasswordFile = "/etc/mail/media.pass";
        };
        "chat@${tld}" = {
          hashedPasswordFile = "/etc/mail/chat.pass";
        };
        "system@${tld}" = {
          hashedPasswordFile = "/etc/mail/system.pass";
          aliases = [ "noreply@${tld}" ];
        };
      };
    };

  security.acme = {
    acceptTerms = true;
    defaults.email = "noc@nix.vegas";
    certs."auth.nix.vegas".group = kanidmCertsGroup;

    # We need to add this to the chain because DANE pins it
    certs."mail.nix.vegas".postRun =
      let
        isrgRoot = pkgs.fetchurl {
          url = "https://letsencrypt.org/certs/isrgrootx1.pem";
          hash = "sha256-IrVXonBVszYGtlWfN3A5KNPkrXnxELQH0EmG4YQ1Q9E=";
        };
      in
      ''
        cat ${isrgRoot} >> chain.pem
        cat ${isrgRoot} >> fullchain.pem
        cat ${isrgRoot} >> full.pem
      '';
  };

  users = {
    groups."kanidm" = { };
    groups.${kanidmCertsGroup} = { };

    # Can't go through systemd config due to infinite recursion
    users."kanidm" = {
      isSystemUser = true;
      group = "kanidm";
      extraGroups = [
        kanidmCertsGroup
      ];
    };

    users."${config.services.nginx.user}".extraGroups = [
      kanidmCertsGroup
    ];
  };

  nixpkgs.system = "x86_64-linux";
}
