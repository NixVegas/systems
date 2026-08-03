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
    perf
    wget
    curl
  ];

  systemd.services.nix-daemon.serviceConfig.LimitNOFILE = lib.mkForce 1073741816;

  programs.fix.enable = true;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  time.timeZone = "America/Los_Angeles";

  system.stateVersion = "26.05";
}
