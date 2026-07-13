{
  pkgs,
  lib,
  config,
  ...
}:
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
      host = "0.0.0.0"; # TODO: bind to priv slice only + add auth before public
      extraFlags = [
        "-hf"
        "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:Q4_K_M"
        "-nkvo"
      ];
      openFirewall = true; # TODO: proper network slices between priv/pub side
    };
    ctf-server = {
      enable = true;
      openFirewall = true; # TODO: proper network slices between priv/pub side
      host = "citadel.local";
    };
    postgresql.ensureDatabases = [
      "ctf-server"
    ];
  };

  systemd.services.llama-cpp = {
    serviceConfig = {
      MemoryDenyWriteExecute = lib.mkForce false;
      ProcSubset = lib.mkForce "all";
    };

    environment = {
      inherit (config.environment.variables) TT_MESH_GRAPH_DESC_PATH GGML_METALIUM_MESH_SHAPE;
    };
  };

  environment.variables.GGML_METALIUM_MESH_SHAPE = "2x2";

  nixpkgs.system = "x86_64-linux";
}
