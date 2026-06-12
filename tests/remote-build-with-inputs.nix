# Probe derivation WITH a real input closure, for the same ssh-ng:// builders
# as remote-build.nix.
#
# Every other probe in this pipeline is deliberately input-free: its builder
# is the static /bin/sh the sandbox itself provides, so only the .drv crosses
# the wire. That cannot detect a builder that sets up the sandbox without the
# derivation's input closure — the failure mode that breaks every real-world
# build ("error: executing '/nix/store/...-bash/bin/bash': No such file or
# directory" on comin system rebuilds), because real derivations always have
# store-path builders and inputs.
#
# This probe has the smallest possible real closure, two paths:
#   - its build script is the *output of another derivation* (executed as
#     `/bin/sh <store-path>`, since the applet-less sandbox ash has no chmod
#     to make anything executable), and
#   - a `builtins.toFile` source the script reads back, proving the path was
#     uploaded from the client store and bind-mounted into the sandbox.
# The script itself sticks to shell builtins (read/echo/redirects) for the
# same no-applets reason.
#
# Log interface, mirroring remote-build.nix: BUILDTOKEN:<uptime> identifies
# the execution, MARKER:<tag> proves log fan-out, and INPUT:<tag> proves the
# toFile input was present inside the sandbox.
{
  prefix ? "remote-input-test",
  tag ? "${prefix}-${toString builtins.currentTime}",
}:
let
  src = builtins.toFile "${tag}-src" "${tag}\n";

  buildScript = derivation {
    name = "${tag}-build-script";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [
      "-e"
      "-c"
      ''
        {
          echo 'read start _rest < /proc/uptime'
          echo 'echo "BUILDTOKEN:$start"'
          echo 'echo "MARKER:$marker"'
          echo 'while read line; do echo "INPUT:$line"; done < "$src"'
          echo 'echo "DONE:$marker"'
          echo 'echo "$start $marker" > "$out"'
        } > "$out"
      ''
    ];
  };
in
derivation {
  name = tag;
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [
    "-e"
    buildScript
  ];
  marker = tag;
  inherit src;
}
