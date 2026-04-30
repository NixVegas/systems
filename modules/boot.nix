{
  lib,
  config,
  pkgs,
  ...
}:
{
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
    systemd-boot.enable = lib.mkDefault true;
    efi.canTouchEfiVariables = lib.mkDefault true;
  };

  console.font = lib.mkDefault "sun12x22";
  hardware.enableRedistributableFirmware = true;
}
