# Shared building blocks for the Protectli event routers (ghostgate and the
# VP2420s). These are pure helper functions — import into a host's `let`:
#
#   erlib = import ../event-router/lib.nix { inherit lib pkgs; };
#
# and use them to build the kea / knot / kresd config that is otherwise
# duplicated near-verbatim across every router.
{ lib, pkgs }:

rec {
  # Network descriptor for a router-served subnet: a /24 (by default) with the
  # router itself at <base>.1 and a DHCP pool spanning <base>.128–.254.
  # `subdomain` names its DHCP/DNS zone under `domain` (e.g. "arena" ->
  # arena.dc.nixos.lv).
  mkNet =
    {
      id,
      base,
      prefix ? 24,
      subdomain,
      domain,
    }:
    rec {
      inherit id prefix subdomain;
      subnet = "${base}.0/${toString prefix}";
      address = "${base}.1";
      dhcpStart = "${base}.128";
      dhcpEnd = "${base}.254";
      dhcpDomain = "${subdomain}.${domain}";
    };

  # Fleet-wide arena LAN map (single source of truth) — see ./arena-hosts.nix.
  arenaHosts = import ./arena-hosts.nix;

  # This host's own arena network descriptor, looked up by hostname.
  mkArena =
    { self, domain }:
    mkNet {
      inherit (arenaHosts.${self}) id base;
      subdomain = "arena";
      inherit domain;
    };

  # Every *other* router's arena: { name; cidr; via; } where `via` is that
  # router's Nebula address (pulled from the mesh plan).
  arenaPeers =
    { self, planHosts }:
    lib.mapAttrsToList (name: a: {
      inherit name;
      cidr = "${a.base}.0/24";
      via = planHosts.${name}.nebula.address;
    }) (removeAttrs arenaHosts [ self ]);

  # Every arena CIDR (used to exclude inter-arena traffic from NAT).
  arenaCidrs = lib.mapAttrsToList (_: a: "${a.base}.0/24") arenaHosts;

  # Nebula unsafe_routes to every peer arena. install = false: the kernel
  # routes are managed explicitly in the nebula@arena postStart (table arena),
  # matching the existing default-route pattern.
  arenaUnsafeRoutes =
    args:
    map (p: {
      inherit (p) via;
      route = p.cidr;
      install = false;
    }) (arenaPeers args);

  # Arena space aggregated to /16 supernets. Every router points these at the
  # Nebula tun so Nebula can disaggregate them via its per-peer unsafe_routes.
  # Each router's own /24 (dev arena, added separately) is more specific than
  # its /16 aggregate, so local traffic always stays on the LAN.
  arenaAggregates = lib.unique (
    lib.mapAttrsToList (
      _: a:
      let
        o = lib.splitString "." a.base;
      in
      "${lib.elemAt o 0}.${lib.elemAt o 1}.0.0/16"
    ) arenaHosts
  );

  # Shell lines installing the aggregate arena routes into a policy table, for
  # use inside the nebula@arena postStart (which defines `_ip`). Uses `dev` with
  # NO `via`: peer Nebula IPs are not on-link on the tun, so a `via` route fails
  # to install — and Nebula routes by destination via its unsafe_routes anyway.
  arenaTableRoutes =
    {
      table ? "arena",
      dev ? "nebula.arena",
    }:
    lib.concatMapStrings (agg: "_ip route replace ${agg} dev ${dev} table ${table}\n") arenaAggregates;

  # Common preamble for the nebula@arena postStart. NixOS wraps the script in
  # `set -e`, which is fatal here: a single route that can't be installed yet
  # (mesh not up, tun not ready) would abort the rest — including the Nebula
  # routes. This flips to a tolerant shell, defines the `_ip` / `_rule_replace`
  # helpers, and waits for the Nebula tun so routes on it don't race the daemon.
  arenaPostStartPreamble =
    {
      ip,
      sleep,
      tun ? "nebula.arena",
    }:
    ''
      # Best-effort: never let one un-addable route abort the rest.
      set +e

      _ip() {
        ${ip} "$@"
      }

      _rule_replace() {
        if [ -z "$(_ip rule show "$@" || true)" ]; then
          _ip rule add "$@"
        fi
      }

      # Wait (up to ~30s) for the Nebula tun before installing routes on it.
      _tries=0
      while [ "$_tries" -lt 30 ] && ! _ip link show ${tun} >/dev/null 2>&1; do
        ${sleep} 1
        _tries=$((_tries + 1))
      done
    '';

  # The arena fleet's default internet gateway over Nebula (a cloud lighthouse).
  # Arena traffic sent into Nebula without a more-specific route exits here.
  arenaGatewayHost = "brass";

  # The 0.0.0.0/0 unsafe_route pointing arena internet traffic at that gateway.
  arenaDefaultRoute =
    {
      planHosts,
      gateway ? arenaGatewayHost,
    }:
    {
      route = "0.0.0.0/0";
      via = planHosts.${gateway}.nebula.address;
      install = false;
    };

  # The CTF backbone LAN, hosted behind ghostgate (see devices/ghostgate). Every
  # arena reaches it over Nebula via ghostgate so attendees can hit challenge
  # VMs; ghostgate delivers with real source IPs (no NAT). Keep `ctfNet` in sync
  # with ghostgate's `ctf` net descriptor.
  ctfNet = "10.4.2.0/24";
  ctfGateway = "ghostgate";
  # citadel's pinned ctf address (the DHCP reservation on ghostgate). The CTF
  # server terminates TLS here; internal split-horizon points nixc.tf at it.
  ctfServer = "10.4.2.2";

  # Nebula unsafe_route to the CTF backbone via ghostgate (kernel route managed
  # in the postStart, matching the arena aggregates — hence install = false).
  ctfUnsafeRoute =
    { planHosts }:
    {
      route = ctfNet;
      via = planHosts.${ctfGateway}.nebula.address;
      install = false;
    };

  # Shell line installing the CTF route into a policy table (for the nebula@arena
  # postStart). `dev nebula.arena`, no `via` — same reasoning as arenaTableRoutes.
  ctfTableRoutes =
    {
      table ? "arena",
      dev ? "nebula.arena",
    }:
    "_ip route replace ${ctfNet} dev ${dev} table ${table}\n";

  # A single kea `subnet4` entry from a net descriptor. `reservations` is
  # omitted entirely when empty, and `ntp` controls whether an ntp-servers
  # option is advertised — both to match the hand-written entries exactly.
  mkDhcp4Subnet =
    {
      net,
      reservations ? [ ],
      ntp ? true,
    }:
    {
      inherit (net) subnet id;
      pools = [ { pool = "${net.dhcpStart} - ${net.dhcpEnd}"; } ];
      ddns-qualifying-suffix = "${net.dhcpDomain}.";
      option-data = [
        {
          name = "routers";
          data = net.address;
          always-send = true;
        }
        {
          name = "domain-name-servers";
          data = net.address;
          always-send = true;
        }
        {
          name = "domain-name";
          data = net.dhcpDomain;
          always-send = true;
        }
      ]
      ++ lib.optional ntp {
        name = "ntp-servers";
        data = net.address;
        always-send = true;
      };
    }
    // lib.optionalAttrs (reservations != [ ]) { inherit reservations; };

  # kea dhcp-ddns settings feeding the local knot on 127.0.0.1:53535.
  mkDhcpDdns =
    { keyName, zoneName }:
    {
      forward-ddns.ddns-domains = [
        {
          name = "${zoneName}.";
          key-name = keyName;
          dns-servers = [
            {
              ip-address = "127.0.0.1";
              port = 53535;
            }
          ];
        }
      ];
      tsig-keys = [
        {
          name = keyName;
          algorithm = "HMAC-SHA256";
          secret-file = "/etc/kea/tsig.key";
        }
      ];
    };

  # knot serving one authoritative zone (`zoneText`) that kea-ddns updates.
  mkKnot =
    {
      baseDomain,
      zoneText,
      aclName,
      keyName,
    }:
    let
      zone = pkgs.writeTextDir "${baseDomain}.zone" zoneText;
      zonesDir = pkgs.buildEnv {
        name = "knot-zones";
        paths = [ zone ];
      };
    in
    {
      enable = true;
      extraArgs = [ "-v" ];
      keyFiles = [ "/etc/knot/tsig.conf" ];
      settings = {
        server.listen = "127.0.0.1@53535";
        log.syslog.any = "debug";
        acl.${aclName} = {
          key = keyName;
          action = "update";
        };
        template.default = {
          storage = zonesDir;
          zonefile-sync = -1;
          zonefile-load = "difference-no-serial";
          journal-content = "all";
        };
        zone.${baseDomain} = {
          file = "${baseDomain}.zone";
          acl = [ aclName ];
        };
      };
    };

  # kresd extraConfig: view-gated forwarding resolver. `subnets` are PASSed
  # (everything else DROPped); `ourDomains` are stubbed to the local knot;
  # `localDomains` are forwarded/stubbed there (STUB unless localForward);
  # `upstreams` is an ordered list of "ip@port" stubs for the root.
  mkKresdExtraConfig =
    {
      subnets,
      ourDomains,
      localDomains,
      upstreams,
      localForward ? false,
      # Split-horizon: forward specific suffixes to a chosen resolver, ahead of
      # the general upstream. Each entry is { domain = "ctf.nixos.lv."; server; }.
      forwardZones ? [ ],
      # Static A answers (split-horizon), e.g. { "nixc.tf" = "10.4.2.2"; } to
      # point a public name at an internal host ahead of its public answer.
      hints ? { },
      cacheSizeMB ? 32,
    }:
    let
      quote = xs: lib.concatMapStringsSep ", " (x: "'${x}'") xs;
      localPolicy =
        if localForward then "policy.FORWARD({'127.0.0.1@53535'})" else "policy.STUB('127.0.0.1@53535')";
    in
    ''
      cache.size = ${toString cacheSizeMB} * MB

      modules = {
        'policy',
        'view',
        'hints',
        'serve_stale < cache',
        'workarounds < iterate',
        'stats',
        'predict'
      }

      -- Static split-horizon answers (e.g. nixc.tf -> the internal CTF server),
      -- taking precedence over the public answer.
      ${lib.concatStrings (lib.mapAttrsToList (name: ip: "hints.set('${name} ${ip}')\n      ") hints)}
      -- Accept all requests from these subnets
      subnets = { ${quote subnets} }
      for i, v in ipairs(subnets) do
        view:addr(v, function(req, qry) return policy.PASS end)
      end

      -- Drop everything that hasn't matched
      view:addr('0.0.0.0/0', function (req, qry) return policy.DROP end)

      -- We are responsible for these.
      our_domains = { ${quote ourDomains} }
      policy:add(policy.domains(policy.STUB('127.0.0.1@53535'), policy.todnames(our_domains)))

      -- Forward requests for the local DHCP domains.
      local_domains = { ${quote localDomains} }
      for i, v in ipairs(local_domains) do
        policy:add(policy.suffix(${localPolicy}, {todname(v)}))
      end

      -- Split-horizon forwards (specific suffixes to a chosen resolver), ahead
      -- of the general upstream so e.g. ctf.nixos.lv resolves to the internal
      -- CTF server via ghostgate instead of the public front.
      ${lib.concatMapStringsSep "\n" (
        z: "policy:add(policy.suffix(policy.FORWARD('${z.server}'), {todname('${z.domain}')}))"
      ) forwardZones}

      -- Route upstream
      ${lib.concatMapStringsSep "\n" (
        u: "policy:add(policy.suffix(policy.STUB('${u}'), {todname('.')}))"
      ) upstreams}

      -- Prefetch learning (20-minute blocks over 24 hours)
      predict.config({ window = 20, period = 72 })
    '';
}
