# systems

NixOS configurations and deploy tooling for the Nix Vegas ("Distractions")
infrastructure. Everything is a flake: `systems.nix` registers each machine,
`modules/` holds configuration shared by all of them, `mesh.nix` describes
the overlay network and binary-cache topology, and
[deploy-rs](https://github.com/serokell/deploy-rs) pushes it out.

## Quick start: deploying

Prerequisites:

- Nix with flakes enabled.
- Your user in `modules/users.nix` (wheel + SSH key), and already present on
  the target host — i.e. someone has deployed since you were added.
- deploy-rs on PATH: `nix develop` drops you into a shell that has it.

```console
$ nix develop
$ ./deploy ghostgate           # one host
$ ./deploy devices/ghostgate   # same thing — the wrapper takes the basename
$ ./deploy                     # all deployable hosts
```

The `./deploy` wrapper calls deploy-rs with rollbacks disabled
(`--auto-rollback false --magic-rollback false --rollback-succeeded false`),
`--skip-checks`, and `--interactive-sudo true` — it prompts for your sudo
password on the target. It SSHes as `$(whoami)`; override with
`DEPLOY_USER=<name> ./deploy <host>`. Any `--flag` arguments are forwarded
to deploy-rs, and `-L` is always passed to the underlying build.

Only hosts with an `address` in `systems.nix` can be deployed remotely:
ghostgate, adamantia, brass, crystal, dagoth. The rest (bigzam, saitama,
genos, tatsumaki, vivec) are updated on the machine itself:

```console
$ sudo nixos-rebuild switch --flake .#<host>
```

deploy-rs exits nonzero if activation fails. To double-check what a host is
running, compare `ssh <host> readlink /run/current-system` with the store
path printed during the deploy.

## Architecture

### Repo layout

| Path | Purpose |
| --- | --- |
| `flake.nix` | Inputs, the `nixosSystem`/`deploySystem` helpers, overlays, dev shell |
| `systems.nix` | Machine registry: NixOS version, module list, deploy address per host |
| `mesh.nix` | Mesh plan: Nebula addresses and roles, WiFi mesh, cache sets, public DNS names, SSH host keys |
| `devices/<host>/` | Per-machine configuration |
| `modules/` | Shared modules. boot/fs/misc/net/users/zones apply to every host (`commonModules` in `systems.nix`); the rest (`builder`, `arm-perf`, `kanidm`, `mail`, `pretalx`, `unbound`, ...) are opt-in per device |
| `containers/` | Service modules that run as NixOS containers ("zones") on a host |
| `pkgs/` | Custom packages (onboarding artifacts, pagefind site build, channel index) |
| `deploy` | deploy-rs wrapper script |
| `arena.ca.crt` | CA bundle for the Nebula mesh |

### Mesh

All hosts share a Nebula overlay network ("arena", `10.6.0.0/16`, CA
`arena.ca.crt`). Five hosts are lighthouses **and** relays: adamantia
(10.6.6.6), brass (10.6.6.7), crystal (10.6.6.8), and dagoth (10.6.6.9) are
publicly reachable VPSes; ghostgate (10.6.7.1) anchors the event network.
Builders sit at 10.6.8.x. There is also a MeshOS WiFi mesh (`10.5.0.0/16`)
with ghostgate as the AP (10.5.0.1) and vivec as a client.

`mesh.nix` is the source of truth for addresses, roles, cache sets, and SSH
host keys; each device additionally opts in with
`networking.mesh.nebula.enable = true` (see `devices/tatsumaki/default.nix`).

### Network core: ghostgate

ghostgate is the border router for the event network: nftables firewall,
Kea DHCP handing out iPXE netboot entries (TFTP plus nginx-served netboot
images), knot (authoritative DNS) with kresd (resolver), the MeshOS WiFi
AP, and an ncps cache proxy serving `cache.nixos.lv` to the floor. It boots
via limine with secure boot, keeps its Nebula key in the TPM2, and manages
the core CA on a YubiKey via nixpkcs.

### Build farm and caches

Cache roles are declared per host in `mesh.nix` (`cache.server` /
`cache.client`), grouped into named sets:

- `gvh-a` ("great-value-hydra"): served by saitama — Hydra CI plus a
  Harmonia binary cache (priority 10).
- `gvh-b`: bigzam's mirror of the same, at priority 20.
- `cnl` (`cache.nixos.lv`): served by ghostgate's ncps proxy, which itself
  consumes `gvh-a`/`gvh-b`.

genos and tatsumaki are plain builders (`modules/builder` +
`modules/arm-perf.nix`) and cache clients of `gvh-a`.

### Identity and services

- **adamantia** — Kanidm (SSO), mail stack (`modules/mail`), Immich, Unbound.
- **dagoth** — nginx + ACME in front of the nix.vegas services, which run as
  zones (NixOS containers managed by `modules/zones.nix`): Gitea
  (git.nix.vegas), Mattermost (chat.nix.vegas), FreeScout
  (webmail.nix.vegas), Vaultwarden (vault.nix.vegas). Also Prometheus,
  La Suite Meet, and fail2ban.
- **crystal** — Pretalx, Immich, Owncast.
- **brass** — Owncast, Unbound.

## Machines

| Host | Deploy address | Role |
| --- | --- | --- |
| adamantia | `adamantia.arena.nixos.lv` | Lighthouse VPS; Kanidm, mail, Immich, Unbound |
| bigzam | local only | Builder; `gvh-b` cache mirror; OBS Studio |
| brass | `brass.arena.nixos.lv` | Lighthouse VPS; Owncast, Unbound |
| crystal | `crystal.arena.nixos.lv` | Lighthouse VPS; Pretalx, Immich, Owncast |
| dagoth | `dagoth.arena.nixos.lv` | Lighthouse VPS; nix.vegas zones (Gitea, Mattermost, FreeScout, Vaultwarden), Prometheus, La Suite Meet |
| genos | local only | Builder |
| ghostgate | `10.3.7.136` | Event border router: DHCP/PXE, DNS, firewall, WiFi AP, cache proxy |
| saitama | local only | Hydra CI; Harmonia (`gvh-a`) |
| tatsumaki | local only | Builder (aarch64) |
| vivec | local only | Wireless monitoring: Kismet, GPSd; WiFi mesh client |

Quirks worth knowing:

- **dagoth** listens for SSH on port 42070 (`profile.sshOpts` in
  `systems.nix`; the deploy wrapper handles it).
- **ghostgate** uses limine + secure boot, keeps its Nebula key in the
  TPM2, and manages the core CA on a YubiKey via nixpkcs.
- **vivec** carries a custom kernel patch (Tremont support) in
  `devices/vivec/`.
- Details for any host live in `devices/<host>/default.nix`.

## How-to

### Add a new machine

1. Create `devices/<name>/default.nix` — `devices/tatsumaki/default.nix` is
   a minimal example. Set `networking.hostName`, hardware essentials
   (initrd kernel modules or a `hardware-configuration.nix`), and
   `nixpkgs.system` if the host is not x86_64-linux.
2. Register it in `systems.nix`: `version`,
   `modules = [ ./devices/<name> ] ++ commonModules`, and — if it should be
   remotely deployable — an `address`. Use `profile` for deploy-rs
   overrides (see dagoth's custom SSH port).
3. Add the host to `mesh.nix` under `networking.mesh.plan.hosts`: a unique
   `nebula.address` (builders live in 10.6.8.x), `ssh.hostKey`, and any
   cache roles. In the device config, set
   `networking.mesh.nebula = { enable = true; networkName = "arena"; }`.
4. Sanity-build:
   `nix build .#nixosConfigurations.<name>.config.system.build.toplevel`
5. Install the machine once by hand; after that it updates with
   `./deploy <name>` (or locally via `nixos-rebuild switch --flake .#<name>`).

### Add a user

1. Add an entry in `modules/users.nix` under `users.users`, following the
   existing ones: `isNormalUser = true`, `extraGroups = [ "wheel" ]`, and
   the person's SSH public key(s).
2. `wheel` grants sudo (`execWheelOnly`) and Nix `trusted-users`. Deploys
   use interactive sudo, so the account needs a password on the target —
   have an existing admin run `sudo passwd <user>` there.
3. Deploy. `modules/users.nix` is in `commonModules`, so the user lands on
   every host you deploy to.

### Add a container service (zone)

1. Create `containers/<service>.nix`: a plain NixOS module that enables the
   service and opens its firewall ports — `containers/gitea.nix` is the
   template.
2. On the hosting device (today that's dagoth), add a
   `zones.zones.<service>` entry: `config.imports` pulls in your module
   plus site-specific settings (domain, `system.stateVersion`), and set a
   unique `localAddress`. Persistent state (e.g. postgres) is bind-mounted
   under `zones.zoneRoot` (default `/zones`) — see the mattermost zone in
   `devices/dagoth/default.nix`. Zones are NixOS containers managed by
   `modules/zones.nix`.
3. If the service is public, add an nginx virtualHost + ACME entry on the
   host pointing at the zone's `localAddress`.
4. `./deploy <host>`.
