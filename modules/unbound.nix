{
  lib,
  pkgs,
  config,
  ...
}:

{
  services = {
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

        inherit (config.networking.mesh.plan.hosts)
          adamantia
          brass
          ghostgate
          crystal
          ;
        coreNebulaIp = brass.nebula.address;
        onsiteNebulaIp = ghostgate.nebula.address;
        # nix.vegas is served by crystal, not brass (brass holds no cert for it,
        # so pointing there fails the TLS handshake with UNRECOGNIZED_NAME).
        siteNebulaIp = crystal.nebula.address;
        mailIpv4 = lib.findFirst (lib.strings.hasInfix ".") null adamantia.nebula.entryAddresses;
        mailIpv6 = lib.findFirst (lib.strings.hasInfix ":") null adamantia.nebula.entryAddresses;
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
            "ntp.arena.nixos.lv. IN A ${coreNebulaIp}"
            "cache.nixos.lv. IN CNAME cache.dc.nixos.lv."
            "cache.dc.nixos.lv. IN A ${onsiteNebulaIp}"
            "nix.vegas. IN A ${siteNebulaIp}"
            "live.nix.vegas. IN A ${coreNebulaIp}"
            "cache.nix.vegas. IN CNAME cache.dc.nixos.lv."
            "mail.nix.vegas. IN A ${mailIpv4}"
            "mail.nix.vegas. IN AAAA ${mailIpv6}"
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
  };
}
