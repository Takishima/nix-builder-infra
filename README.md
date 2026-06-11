# nix-builder-infra

A fleet of NixOS remote builders on Hetzner Cloud, used to load-test the Nix
`ssh-ng://` daemon worker protocol (developed in
[Takishima/nix](https://github.com/Takishima/nix)) with real builds.

This lives in its own repository (rather than inside the nix fork) so that
GitHub Actions `workflow_dispatch` works out of the box and fleet config stays
independent of the upstream source tree.

## Why it's built this way

Claude Code web sessions run in a sandbox whose only egress is Anthropic's
HTTP/HTTPS proxy — **there is no outbound SSH (port 22)**. So the usual
SSH-based deploy tools (`nixos-anywhere`, `nixos-rebuild --target-host`,
`colmena`, `deploy-rs`) can't run from a web session.

Instead this uses a **GitOps pull model**: each builder runs
[`comin`](https://github.com/nlewo/comin), which polls this repo over HTTPS and
rebuilds itself to `nixosConfigurations.<hostname>` on every push to `main`.
A web session deploys by editing files and pushing.

```
web session  --git push-->  this repo  <--HTTPS poll--  comin on each builder --> nixos-rebuild switch
web session  --workflow_dispatch--> GH-hosted runner --SSH--> builder   (bootstrap & health checks only)
```

## Layout

| File            | Purpose                                                              |
| --------------- | -------------------------------------------------------------------- |
| `flake.nix`     | `nixosConfigurations.<host>` for each builder; inputs (nixpkgs/comin/disko) |
| `builder.nix`   | The deployable config: nix-daemon builder role, `comin`, SSH, status reporter |
| `disko.nix`     | Deterministic disk layout (BIOS/GRUB, ext4 root), applied by nixos-anywhere |
| `keys/ci-builder.pub` | Authorized key for the `nixremote` ssh-ng:// build user (populate this) |
| `provision.sh`  | Sandbox-runnable server creation via the Hetzner HTTPS API (no SSH)  |
| `.github/workflows/bootstrap-builder.yml` | One-shot nixos-anywhere install of a fresh server |
| `.github/workflows/builder-check.yml`     | On-demand SSH health probe, readable from web sessions |

## One-time setup

1. **Hetzner**: a read/write API token and an SSH key in the project whose
   private half is the `BUILDER_SSH_PRIVATE_KEY` Actions secret here.
2. **Web environment** (claude.ai/code environment dialog): Custom network
   access including `api.hetzner.cloud`; `HCLOUD_TOKEN` env var; setup script
   from `web-setup.sh`.
3. **Secrets on builders** (optional, delivered out-of-band): a `state:write`
   GitHub token at `/run/keys/github-status-token` to report deploy convergence
   as commit statuses.

## Bootstrap a builder

```bash
# 1. Create the server (runs in a web session; HTTPS only):
HETZNER_SSH_KEY=hetzner-bootstrap COUNT=1 SERVER_TYPE=cx33 NO_INFECT=1 ./provision.sh
# 2. Dispatch the bootstrap-builder workflow with host=nix-builder-NN and the
#    server's IP. A GitHub-hosted runner kexecs the server and installs the
#    flake config, disko layout included.
# 3. The final workflow step verifies the host rebooted into NixOS with comin
#    active. Later health checks: dispatch builder-check with the IP.
```

Do **not** switch a `nixos-infect`ed machine onto this flake: the disko layout
here describes what nixos-anywhere creates, not an infected image's partitions.

## Everyday config deploys

1. Edit `builder.nix` (or hostnames in `flake.nix`).
2. Validate: `nix flake check` /
   `nix eval .#nixosConfigurations.nix-builder-01.config.system.build.toplevel.drvPath`
3. Push to `main`. comin converges each builder within ~60s.
4. Observe via the `builder-check` workflow, or commit statuses if the status
   token is installed on the builders.
