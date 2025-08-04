{ config, lib, ... }:

let
  inherit (lib.options) mkOption mkEnableOption mkIf mkMerge;
  inherit (lib) types;
in
{
  options = {
    nix.vegas = {
      onboarding = {
        enable = mkEnableOption "Nix Vegas onboarding";

      };
    };
  };

  config = {
    
  };
}
