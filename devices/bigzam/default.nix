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

  nixpkgs.system = "x86_64-linux";
}
