{ ... }:
{
  boot = {
    initrd.availableKernelModules = [
      "xhci_pci"
      "nvme"
      "ahci"
      "thunderbolt"
      "usbhid"
    ];
    kernelModules = [ "kvm-amd" ];
  };

  networking = {
    hostName = "bigzam";
    hostId = "4cfde750";
  };

  system.stateVersion = "25.05";
  nixpkgs.system = "x86_64-linux";
}
