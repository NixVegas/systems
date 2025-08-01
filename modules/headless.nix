{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/headless.nix")
  ];
}
