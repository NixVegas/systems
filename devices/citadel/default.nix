{ pkgs, lib, ... }:
{
  boot = {
    initrd.availableKernelModules = [
      "nvme"
      "xhci_pci"
      "ahci"
      "usbhid"
      "uas"
      "usb_storage"
      "sd_mod"
    ];
    kernelModules = [ "kvm-amd" ];
  };

  networking = {
    useDHCP = true; # TODO: set to false for NOC
    hostName = "citadel";
  };

  nixpkgs.system = "x86_64-linux";
}
