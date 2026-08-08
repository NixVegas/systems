{
  lib,
  ...
}:

{
  boot.extraModprobeConfig = lib.mkAfter ''
    options mt76-usb disable_usb_sg=1
  '';
}
