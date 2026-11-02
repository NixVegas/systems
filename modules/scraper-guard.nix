# Scraper / abuse control for public nginx services: a per-client request
# budget on EVERY vhost by default (opt out per name, tune burst per name),
# plus fail2ban escalation for clients that keep tripping it or flood known
# bot probe paths. Enable per host.
#
#   nixVegas.scraperGuard = {
#     enable = true;
#     vhostLimits."relive.nix.vegas".burst = 100;             # asset-heavy UI
#     vhostLimits."cache.nixos.lv" = { rate = "200r/s"; burst = 2000; };  # own zone
#     # behind an L4 proxy (brass's SNI router)? see realIpFrom + banAction
#   };
#
# Division of labour: nginx `limit_req` is the shaper -- it caps a client at
# `rate` (burst `burst`) and 429s the excess, but keeps serving them at the
# cap forever. fail2ban is the escalation -- a client that trips the limiter
# `maxretry` times in `findtime` has proven it won't back off and is cut off
# entirely for `bantime` (escalating, via the fleet's bantime.increment). A
# second jail bans 404 floods against known probe paths (wp-login, .env ...),
# which never exceed the rate and so are invisible to limit_req. Both only see
# clients that EXCEED the rate; a scraper paced under it sails through -- the
# lever for that is a lower `rate`, not this module.
#
# HOW the default-on works: `limit_req` is set once at the http level, so nginx
# inherits it into every server and location. A level that sets its own
# limit_req replaces the inherited one, which is how vhostLimits works: it
# emits a server-level limit_req for just those names. A burst-only override
# reuses the shared zone; an override with its own `rate` needs its own zone
# (nginx has one rate per zone), which the module generates per vhost.
# Exclusions use nginx's own escape hatch: the zone is keyed on a
# `map $server_name` that yields an EMPTY key for excluded names, and
# "requests with an empty key value are not accounted". Keying on
# $server_name (the matched server's primary name) rather than $host means a
# client cannot exempt itself with a forged Host header. Because every
# location counts, size bursts to absorb one full page load of assets.
#
# WHERE the ban bites is the subtle part and is why banAction exists:
#   * Direct public ingress (adamantia, brass, crystal, dagoth): the client's
#     real address is the L3 source, so the fleet's default nftables ban is
#     strictly stronger -- it drops the IP at the firewall, and on brass that
#     cuts it off from everything behind the front door, L4 passthroughs
#     included. This is the default.
#   * Behind an L4 proxy (ghostgate behind brass's SNI router): every public
#     packet arrives from the proxy's IP, so a firewall ban on the real client
#     matches NOTHING. The real address only exists in-band via PROXY protocol
#     (realIpFrom), and the ban must be enforced where that address is visible:
#     an nginx `deny` include maintained by a custom fail2ban action
#     (banAction = "nginx-deny"). The host still owns its PROXY-protocol
#     listener (defaultListen with proxyProtocol = true); this module only
#     trusts the conveyed address.
#
# Everything gets a limit, but some services need a HIGH one via vhostLimits
# rather than the default: binary caches and anything that 302s to one (a nix
# client sustains hundreds of narinfo requests per second across a build, so
# they need a higher RATE, not just burst), streaming (HLS segment polling by a
# venue's worth of viewers behind one NAT), realtime/meeting apps, and
# dashboards that fan out many queries per page load (grafana). Gallery and
# chat UIs just need a bigger burst. Internal clients are exempt entirely:
# a geo on the realip'd address yields an EMPTY zone key for `internalRanges`
# (the never-ban set by default), and nginx does not account an empty key --
# the same mechanism as excludeVhosts, keyed on the client instead of the
# server. excludeVhosts is the last resort and should normally be empty.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixVegas.scraperGuard;
  nginxDeny = cfg.banAction == "nginx-deny";
  denyFile = "/var/lib/fail2ban/nginx-deny.conf";
  jailCommon = {
    enabled = true;
    findtime = cfg.findtime;
    bantime = cfg.bantime;
  }
  // lib.optionalAttrs nginxDeny { action = "nginx-deny"; };
  # vhosts whose rate differs from the global one get a dedicated zone, since
  # nginx has exactly one rate per limit_req zone.
  customRate = lib.filterAttrs (_: l: l.rate != cfg.rate) cfg.vhostLimits;
  zoneFor = name: "scraper_guard_" + lib.replaceStrings [ "." "-" ] [ "_" "_" ] name;
