# Event network: floor LANs, the CTF, and public ingress

This covers the parts of the infra that only exist during the event and saw
heavy iteration: the LANs behind **ghostgate**, the **citadel** CTF/AI server,
how the floor reaches it, the public **TLS ingress on brass**, and the
split-horizon DNS that ties it together. It also collects the networking
footguns we hit so the next person doesn't rediscover them.

Shared helpers live in `modules/event-router/lib.nix` (`erlib`), imported into
ghostgate's and the VP2420s' `let` blocks. Prefer extending `erlib` over
copy-pasting router config between hosts.

## Floor LANs (behind ghostgate)

ghostgate is the border router. Behind it are three wired LANs plus the WiFi
mesh, each a `/24` described by `erlib.mkNet` (router at `.1`, DHCP pool
`.128–.254`, DHCP/DNS zone `<sub>.dc.nixos.lv`):

| Net     | CIDR         | Interface     | Purpose                         |
| ---     | ---          | ---           | ---                             |
| noc     | 10.4.0.0/24  | `noc` bridge  | Management / ops                |
| build   | 10.4.1.0/24  | `build` vlan  | Builders' underlay              |
| ctf     | 10.4.2.0/24  | `ctf` vlan    | CTF backbone to citadel         |
| arena   | 10.7/10.8    | `arena`       | Attendee LAN (per router)       |
| mesh    | 10.5.0.0/16  | `mesh2`       | 802.11s to the VP2420 routers   |

`build` and `ctf` are VLANs on an **802.3ad LACP bond** (`trunk`) over the
2×10G link between ghostgate and citadel. `noc` is a separate 2-port bridge.

### citadel — CTF + AI server

`devices/citadel`, deploy address `citadel.local` (on-path only). Runs:

- `ctf-server` — the Phoenix CTF app (`host = nixc.tf`), spawning challenge
  VMs with SSH on **26000–27023** (`vmPortRange` — the IANA-registered Quake
  range, deliberately squatted).
- `llama-cpp` (metalium) + `hardware.tenstorrent` (a `p150_x4` mesh).

citadel is **multi-homed**: on `noc` (10.4.0.132, DHCP), `build`, and `ctf`
(10.4.2.2, pinned). Only `ctf` carries a default route; `noc`/`build` are
`nogateway` (see the multi-default footgun). Its ctf address is pinned with
`networking.interfaces.ctf.macAddress` + a Kea reservation on ghostgate, so it
survives whichever bond member's MAC the LACP bond adopts.

## Reachability model

Goals: the CTF (`10.4.2.0/24`) reachable from **every arena** and from **noc**
with **real source IPs** (the CTF logs real attendee addresses — no NAT);
builders (`10.4.1.0/24`) reachable from noc.

