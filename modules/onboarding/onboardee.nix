{ config, lib, ... }:

{
  nix.settings.substituters = lib.mkBefore [ "https://cache.nixos.lv" ];
  system.nixos.vendorName = "Nix Vegas";
}
