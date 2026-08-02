{
  lib,
  pkgs,
  ...
}:
{
  # All normal users get the desktop hardware groups + pkcs11 (users.nix applies).
  nixVegas.desktop = {
    enable = true;
    groups = [
      "networkmanager"
      "lp"
      "libvirtd" # virt-manager: talk to the libvirt socket without sudo
      "wireshark"
    ];
  };

  networking.mesh.cache.client = {
    enable = true;
    useHydra = false;
    trustHydra = true;
    useRecommendedCacheSettings = true;
  };

  # These boxes boot ZFS off partlabel'd disks (the fleet uses by-id; fs.nix
  # deliberately leaves devNodes to the NixOS default, so set it here).
  boot.zfs.devNodes = "/dev/disk/by-partlabel";
  # xanmod over boot.nix's `mkDefault linux_6_18`.
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_xanmod;

  # Standalone desktops don't run Nebula, but the shared meshos default module
  # (applied to every host via nixosModules.default) declares the `arena`
  # network, which defaults enabled and reads a CA the desktops never set (that
  # lives in mesh.nix, which they don't import). Turn the network off here.
  services.nebula.networks.arena.enable = lib.mkForce false;

  hardware = {
    # enableRedistributableFirmware is already set fleet-wide by boot.nix.
    bluetooth.enable = true;
    steam-hardware.enable = true;
    graphics = {
      enable = true;
      enable32Bit = true;
    };
  };

  security.pkcs11 = {
    enable = true;
    pcsc.enable = true; # pcsc.users is set for all normal users in users.nix
    tpm2.enable = true;
  };

  networking = {
    # hostId comes from fs.nix now (shared zfs module) -- no desktop specialization.
    networkmanager = {
      enable = true;
      dns = "systemd-resolved";
    };
  };

  programs = {
    steam = {
      enable = true;
      extest.enable = true;
      protontricks.enable = true;
      extraCompatPackages = with pkgs; [ proton-ge-bin ];
    };
    wireshark.enable = true;
    gnupg.agent.enable = true;
  };

  services = {
    thermald.enable = true;
    acpid.enable = true;
    printing = {
      enable = true;
      drivers = [
        pkgs.gutenprint
        pkgs.hplip
        pkgs.brlaser
      ];
    };
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;
    };
    resolved = {
      enable = true;
      dnssec = "allow-downgrade";
    };
    displayManager.cosmic-greeter.enable = true; # NO autoLogin
    desktopManager.cosmic.enable = true;
    libinput.enable = true;
  };

  virtualisation = {
    podman.enable = true;
    libvirtd.enable = true;
  };

  fonts.packages = [
    pkgs.input-fonts
    pkgs.nerd-fonts._3270
    pkgs.noto-fonts
  ];

  nixpkgs.config = {
    allowUnfree = true;
    input-fonts.acceptLicense = true;
  };

  # System-wide (every user), merged from the two per-host lists in ~/ops
  # (environment.systemPackages + users.users.numinit.packages).
  environment.systemPackages = with pkgs; [
    # base CLI/disk tooling
    psmisc
    pciutils
    man-pages
    binwalk
    file
    parted
    hdparm
    gptfdisk
    gparted
    smartmontools
    zip
    unzip
    android-tools # was programs.adb.enable (removed in 26.05; uaccess handles perms)
    # dev / net / desktop apps
    traceroute
    unbound
    bind
    (python3.withPackages (
      ps: with ps; [
        pip
        virtualenv
      ]
    ))
    (ruby.withPackages (
      ps: with ps; [
        nokogiri
        pry
      ]
    ))
    speedtest-cli
    pass
    pavucontrol
    wine
    chromium
    firefox
    virt-manager
    obsidian
    discord
    sanoid
    openmw
    kdePackages.kdenlive
    audacity
    obs-studio
    wireshark
    yubikey-manager
    yubioath-flutter
  ];
}
