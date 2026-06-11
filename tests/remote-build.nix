# Zero-dependency probe derivation for exercising a builder over ssh-ng://.
#
# - No inputs at all: `builder = "/bin/sh"` is the static busybox ash that the
#   builders' `sandbox = true` provides inside every build, so the client only
#   uploads the .drv itself — the protocol path under test — never a stdenv
#   closure.
# - Freshness: `tag` defaults to `builtins.currentTime`, so each evaluation
#   yields a brand-new derivation that can be neither substituted nor already
#   valid on the builder. Pass `prefix` to keep jobs that evaluate within the
#   same epoch second (e.g. two matrix legs) from colliding on one drv; pass
#   `tag` outright when two clients must agree on the *same* drv (dedup stage).
# - `holdSeconds` keeps the build in-flight so a second client has time to
#   attach (the sandbox shell is applet-less ash with no `sleep`, hence the
#   busy-wait on /proc/uptime, which the sandbox mounts).
#
# The streamed log is the test interface:
#   BUILDTOKEN:<uptime-at-start> identifies the build *execution* — the
#     builder-side monotonic clock has 10ms resolution, so two distinct runs of
#     the same drv (necessarily serialized by the builder's path locks) can
#     never emit the same token, while one shared (deduped) build shows the
#     same token to every attached client.
#   MARKER:<tag> proves the log line crossed the wire to a given client
#     (fan-out for the build owner, buffered replay for a late joiner).
{
  prefix ? "remote-test",
  tag ? "${prefix}-${toString builtins.currentTime}",
  holdSeconds ? 0,
}:
derivation {
  name = tag;
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [
    "-e"
    "-c"
    ''
      read start _rest < /proc/uptime
      echo "BUILDTOKEN:$start"
      echo "MARKER:${tag}"
      start_s=''${start%.*}
      now_s=$start_s
      while [ $((now_s - start_s)) -lt ${toString holdSeconds} ]; do
        read now _rest < /proc/uptime
        now_s=''${now%.*}
      done
      echo "DONE:${tag}"
      echo "$start ${tag}" > "$out"
    ''
  ];
}
