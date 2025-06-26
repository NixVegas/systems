{
  lib,
  config,
  ...
}:
{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    substituters = [ "https://cosmic.cachix.org/" ];
    trusted-public-keys = [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
  };

  system.stateVersion = "25.05";
}
