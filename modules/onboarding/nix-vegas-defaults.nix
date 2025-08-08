{ lib, ... }:

# This file was included in this built configuration as a default.
# If you want to use its settings when you rebuild your system,
# make sure you add `imports = [ ./nix-vegas-defaults.nix ];` to your configuration.nix
{
  # Work on serial consoles
  boot.kernelParams = lib.mkAfter [
    "console=tty0"
    "console=ttyS0,115200n8"
  ];

  # Use our binary cache as the first substituter
  nix.settings.substituters = lib.mkBefore [ "https://cache.nixos.lv" ];

  # Customize the vendor name
  system.nixos.vendorName = "Nix Vegas";

  # Include this file in /etc/nixos
  environment.etc."nixos/configuration-nix-vegas.nix".text =
    builtins.readFile ./nix-vegas-defaults.nix;
}
