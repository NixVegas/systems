# Single source of truth for every event router's attendee ("arena") LAN.
#
# Each entry is a /24: `base` is the first three octets (router at <base>.1,
# DHCP <base>.128–.254) and `id` is that host's *local* kea subnet id. Nebula
# addresses are NOT here — they come from mesh.nix (the mesh plan). Because the
# ranges are distinct and non-overlapping, the routers can route between them
# over Nebula (see the arena* helpers in ./lib.nix); add a router by adding a
# line here plus its mesh.nix nebula entry.
{
  ghostgate = {
    id = 4;
    base = "10.7.0";
  };
  ayem = {
    id = 1;
    base = "10.8.1";
  };
  seht = {
    id = 1;
    base = "10.8.2";
  };
  vehk = {
    id = 1;
    base = "10.8.3";
  };
}
