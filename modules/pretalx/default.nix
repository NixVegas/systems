{
  pkgs,
  config,
  ...
}:

{
  services.pretalx = {
    enable = true;
    plugins = with config.services.pretalx.package.plugins; [
      pages
      youtube
    ];
  };
}
