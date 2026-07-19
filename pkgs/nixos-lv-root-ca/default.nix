{
  runCommand,
}:

runCommand "nixos-lv-root-ca.crt" { ca = ./ca.crt; } ''
  cp $ca $out
''
