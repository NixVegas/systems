{
  lib,
  config,
  ...
}:
{
  boot.kernel.sysctl = {
    "vm.swappiness" = 0;
    "fs.inotify.max_user_watches" = 16384;
  };

  boot.loader = {
    systemd-boot.enable = lib.mkDefault true;
    efi.canTouchEfiVariables = lib.mkDefault true;
  };

  console.font = lib.mkDefault "sun12x22";
  hardware.enableRedistributableFirmware = true;
}
