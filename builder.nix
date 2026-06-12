{
  config,
  pkgs,
  lib,
  self,
  nix-fork,
  modulesPath,
  ...
}:
let
  # Canonical GitHub repo this fleet pulls from. comin (on each builder) polls
  # this over HTTPS; the web session only has to `git push` to the deploy branch.
  repo = "Takishima/nix-builder-infra";
  deployBranch = "main";

  # The deployed git revision, surfaced so the reporter below can post a commit
  # status the web sandbox can read back via the GitHub MCP (it cannot SSH in).
  rev = if self ? rev then self.rev else (self.dirtyRev or "unknown");
in
{
  # Hetzner Cloud VMs are QEMU guests with virtio-SCSI disks; without these
  # initrd modules the installed system hangs in stage 1, unable to find its
  # root disk (the installer kernel has them, so nixos-anywhere still succeeds).
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  # --- Boot / disk --------------------------------------------------------
  # Filesystems AND the GRUB device come from disko.nix (the EF02 partition sets
  # boot.loader.grub.devices). Hetzner Cloud boots legacy BIOS.
  boot.loader.grub.enable = true;

  # --- Networking ---------------------------------------------------------
  # Hetzner Cloud hands out IPv4 over DHCP; that is enough for the load-test
  # client to reach the builder over ssh-ng://. (IPv6 is static per-server and
  # can be added via cloud-init if needed.)
  networking.useDHCP = lib.mkDefault true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # --- Remote-builder role ------------------------------------------------
  # The daemon under test: the pinned Nix fork. ssh-ng:// clients that connect
  # as nixremote run `nix-daemon --stdio` from this package, so this is the
  # remote endpoint of the builder protocol. Bump via `nix flake update
  # nix-fork` + the build-fork-nix workflow (populates Cachix) + push.
  nix.package = nix-fork.packages.${pkgs.system}.nix-cli;

  # Mirrors the proven topology in tests/nixos/remote-builds-ssh-ng.nix: a
  # trusted SSH build user, sandboxed builds, and the system-features the Nix
  # scheduler matches against requiredSystemFeatures.
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
      # The fork's per-store build coordinator: concurrent BuildDerivation
      # requests for the same resolved drv coalesce into one build with log
      # fan-out/replay. The builder-protocol-tests workflow's dedup stage
      # exercises (and requires) this.
      "build-coordinator"
    ];
    trusted-users = [
      "root"
      "nixremote"
    ];
    max-jobs = "auto";
    cores = 0;
    sandbox = true;
    system-features = [
      "big-parallel"
      "kvm"
      "nixos-test"
      "benchmark"
    ];
    # Let builders fetch their own substitutes instead of receiving every input
    # over the protocol from the client.
    builders-use-substitutes = true;
    # The fork's prebuilt closures land here via the build-fork-nix workflow;
    # comin substitutes them instead of compiling nix on the builder.
    extra-substituters = [ "https://damien.cachix.org" ];
    extra-trusted-public-keys = [ "damien.cachix.org-1:5ddkbRsrODT9rsBQ43qNLvlxpEEiye1aHsIxxu+SPxw=" ];
  };

  users.groups.nixremote = { };
  users.users.nixremote = {
    isNormalUser = true;
    group = "nixremote";
    description = "Nix remote-build SSH user";
    # Populate keys/ci-builder.pub with the load-test client's public key.
    openssh.authorizedKeys.keyFiles = [ ./keys/ci-builder.pub ];
  };

  # Operations access for the bootstrap/CI key: the bootstrap-builder and
  # builder-check workflows SSH in as root with this key. Without it the
  # installed system accepts no logins at all (the installer environment only
  # had the key injected by Hetzner/nixos-anywhere for the install itself).
  users.users.root.openssh.authorizedKeys.keyFiles = [ ./keys/ops.pub ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # --- GitOps deploy (pull model) ----------------------------------------
  # Each builder polls the repo and rebuilds itself to
  # nixosConfigurations.<networking.hostName>. No SSH, no inbound deploy path.
  services.comin = {
    enable = true;
    remotes = [
      {
        name = "origin";
        url = "https://github.com/${repo}.git";
        branches.main.name = deployBranch;
        # If Takishima/nix is private, drop a fine-grained read-only token here
        # (delivered out-of-band, e.g. via cloud-init user-data):
        # auth.access_token_path = "/run/keys/comin-github-token";
      }
    ];
  };

  # Record which commit this build came from, so the reporter (and `nixos-version
  # --configuration-revision`) can identify the deployed revision.
  system.configurationRevision = rev;

  # --- Pre-switch acceptance check ----------------------------------------
  # Abort the switch unless the INCOMING system's Nix can actually build a
  # derivation with a real input closure. This is the regression the fork has
  # shipped twice (sandbox set up without the drv's inputs: "executing
  # '...-bash/bin/bash': No such file or directory"), and input-free probes
  # cannot see it. The build runs in a throwaway store, so it exercises the
  # chroot sandbox and the per-store build coordinator without touching
  # /nix/store's coordinator or locks — a failure leaves the running system
  # untouched and comin simply stays on the current generation.
  system.preSwitchChecks.fork-daemon-smoke-build = ''
    incoming="$1"
    nix="$incoming/sw/bin/nix"
    if [ ! -x "$nix" ]; then
      echo "pre-switch smoke: no nix binary at $nix; failing closed" >&2
      exit 1
    fi
    # Not under /tmp: nix refuses a store rooted in a world-writable
    # directory ("Path '/tmp' is world-writable or a symlink").
    scratch=$(${pkgs.coreutils}/bin/mktemp -d /root/pre-switch-smoke.XXXXXXXX)
    trap '${pkgs.coreutils}/bin/rm -rf "$scratch"' EXIT
    echo "pre-switch smoke: building an input-bearing derivation with $("$nix" --version)"
    # Deliberately WITHOUT the build-coordinator feature: a coordinator
    # spawned for the scratch store outlives the check and poisons later
    # daemon builds ("Nix daemon disconnected unexpectedly" hangs, observed
    # on the first deploy of this check). The chroot/input-closure path —
    # the regression this check exists for — is exercised either way; the
    # coordinator behaviour is covered remotely by builder-protocol-tests.
    "$nix" build --no-link \
      --extra-experimental-features 'nix-command' \
      --store "$scratch" \
      --option substituters "" \
      -f ${./tests/remote-build-with-inputs.nix} \
      --argstr prefix pre-switch-smoke \
      || { echo "pre-switch smoke: the incoming Nix cannot build a drv with inputs; refusing to switch" >&2; exit 1; }
    echo "pre-switch smoke: OK"
  '';

  # --- Observability: report convergence back to GitHub -------------------
  # The web sandbox cannot SSH in to check a deploy, so each builder POSTs a
  # commit status for the deployed SHA. Claude then reads it via the GitHub MCP
  # (mcp__github__get_commit). Best-effort: it no-ops unless a status token is
  # present at /run/keys/github-status-token (state:write scope on the repo).
  systemd.services.report-deploy-status = {
    description = "Report active NixOS configurationRevision to the GitHub commit status API";
    after = [
      "network-online.target"
      "comin.service"
    ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.curl
      pkgs.coreutils
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      token_file=/run/keys/github-status-token
      if [ ! -r "$token_file" ]; then echo "no status token; skipping report"; exit 0; fi
      rev="${rev}"
      if [ "$rev" = "unknown" ]; then echo "no revision to report; skipping"; exit 0; fi
      curl --fail --silent --show-error \
        -X POST \
        -H "Authorization: Bearer $(cat "$token_file")" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}/statuses/$rev" \
        -d '{"state":"success","context":"comin/${config.networking.hostName}","description":"deployed on ${config.networking.hostName}"}'
    '';
  };

  # Fire the reporter whenever the active system generation changes.
  systemd.paths.report-deploy-status = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathChanged = "/run/current-system";
  };

  # --- Workaround: clear stale coordinator lock after each deploy ---------
  # Fork bug (see bug-report-coordinator-scratch-store-wedge.md): when the
  # per-store build coordinator exits it leaves /nix/var/nix/
  # coordinator.socket.lock behind (root, 0600), and every later
  # *unprivileged* daemon relay blocks on it indefinitely — each comin deploy
  # therefore wedges the builder's ssh-ng path. Until the fork cleans up (or
  # opens up) its lock, remove it after every generation switch, but only
  # when no live coordinator still holds the flock.
  systemd.services.coordinator-lock-cleanup = {
    description = "Remove a stale Nix build-coordinator lock left by the previous deploy";
    path = [
      pkgs.util-linux
      pkgs.coreutils
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      lock=/nix/var/nix/coordinator.socket.lock
      [ -e "$lock" ] || exit 0
      if flock -n "$lock" true 2>/dev/null; then
        rm -f "$lock" /nix/var/nix/coordinator.socket
        echo "removed stale coordinator lock"
      else
        echo "coordinator lock is held by a live coordinator; leaving it"
      fi
    '';
  };
  systemd.paths.coordinator-lock-cleanup = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathChanged = "/run/current-system";
  };

  # --- Misc ---------------------------------------------------------------
  time.timeZone = "UTC";
  environment.systemPackages = [ pkgs.git ];
  system.stateVersion = "25.11";
}
