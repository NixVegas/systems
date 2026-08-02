{
  lib,
  config,
  pkgs,
  ...
}:
{
  imports = [
    # Runs limine-install.py with Python safe-path so it doesn't scandir the
    # whole /nix/store on import (catastrophic on the cache host). No-ops on
    # grub hosts. Delete once the upstream shebang fix reaches our nixpkgs.
    ./limine-safepath.nix
  ];

  boot.kernelPackages = lib.mkDefault pkgs.linuxKernel.packages.linux_6_18;

  boot.kernel.sysctl = {
    "vm.swappiness" = lib.mkDefault 1;
  };

  boot.tmp = {
    useTmpfs = true;
    tmpfsHugeMemoryPages = "within_size";
    cleanOnBoot = true;
  };

  boot.loader = {
    limine = {
      enable = lib.mkDefault true;
      efiInstallAsRemovable = true;
      secureBoot = {
        enable = true;
        autoGenerateKeys = true;
        autoEnrollKeys.enable = true;
      };
    };
    efi.canTouchEfiVariables = lib.mkDefault false;
  };

  environment.systemPackages = with pkgs; [ sbctl ];

  console.font = lib.mkDefault "sun12x22";
  hardware.enableRedistributableFirmware = true;
}
