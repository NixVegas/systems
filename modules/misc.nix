{
  lib,
  config,
  pkgs,
  ...
}:
{
  environment.systemPackages = with pkgs; [
    git
    vim-full
    neovim
    htop
    btop
    iftop
    config.boot.kernelPackages.perf
  ];

  systemd.services.nix-daemon.serviceConfig.LimitNOFILE = lib.mkForce 1073741816;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = lib.mkAfter [ "https://cosmic.cachix.org/" ];
    trusted-public-keys = lib.mkAfter [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
  };

  time.timeZone = "America/Los_Angeles";

  system.stateVersion = "25.05";
}
