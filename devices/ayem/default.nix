# ayem — Protectli VP2420, sibling of seht/vehk. Same hardware and role;
# the shared configuration lives in ../../modules/vp2420.
{ ... }:

{
  imports = [
    ../../modules/vp2420
  ];

  networking.hostName = "ayem";
}