in
{
  options.nixVegas.scraperGuard = {
    enable = lib.mkEnableOption "per-client rate limiting on all nginx vhosts + fail2ban escalation";

    rate = lib.mkOption {
      type = lib.types.str;
      default = "10r/s";
      description = "Sustained per-client request rate (nginx limit_req_zone syntax). Applies to every location of every non-excluded vhost.";
    };

    burst = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        Default requests a client may burst above `rate` before being 429'd
        (nodelay). Every location counts (assets included), so size this to
        absorb one full page load; sustained navigation then refills at `rate`.
        Override per name with `vhostBurst`.
      '';
    };

    vhostLimits = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            rate = lib.mkOption {
              type = lib.types.str;
              default = cfg.rate;
              defaultText = lib.literalExpression "config.nixVegas.scraperGuard.rate";
              description = "Sustained rate for this vhost. Differing from the global rate allocates a dedicated zone.";
            };
            burst = lib.mkOption {
              type = lib.types.int;
              default = cfg.burst;
              defaultText = lib.literalExpression "config.nixVegas.scraperGuard.burst";
            };
          };
        }
      );
      default = { };
      example = {
        "relive.nix.vegas".burst = 100;
        "cache.nixos.lv" = {
          rate = "200r/s";
          burst = 2000;
        };
      };
      description = ''
        Per-vhost rate/burst overrides (vhost attribute name -> limits). Emits a
        server-level limit_req that replaces the inherited default for just
        that name; its locations inherit it in turn.
      '';
    };

    excludeVhosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "cache.nixos.lv"
        "live.nix.vegas"
      ];
      description = ''
        Primary server names (the vhost attribute name) exempt from the rate
        limit. See the header for what must always be excluded.
      '';
    };

    realIpFrom = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.6.6.7" ];
      description = ''
        Addresses whose PROXY-protocol client address is trusted (set_real_ip_from
        + real_ip_header proxy_protocol). Only for hosts behind an L4 proxy; the
        host must separately expose a listener with proxyProtocol = true. Empty
        for direct public ingress, where $remote_addr is already the client.
      '';
    };

    banAction = lib.mkOption {
      type = lib.types.enum [
        "nftables"
        "nginx-deny"
      ];
      default = "nftables";
      description = ''
        Where a fail2ban ban is enforced. "nftables": the fleet's default
        firewall ban (direct ingress; strongest). "nginx-deny": an HTTP-layer
        403 via an nginx `deny` include -- REQUIRED behind an L4 proxy, where a
        firewall ban on the real client IP would never match a packet.
      '';
    };

    extraIgnoreIP = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Internal ranges that must never be banned (LANs, mesh underlay). The
        Nebula subnet is already ignored fleet-wide (modules/net.nix).
      '';
    };

    egressLimit = {
      vhosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "cache.nixos.lv" ];
        description = ''
          Vhosts that get a per-client EGRESS ceiling (the binary cache). nginx
          has no true per-IP bandwidth zone; the ceiling is `connections` x
          `rate` via limit_conn + per-connection limit_rate. Applies to public
          clients only: addresses in `internalRanges` are unlimited and
          uncounted, so onsite builds pull at LAN speed.
        '';
      };
      rate = lib.mkOption {
        type = lib.types.str;
        default = "2m";
        description = "Per-connection limit_rate for public clients (nginx size syntax, e.g. 2m = 2 MB/s).";
      };
      after = lib.mkOption {
        type = lib.types.str;
        default = "8m";
        description = ''
          limit_rate_after: bytes of each response sent unthrottled before the
          rate applies, so narinfos and small NARs are never shaped -- only
          large NAR pulls are.
        '';
      };
      connections = lib.mkOption {
        type = lib.types.int;
        default = 32;
        description = ''
          Max concurrent connections per public client. MUST exceed nix's
          http-connections (default 25) or legitimate substitution fails;
          excess connections get 429 (nix retries those). Ceiling per client
          is roughly connections x rate (32 x 2m ~= 64 MB/s).
        '';
      };
    };

    internalRanges = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.services.fail2ban.ignoreIP;
      defaultText = lib.literalExpression "config.services.fail2ban.ignoreIP";
      description = ''
        CIDRs exempt from the rate limit AND the egress ceiling, matched by geo
        on the realip'd client address. Defaults to the same "never ban" set
        (Nebula + the host's extraIgnoreIP). Note that on a host whose
        extraIgnoreIP includes attendee LANs, those attendees are exempt too;
        narrow this to the fleet ranges if they should stay limited.
      '';
    };

    maxretry = lib.mkOption {
      type = lib.types.int;
      default = 20;
      description = "limit_req trips within `findtime` before a client is banned (the probe-path jail uses half).";
    };

    findtime = lib.mkOption {
      type = lib.types.str;
      default = "10m";
    };

    bantime = lib.mkOption {
      type = lib.types.str;
      default = "1h";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.nginx.enable;
        message = "nixVegas.scraperGuard needs services.nginx on this host.";
      }
    ];

    services.nginx.commonHttpConfig = ''
      ${lib.optionalString (cfg.realIpFrom != [ ]) ''
        # Behind an L4 proxy: trust the PROXY-protocol client address only from
        # the proxy itself; anyone else is logged as their own L3 address.
        ${lib.concatMapStrings (ip: "set_real_ip_from ${ip};\n") cfg.realIpFrom}real_ip_header proxy_protocol;
      ''}
      # nixVegas.scraperGuard: rate-limit every server by default. The zone key
      # is EMPTY -- which nginx does not account -- for internal clients (geo on
      # the realip'd address) and for excluded server names; otherwise it is
      # the client address.
      geo $scraper_guard_internal {
        default 0;
      ${lib.concatMapStrings (c: "  ${c} 1;\n") (lib.unique cfg.internalRanges)}}
      map $server_name $scraper_guard_vhost_key {
        default $binary_remote_addr;
      ${lib.concatMapStrings (v: "  ${v} \"\";\n") cfg.excludeVhosts}}
      map $scraper_guard_internal $scraper_guard_key {
        1 "";
        default $scraper_guard_vhost_key;
      }
      limit_req_zone $scraper_guard_key zone=scraper_guard:10m rate=${cfg.rate};
      ${lib.concatStrings (
        lib.mapAttrsToList (
          n: l: "limit_req_zone $scraper_guard_key zone=${zoneFor n}:10m rate=${l.rate};\n"
        ) customRate
      )}limit_req zone=scraper_guard burst=${toString cfg.burst} nodelay;
      limit_req_status 429;
      ${lib.optionalString nginxDeny ''
        # fail2ban's nginx-layer bans. A glob, not a bare path: nginx (and the
        # build-time gixy check) accept a glob that matches nothing, whereas a
        # missing bare include is a startup error. tmpfiles still creates the
        # file so bans apply from first boot.
        include /var/lib/fail2ban/nginx-deny*.conf;
      ''}
      ${lib.optionalString (cfg.egressLimit.vhosts != [ ]) ''
        # Egress ceiling for ${lib.concatStringsSep ", " cfg.egressLimit.vhosts}
        # (public clients only, via the same geo as the rate limit): internal
        # ranges get rate 0 (unlimited) and an empty limit_conn key
        # (uncounted). Ceiling per public client ~= connections x rate.
        map $scraper_guard_internal $scraper_guard_egress_rate {
          1 0;
          default ${cfg.egressLimit.rate};
        }
        map $scraper_guard_internal $scraper_guard_conn_key {
          1 "";
          default $binary_remote_addr;
        }
        limit_conn_zone $scraper_guard_conn_key zone=scraper_guard_conn:10m;
        limit_conn_status 429;
      ''}
    '';

    # mkMerge, not `//`: a vhost can be in both vhostLimits and egressLimit
    # (the cache is), and both extraConfigs must land, not the last one win.
    services.nginx.virtualHosts = lib.mkMerge [
      # Per-vhost limits: a server-level limit_req replaces the inherited
      # default for just these names (their locations inherit it in turn).
      (lib.mapAttrs (n: l: {
        extraConfig = ''
          limit_req zone=${if l.rate != cfg.rate then zoneFor n else "scraper_guard"} burst=${toString l.burst} nodelay;
        '';
      }) cfg.vhostLimits)
      # Egress ceiling: server-level so every location of the vhost inherits.
      (lib.genAttrs cfg.egressLimit.vhosts (_: {
        extraConfig = ''
          limit_rate_after ${cfg.egressLimit.after};
          limit_rate $scraper_guard_egress_rate;
          limit_conn scraper_guard_conn ${toString cfg.egressLimit.connections};
        '';
      }))
    ];

    services.fail2ban = {
      enable = true;
      ignoreIP = cfg.extraIgnoreIP;
      jails = {
        # Repeat offenders of the limiter: nginx logs "limiting requests" to
        # error.log at error level for every 429.
        nginx-limit-req.settings = jailCommon // {
          filter = "nginx-limit-req";
          logpath = "/var/log/nginx/error.log";
          maxretry = cfg.maxretry;
        };
        # 404 floods against known bot probe paths. The stock filter matches
        # only those paths, so ordinary 404s never count.
        nginx-botsearch.settings = jailCommon // {
          filter = "nginx-botsearch";
          logpath = "/var/log/nginx/access.log";
          maxretry = cfg.maxretry / 2;
        };
      };
    };

    # The nginx-layer ban action: maintain a `deny <ip>;` include and reload
    # nginx. Absolute store paths because fail2ban's action shell has no PATH.
    environment.etc."fail2ban/action.d/nginx-deny.conf" = lib.mkIf nginxDeny {
      text = ''
        [Definition]
        actionstart = ${pkgs.coreutils}/bin/touch ${denyFile}
        actionban   = ${pkgs.coreutils}/bin/echo "deny <ip>;" >> ${denyFile} && ${pkgs.systemd}/bin/systemctl reload nginx
        actionunban = ${pkgs.gnused}/bin/sed -i '/^deny <ip>;$/d' ${denyFile} && ${pkgs.systemd}/bin/systemctl reload nginx
      '';
    };
    # nginx `include`s the deny file at startup; make sure it exists first.
    systemd.tmpfiles.rules = lib.mkIf nginxDeny [ "f ${denyFile} 0644 root root -" ];
  };
}
