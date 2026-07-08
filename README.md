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
