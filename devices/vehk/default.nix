# vehk — Protectli VP2420 wireless monitoring / mesh-client travel router.
# The bulk of the configuration is shared with its siblings ayem/seht in
# ../../modules/vp2420; only host-specific bits live here.
{ ... }:

{
  imports = [
    ../../modules/vp2420
  ];

  networking.hostName = "vehk";
}
