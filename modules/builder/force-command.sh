#!/usr/bin/env bash

# We don't really care about what flags are passed with the nix-daemon or nix-store commands
# We only care about the command itself
IFS=" " read -r -a COMMAND_ARRAY <<<"${SSH_ORIGINAL_COMMAND:=''}"
COMMAND="${COMMAND_ARRAY[0]:=''}"

case "${COMMAND}" in
# To support the ssh-ng:// protocol
'nix-daemon')
  exec nix-daemon --stdio
  ;;
# To support the legacy ssh:// protocol
'nix-store')
  exec nix-store --serve --write
  ;;
# Don't allow anything else to be executed except for the above 2 commands
*)
  echo "Hi! You've successfully authenticated!"
  echo "However, we do not provide shell access :( Sorry!"
  exit 1
  ;;
esac
