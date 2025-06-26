{
  lib,
  config,
  ...
}:
{
  systemd.services.nix-daemon.serviceConfig.LimitNOFILE = lib.mkForce 1073741816;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    substituters = [ "https://cosmic.cachix.org/" ];
    trusted-public-keys = [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
  };

  system.stateVersion = "25.05";
}
