# Big socket buffers for every nebula host in the mesh plan.
#
# Nebula moves the whole overlay through ONE UDP socket, drained by a single
# reader goroutine (listen.routines=1 default), at kernel-default buffer sizes
# (~208KB each way ~= 150 full datagrams). Measured on ghostgate post-DC34:
# `ss -uampi` showed the socket at rb/tb 212992 with d=114644 -- 114k inbound
# datagrams dropped at the socket -- while relay/handshake churn plus tunnel
# traffic bursts overflowed the receive side, felt as multi-second stalls with
# sequence gaps on everything crossing the overlay. The send side has the
# mirror-image failure: skbs queued in a congested qdisc (e.g. mesh2's cake
# holding toward a deaf 802.11s peer) stay charged to the socket, and once
# they exceed SO_SNDBUF every send blocks -- one dead underlay head-of-line
# blocks all tunnels.
#
# 64MiB each way makes both failure modes arithmetically unreachable: no qdisc
# here holds close to 64MiB, and the reader gets ~50k datagrams of burst
# headroom. brass benefits most -- as the fleet's sole lighthouse+relay its
# socket carries the aggregate of everyone's relayed traffic.
#
# The sysctls are required: SetReadBuffer/SetWriteBuffer are silently capped
# at rmem_max/wmem_max. Buffers apply at socket creation, so nebula must
# restart (deploys do) -- SIGHUP is not enough. Verify on a host:
#   ss -uampi | grep -A1 <nebula port>   ->  rb/tb ~134217728 (kernel doubles),
#   and the d= drop counter stops climbing.
{ config, lib, ... }:
let
  me = config.networking.mesh.plan.hosts.${config.networking.hostName} or { };
in
{
  config = lib.mkIf (me ? nebula) {
    services.nebula.networks.arena.settings.listen = {
      read_buffer = 67108864;
      write_buffer = 67108864;
    };
    boot.kernel.sysctl = {
      "net.core.rmem_max" = 67108864;
      "net.core.wmem_max" = 67108864;
    };
  };
}
