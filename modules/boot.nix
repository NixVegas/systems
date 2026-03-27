{
  lib,
  config,
  ...
}:
{
  boot.kernel.sysctl = {
    "vm.swappiness" = lib.mkDefault 10;
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
