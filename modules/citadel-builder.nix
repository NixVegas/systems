# Makes a host a remote-build client of citadel — the shared "huge box" builder
# on the build net (10.4.1.2 / citadel.build.dc.nixos.lv). Auth reuses the mesh
# plan's SSH host keys, no new secrets: this host offloads over SSH using its
# own /etc/ssh/ssh_host_ed25519_key, whose pubkey citadel carries in the `build`
# user's authorized_keys (see devices/citadel). citadel's host key (from the
# plan) is pinned so there's no TOFU. Imported by ghostgate and the 2420s.
#
# Reachability: ghostgate is on the build net directly. The 2420s reach it over
# Nebula via ghostgate (buildUnsafeRoute/buildTableRoutes) — which requires
# ghostgate's Nebula cert to be signed with 10.4.1.0/24, like ctf's net.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  erlib = import ./event-router/lib.nix { inherit lib pkgs; };
  planHosts = config.networking.mesh.plan.hosts;
  builderHost = "citadel.build.dc.nixos.lv";
  builderIp = erlib.buildServer;
  # knownHosts wants "type base64" — strip the trailing "root@citadel" comment.
  citadelHostKey = lib.concatStringsSep " " (
    lib.take 2 (lib.splitString " " planHosts.citadel.ssh.hostKey)
  );
in
{
  nix.distributedBuilds = true;
  # citadel is on a 10G link with its own fat pipe to cache.nixos.lv, so let it
  # fetch build inputs itself instead of the client shipping every dep over.
  nix.settings.builders-use-substitutes = true;

  nix.buildMachines = [
    {
      hostName = builderHost;
      sshUser = "nix-ssh";
      sshKey = "/etc/ssh/ssh_host_ed25519_key";
      # ssh-ng, not the legacy ssh:// (nix-store --serve) protocol — the latter
      # connects but returns no usable store handshake here, so the build-hook
      # silently declines the builder. ssh-ng speaks the daemon protocol and
      # reports Trusted: 1.
      protocol = "ssh-ng";
      systems = [ "x86_64-linux" ];
      maxJobs = 8;
      speedFactor = 20;
      supportedFeatures = [
        "benchmark"
        "big-parallel"
        "kvm"
        "nixos-test"
      ];
    }
  ];

  programs.ssh.knownHosts.citadel-build = {
    hostNames = [
      builderHost
      builderIp
    ];
    publicKey = citadelHostKey;
  };
}
