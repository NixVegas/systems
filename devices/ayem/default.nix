# ayem — Protectli VP2420, sibling of seht/vehk. Same hardware and role;
# the shared configuration lives in ../../modules/vp2420.
{ ... }:

{
  imports = [
    ../../modules/vp2420
    ../../modules/ctf-recon-wifi.nix
  ];

  networking.hostName = "ayem";

  # RF scavenger-hunt find (Recon8 "Free WiFi"): an open SSID on the spare
  # mt76x0u (wlp0s20f0u8) that beacons the flag over broadcast UDP. The flag is
  # provisioned out-of-band at /etc/nixctf/flag-recon-wifi (not committed).
  nixVegas.ctfReconWifi.enable = true;
}
