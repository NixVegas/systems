# Let pcscd use YubiKeys. Import on any host that signs with a YubiKey-resident
# key through pcscd (nixpkcs `security.pkcs11.pcsc`, the `openssl-with-pkcs11`
# wrapper, ykman PIV ops).
#
# pcscd drops to the dedicated `pcscd` user the NixOS module creates, so it
# needs the YubiKey's raw USB node to be group-accessible. The ccid package's
# 92_pcscd_ccid.rules is what normally does that, but it grants GROUP="pcscd"
# only to an explicit VID/PID allowlist that contains no Yubico (1050) entries,
# so the node stays root:root and pcscd logs
#   ccid_usb.c OpenUSBByName() Can't libusb_open(..): LIBUSB_ERROR_ACCESS
# The token is then visible but unusable: ykcs11 reports
# "SCardListReaders failed, rc=8010002e" (no readers), the pkcs11 provider
# says "Module initialization failed", and openssl falls back to
# "Could not open file or uri for loading CA private key from pkcs11:...".
# A manual chown of /dev/bus/usb/<bus>/<dev> fixes it until the next replug or
# reboot; this rule makes it permanent. uaccess keeps the active console
# user's ACL on the node so ykman and friends still work for them.
{ ... }:
{
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="1050", GROUP="pcscd", MODE="0660", TAG+="uaccess"
  '';
}
