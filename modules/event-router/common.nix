# Shared low-level defaults for the Protectli event routers (ghostgate and the
# VP2420s). Only settings that are identical across every router live here;
# host-specific boot/console/hardware bits stay in each host's config.
{ pkgs, ... }:
{
  # These boxes run the xanmod kernel and route between their interfaces.
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_xanmod;
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = true;
  };

  hardware.enableRedistributableFirmware = true;

  services.acpid.enable = true;

  # Kea binds a raw socket to the LAN bridge. It's already `partOf` hostapd
  # (so it restarts with it), but without an ordering it can start *before*
  # hostapd finishes bringing the bridge up, bind to a not-ready interface, and
  # then sit there not serving DHCP until manually restarted. Order it after
  # hostapd so the socket lands on a ready bridge.
  systemd.services.kea-dhcp4-server.after = [ "hostapd.service" ];

  # nginx tuning shared by every router's cache/DNS front-end. (Each host still
  # enables nginx and defines its own upstreams/virtualHosts.)
  services.nginx = {
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;
    recommendedBrotliSettings = true;
    recommendedProxySettings = true;
    recommendedUwsgiSettings = true;
    recommendedOptimisation = true;
  };
}