- **Arena → ctf** (remote 2420 arenas *and* ghostgate's own arena): over Nebula
  via ghostgate. Each router installs `erlib.ctfUnsafeRoute` (a Nebula
  `unsafe_route` for `10.4.2.0/24` via ghostgate, `install = false`) plus a
  kernel route in the `arena` policy table (`erlib.ctfTableRoutes`). ghostgate's
  forward chain allows `arena`/`nebula.arena` ↔ `ctf`, and **ctf is excluded
  from masquerade** so real IPs survive.
- **noc → ctf / build**: local on ghostgate (`from <noc> lookup arena` policy
  routing + a `noc → {build,ctf}` forward rule). noc→ctf **is** masqueraded on
  ghostgate (see rp_filter footgun) so multi-homed citadel replies
  symmetrically; noc→build was already masqueraded (build is in the LAN masq
  set).
- **noc → builders over the Nebula overlay** (`10.6.9.x`): noc's Nebula egress
  is masqueraded on ghostgate, because the builders have no route back to the
  noc subnet and would otherwise never reply.

## Public ingress on brass

brass is the public IPv4 (`185.193.48.248`) and fronts every public name via
**L4 SNI routing on :443** (`services.nginx.streamConfig`, `ssl_preread`) plus
per-name `:80` handling. Names split three ways (`devices/brass/default.nix`
`let` block):

1. **Public passthrough** (`publicBackends`, e.g. `nixos.lv`): brass
   SNI-passes :443 straight through to the backend (`ghostgate:443`), which
   terminates its own TLS and runs its own HTTP-01 ACME (brass forwards :80
   to it). Fully public.
2. **Onsite-only** (`onsiteBackends`: `nixc.tf`, `www.nixc.tf`, `ctf.nixos.lv`,
   `ctf.nix.vegas`, `cache.nixos.lv`, `cache.nix.vegas`): must **not** be
   publicly reachable. brass **terminates them with its own LE cert and
   302-redirects to `https://nix.vegas`** on both :80 and :443.
   `acmeFallbackHost = <backend>` forwards any ACME token brass doesn't own to
   the backend, so the backend's *onsite* cert keeps renewing. These are **not**
   in the :443 SNI map. Attendees reach the real site via split-horizon DNS
   straight to the backend (citadel/ghostgate) with a valid cert — never
   through brass.
3. **brass-local** (`live.nix.vegas`/owncast): terminate on brass's local nginx
   at **:8443** (`defaultSSLListenPort = 8443`), reached via the stream's
   `default` upstream. The stream owns :443; all local nginx SSL is on :8443.

A `_default` server (`default = true; rejectSSL = true;` and `:80` → 302
nix.vegas) catches genuinely-unknown SNI/Host.

> **Why brass terminates the onsite names rather than rejecting them.** A public
> client hitting `https://nixc.tf` needs a *valid cert for nixc.tf* before any
> HTTP redirect can happen. `rejectSSL` yields `SSL_ERROR_UNRECOGNIZED_NAME`; a
> self-signed cert is a browser warning. brass holding its own LE cert +
> redirect is the only clean answer, and `acmeFallbackHost` keeps the backend's
> onsite cert issuing at the same time (brass serves its own challenge tokens
> from its webroot; anything it doesn't own is proxied to the backend). Both
> hosts end up with valid certs for the same name — no conflict.

## Split-horizon DNS

Onsite clients resolve the CTF/cache names to the **internal** host (valid cert,
direct path); the public resolves them to brass.

- **ghostgate + the 2420s** run kresd via `erlib.mkKresdExtraConfig`.
  `nixc.tf`/`www.nixc.tf` are answered by static **`hints`** → citadel
  (`erlib.ctfServer`, `10.4.2.2`); they can't live in the `nixos.lv` knot zone
  because `nixc.tf` is a separate registered domain. `ctf.nixos.lv` is answered
  via ghostgate's knot zone (CNAME → citadel) plus a 2420 `forwardZones` entry.
- **ghostgate's knot** zone (`nixos.lv`) holds static A records for ghostgate on
  each LAN — `ghostgate.{noc,build,ctf}.dc.nixos.lv` → the LAN gateway `.1` — so
  both the FQDN and bare `ghostgate` resolve. Bare `ghostgate` only works if the
  client has the LAN's DHCP search domain (e.g. `noc.dc.nixos.lv`), which Kea
  hands out; a statically-configured deploy box needs the FQDN or the search
  domain set manually. ghostgate isn't a DHCP client of itself, so these records
  are static (DDNS never creates them).
- `cache.nixos.lv` is harmonia over ghostgate's dedup+zstd store — the study
  winner — behind a plain nginx `proxy_pass`. A patched harmonia
  (`pkgs/harmonia/substitute-on-miss.patch`) makes misses non-blocking: on a
  narinfo miss it **302-redirects the client to cache.nixos.org** (a catch-all
  redirects the follow-up `nar/*.nar.xz` too), so the client never waits on
  us, and in the background it fetches the upstream narinfo over its own HTTPS
  to get the store path and asks the nix daemon to substitute it — so the next
  request for that path is served locally and the store converges on what the
  event actually uses. No nginx upstream proxy, no resolver listener. The
  `upstream.cache.nixos.lv` mirror and the `ghostgate-nar` pool are
  decommissioned (the study proved dedup+zstd ~10% smaller than storing
  upstream's xz NARs verbatim). See
  `docs/superpowers/specs/2026-07-16-harmonia-substitute-on-miss-design.md`.
- **brass's unbound** (`modules/unbound.nix`) is the Nebula-side split-horizon
  resolver; it deliberately does **not** answer the CTF names (onsite-only).

## Footguns (hard-won — read before touching the routers)

- **Zone files only know `;` comments.** A `#` comment in a `zoneText` is
  parsed as a resource record ("owner is invalid") and knot then refuses to
  load the *entire* zone. The failure is deceptively indirect: knot runs with
  no zone contents, so every name under `nixos.lv` SERVFAILs (ssh by name
  breaks, deploys break — the deploy address is in the zone), and every Kea
  DDNS update is rejected with `DDNS, processing failed (semantic check)` /
  RCODE 2, because knot applies updates against an empty zone whose apex has
  no SOA. `erlib.mkKnot` now runs `kzonecheck` at build time so this class of
  mistake fails the `nix build` instead.
- **Nebula multi-homed underlay pollution.** A multi-homed router advertises
  *every* local interface IP to the lighthouses, and peers try them all as
  underlay endpoints. Interfaces in ranges peers route *over* Nebula (the arena
  aggregates `10.7/10.8`, the overlay `10.6.0.0/16`) cause a peer's handshake to
  loop back into the tun and never land; stale/private ranges pollute every
  peer's candidate list. Symptom looks like a crypto failure but isn't (cert
  verifies, TPM ECDH matches). Fix: constrain
  `services.nebula.networks.arena.settings.lighthouse.{local,remote}_allow_list`
  to exclude the overlay + routed aggregates + `192.168/16` + the deploy LAN
  `10.3.0.0/16`; keep the real underlays (mesh `10.5`, build `10.4.1`). For a
  *roaming* node also deny the mesh in `remote_allow_list`. See the
  `nebula-multihomed-underlay-pollution` memory for the full write-up.
- **Never masquerade a Nebula/mesh underlay interface's own peer traffic.**
  Masquerading `mesh2` (the 802.11s underlay) rewrites source ports; when two
  peers each initiate a handshake the flows collide on the same 5-tuple and
  Nebula loops forever — while ICMP still works (deceptive). Exclude the mesh
  subnet: `oifname "mesh2" ip daddr != 10.5.0.0/16 masquerade`.
- **Multi-WAN asymmetric reply.** ghostgate runs multiple DHCP default routes
  for failover; Nebula binds `[::]` and answers via the lowest-metric default,
  so a handshake arriving on a secondary WAN is replied from the primary and the
  tunnel flaps. Prefer a single egress; the Nebula allow-lists also fix it
  structurally.
- **Strict rp_filter on multi-homed hosts.** citadel is on `noc` *and* `ctf`
  (`checkReversePath = true`). A real-source noc packet arriving on citadel's
  `ctf` interface fails strict rp_filter, because citadel's route back to the
  noc subnet is the `noc` interface, not `ctf`. Classic symptom: **noc→ctf works
  for ~30s after boot** (before citadel's noc-bridge DHCP installs the direct
  `10.4.0.0/24 dev noc` route), **then times out**; `rp_filter=2` on citadel
  doesn't fully fix it because the return path stays asymmetric. Fix:
  **masquerade noc→ctf on ghostgate** (`oifname "ctf" ip saddr <noc>
  masquerade`) so citadel sees ghostgate (`10.4.2.1`), whose reverse path always
  matches the arrival interface. Arena→ctf keeps real IPs (the rule only matches
  the noc subnet).
- **Bond MAC instability.** An 802.3ad bond adopts one member's MAC
  non-deterministically → DHCP reservations break across reboots. Pin
  `networking.interfaces.<x>.macAddress` on the pinned interface and reserve
  *that* MAC in Kea.
- **Policy routing must carry the local LANs.** noc/arena source traffic is sent
  to the `arena` table (`from <sub> lookup arena`), whose default is
  `dev nebula.arena`. That table must also carry the local `/24`s (`dev ctf`,
  `dev build`, `dev noc`) or LAN-to-LAN traffic gets black-holed into Nebula.
  Those routes are installed in the `nebula@arena` postStart (tolerant `set +e`,
  waits for the tun via `erlib.arenaPostStartPreamble`). If you see LAN traffic
  vanish ~30s after boot (when the postStart runs), check
  `ip route get <dst> from <src> iif <lan>` on ghostgate — it should say
  `dev ctf`/`dev build`, not `dev nebula.arena`.

## Deploy dependencies (external / operational — not in the repo)

- **Public DNS → brass** (`185.193.48.248`) for `nixc.tf`, `www.nixc.tf`,
  `ctf.nixos.lv`, `ctf.nix.vegas`, `cache.nixos.lv`, `cache.nix.vegas`,
  `nixos.lv`. (Onsite DNS is handled internally and needs no external change.)
- **ghostgate's Nebula cert** must include the ctf net (`10.4.2.0/24`, or the
  broader `10.4.0.0/16`) in its `unsafeNetworks`, or peers drop ctf-routed
  traffic. The cert is TPM-backed via nixpkcs — re-signed on the host, not in
  the repo.
- **ACME ordering:** brass + public DNS must be up first; the backends' certs
  *and* brass's onsite redirect certs issue via the :80 forward a few minutes
  after first deploy. Expect a brief self-signed-placeholder window on brass for
  the onsite names on first deploy.
- **Deploy order** when landing a full change: ghostgate → citadel → brass
  (→ the 2420s whenever convenient). brass's :443 is the one production-risk
  change (its own owncast/live moved behind the SNI router on :8443) — verify
  those after deploying brass.
- **Commits are unsigned in-session.** The signing key is a hardware
  `sk-ecdsa`/YubiKey needing physical touch. Re-sign before pushing:
  `git rebase --exec 'git commit --amend --no-edit -S' HEAD~<N>`.

## Where things live

| Path | What |
| --- | --- |
| `modules/event-router/lib.nix` | `erlib`: `mkNet`, `mkDhcp4Subnet`, `mkKnot`, `mkKresdExtraConfig` (+ `forwardZones`, `hints`), the arena/ctf route + policy-table helpers, `arenaPostStartPreamble` |
| `devices/ghostgate/default.nix` | Border router: nftables (firewall/nat), policy routing, Kea DHCP, knot/kresd, the noc/build/ctf nets + the LACP bond |
| `devices/citadel/default.nix` | CTF (`ctf-server`) + AI (llama/tenstorrent) server |
| `devices/brass/default.nix` | Public SNI ingress (`streamConfig` + the `publicBackends`/`onsiteBackends` split) + owncast |
| `modules/vp2420/default.nix` | ayem/seht/vehk travel routers (arena + kresd + Nebula) |
