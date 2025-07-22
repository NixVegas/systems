{ ... }:
{
  imports = [
    ../modules/swap.nix
  ];

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

  hardware = {
    nvidia.open = true;
    graphics.enable = true;
  };

  networking = {
    hostName = "bigzam";
    hostId = "4cfde750";
  };

  services = {
    desktopManager.cosmic.enable = true;
    displayManager.cosmic-greeter.enable = true;
  };

  nixpkgs.system = "x86_64-linux";
}
