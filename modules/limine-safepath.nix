{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.boot.loader.limine;
  efi = config.boot.loader.efi;
in
{
  config = lib.mkIf cfg.enable {
    system.build.installBootLoader = lib.mkForce (
      let
        limineInstallConfig = pkgs.writeText "limine-install.json" (
          builtins.toJSON {
            inherit (config.system.nixos) distroName;
            nixPath = config.nix.package;
            efiBootMgrPath = pkgs.efibootmgr;
            liminePath = cfg.package;
            efiMountPoint = efi.efiSysMountPoint;
            fileSystems = config.fileSystems;
            luksDevices = builtins.attrNames config.boot.initrd.luks.devices;
            canTouchEfiVariables = efi.canTouchEfiVariables;
            efiSupport = cfg.efiSupport;
            efiRemovable = cfg.efiInstallAsRemovable;
            secureBoot = cfg.secureBoot;
            biosSupport = cfg.biosSupport;
            biosDevice = cfg.biosDevice;
            partitionIndex = cfg.partitionIndex;
            force = cfg.force;
            enrollConfig = cfg.enrollConfig;
            style = cfg.style;
            resolution = cfg.resolution;
            maxGenerations = if cfg.maxGenerations == null then 0 else cfg.maxGenerations;
            hostArchitecture = pkgs.stdenv.hostPlatform.parsed.cpu;
            timeout = if config.boot.loader.timeout == null then "no" else config.boot.loader.timeout;
            enableEditor = cfg.enableEditor;
            extraConfig = cfg.extraConfig;
            extraEntries = cfg.extraEntries;
            additionalFiles = cfg.additionalFiles;
            validateChecksums = cfg.validateChecksums;
            panicOnChecksumMismatch = cfg.panicOnChecksumMismatch;
          }
        );
        patchedSrc = pkgs.runCommand "limine-install-safepath.py" { } ''
          substitute \
            ${pkgs.path}/nixos/modules/system/boot/loader/limine/limine-install.py \
            $out --replace-fail '/bin/python3 -B' '/bin/python3 -BP'
        '';
      in
      pkgs.replaceVarsWith {
        src = patchedSrc;
        isExecutable = true;
        replacements = {
          python3 = pkgs.python3.withPackages (python-packages: [ python-packages.psutil ]);
          configPath = limineInstallConfig;
        };
      }
    );
  };
}
