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

  hardware.tenstorrent = {
    enable = true;
    meshName = "p150_x4";
  };

  services = {
    llama-cpp = {
      enable = true;
      package = pkgs.llama-cpp-metalium;
      openFirewall = true; # TODO: proper network slices between priv/pub side
    };
    ctf-server = {
      enable = true;
      openFirewall = true; # TODO: proper network slices between priv/pub side
      secretKeyBaseFile = "/run/secrets/ctf-secret-key-base";
    };
    postgresql.ensureDatabases = [
      "ctf-server"
    ];
  };

  systemd.services.llama-cpp.serviceConfig = {
    MemoryDenyWriteExecute = lib.mkForce false;
    ProcSubset = lib.mkForce "all";
  };

  nixpkgs.system = "x86_64-linux";
}
