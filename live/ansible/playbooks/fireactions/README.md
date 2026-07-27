# fireactions

[Fireactions](https://fireactions.io/latest/) runs ephemeral self-hosted GitHub
Actions runners inside [Firecracker](https://firecracker-microvm.github.io/)
microVMs. Every job gets a fresh microVM that is destroyed when the job ends, so
no state leaks between builds.

This playbook installs the whole stack on a Proxmox guest:

| Component | Role |
| --- | --- |
| Firecracker | VMM that boots each microVM |
| Containerd (devmapper) | Pulls runner images, hands each microVM a thin-provisioned root device |
| CNI (bridge + firewall + tc-redirect-tap) | Networking for the microVMs |
| Guest kernel | Minimal `vmlinux` every microVM boots |
| Fireactions | Orchestrator: registers runners with GitHub, scales pools |

> [!NOTE]
> This installs the [`kholisrag/fireactions`](https://github.com/kholisrag/fireactions)
> **fork**, not upstream — see [Why the fork](#why-the-fork).

## Layout

```text
live/ansible/playbooks/fireactions/
├── install-fireactions.yaml   # entrypoint
├── tasks/                     # one file per component
├── templates/                 # systemd units, containerd + CNI + fireactions config
└── vars/
    ├── main.yaml              # versions, pools, sizing
    └── vault.yaml             # GitHub App ID + private key (ansible-vault)
```

The VM itself is provisioned by OpenTofu at
`live/opentofu/proxmox/petruk-pve/petruk-pve0/vms/fireactions/`.

## Prerequisites

### 1. Nested virtualization on the Proxmox node

Firecracker needs `/dev/kvm` **inside** the guest. `petruk-pve0` already runs
with `kvm_intel.nested=Y`, so this is currently satisfied — but it was set at
runtime, not persisted. Run the playbook to make it survive a reboot:

```bash
# On the Proxmox node - persists kvm_intel/kvm_amd nested=1
ansible-playbook live/ansible/playbooks/pve/enable-nested-virtualization.yaml
```

...and `cpu type = "host"` on the VM, which the OpenTofu unit already sets. After
enabling nesting the guest needs a **cold stop/start** — a reboot from inside the
guest keeps the old CPU model.

Verify from inside the VM:

```bash
ls -la /dev/kvm
grep -cE '(vmx|svm)' /proc/cpuinfo   # must be > 0
```

### 2. GitHub App

One App (`<org>-fireactions`, owned by `<org>`) serves both scopes. It has
to be **installed separately on every account** whose runners you want — the App
existing is not enough, and a missing installation shows up as a `404` on
`GET /orgs/.../installation` rather than anything more helpful.

1. Go to <https://github.com/organizations/<org>/settings/apps> →
   **New GitHub App**.
2. Name it e.g. `<org>-fireactions`. Homepage URL can be anything.
3. Uncheck **Webhook → Active**. Fireactions has no webhook handler at all — it
   maintains a standing pool of idle runners rather than reacting to queued jobs.
4. Grant:
   - **Organization permissions → Self-hosted runners**: Read and write
   - **Repository permissions → Administration**: Read and write
     (this is what repository-scoped runners register through)
5. Under **Where can this GitHub App be installed?** choose *Any account*. Not
   strictly needed while every pool is org-scoped, but it is what lets you add a
   repository-scoped pool under a different account later without recreating the
   App.
6. Create the App, note the **App ID**, then **Generate a private key** and keep
   the downloaded `.pem`.
7. **Install App** on the `<org>` organisation — that is the only scope the
   pools register with today. A repository-scoped pool would additionally need
   the App installed on *that repository's owner*; installing on the org does
   nothing for another account.

Fireactions resolves the installation per pool at runtime
(`FindOrganizationInstallation` / `FindRepositoryInstallation`), so nothing has
to be pinned in the config.

### 3. Secrets

Both values live in `vars/vault.yaml`, encrypted with `ansible-vault` against the
repo-level `.vault_pass` (itself SOPS-encrypted as `.vault_pass.enc`):

```bash
# Materialise the vault password if you have not already
sops -d .vault_pass.enc > .vault_pass && chmod 600 .vault_pass

# Fill in the App ID and paste the PEM
ansible-vault edit live/ansible/playbooks/fireactions/vars/vault.yaml
```

The playbook refuses to run while the placeholders are still in place. The
rendered `/etc/fireactions/config.yaml` contains the private key in cleartext and
is written `0600 root:root` with `no_log: true` on the templating task.

### 4. Host resolution

Both hosts have static DHCP reservations and internal DNS records, applied from
`live/ansible/playbooks/opnsense/vars/vault.yaml`:

| Host | MAC | IP | DNS |
| --- | --- | --- | --- |
| fireactions-01 | `BC:24:11:88:AB:20` | `10.10.99.11` | `fireactions-01.<internal-domain>` |
| fireactions-02 | `BC:24:11:88:AB:21` | `10.10.99.12` | `fireactions-02.<internal-domain>` |

The reservations live in `dnsmasq_hosts` (applied with
`manage-dnsmasq-host-overrides.yaml`) and the A records in `unbound_hosts`
(applied with `manage-local-dns.yaml`). A new host needs an entry in both.

> [!NOTE]
> `opnsense_host` in that vault is `opnsense.<public-zone>`, which does not resolve
> from a workstation whose `/etc/resolver/` only covers `<internal-domain>` —
> every OPNsense playbook then fails with `nodename nor servname provided`. Run
> them with `-e opnsense_host=opnsense.<internal-domain>`; it is the same box and
> the Let's Encrypt wildcard covers it, so TLS still verifies.

Then add both to `~/.ssh/config`, which is what the inventory's `ansible_host`
values resolve through:

```sshconfig
Host petruk-pve0-fireactions-01
    hostname 10.10.99.11
    port 22
    user ansible
Host petruk-pve0-fireactions-02
    hostname 10.10.99.12
    port 22
    user ansible
```

A reservation only takes effect at the guest's next DHCP negotiation. To move a
guest that is still holding a pool lease, without rebooting it:

```bash
# Detached so the SSH connection dropping does not kill the restart
sudo systemd-run --on-active=3 --unit=dhcp-refresh --collect /bin/sh -c \
  'rm -f /run/systemd/netif/leases/*; systemctl restart systemd-networkd'
```

The microVMs are recreated when networkd restarts, so the runners re-register
under new names — harmless, but expect ~1 minute of churn.

## Usage

```bash
source .labirin_venv/bin/activate

# Everything
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/fireactions \
  live/ansible/playbooks/fireactions/install-fireactions.yaml

# A single component (tags: dependencies, firecracker, containerd, cni, kernel, fireactions)
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/fireactions \
  live/ansible/playbooks/fireactions/install-fireactions.yaml --tags containerd
```

> [!WARNING]
> The `containerd` tag wipes `fireactions_containerd_device` and converts it into
> an LVM thin pool. The pre-flight check refuses to touch a device with mounted
> filesystems, but it cannot tell "empty disk" from "disk you care about".

## Pools and sizing

Four tiers are defined in `vars/main.yaml`. Pick one with `runs-on`:

| Tier | `runs-on` | Registers with | vCPU | RAM ceiling | Replicas/host | Idle cost | Ceiling |
| --- | --- | --- | --- | --- | --- | --- | --- |
| small | `fireactions-small` | `<org>` org | 2 | 4 GiB | 5 | ~4.0 GiB | 20 GiB |
| medium | `fireactions-medium` | `<org>` org | 4 | 8 GiB | 1 | ~0.7 GiB | 8 GiB |
| large | `fireactions-large` | `<org>` org | 8 | 12 GiB | 1 | ~0.8 GiB | 12 GiB |
| | | | | | **7 per host** | **~5.5 GiB** | **40 GiB** |

`replicas` is per-host, so with two hosts deployed the concurrency doubles: **10
`small` runners org-wide**, plus 2 each of `medium` and `large`.

`small` is sized for the fan-out of a single `<repo>` PR — `security.yml`
spawns 7 jobs and `ci.yml` adds 2, all on `[self-hosted, fireactions-small]`. At
1 replica per host they queued **1–6 minutes each**, serialised behind two
runners.

Every tier is **organisation-scoped**, so only workflows in `<org>`
repositories can see these runners.

Each tier also carries an explicit spec label (`fireactions-2vcpu-4gb` etc.) if
you prefer to pin by shape rather than by name.

> [!NOTE]
> A repository-scoped tier (`fireactions-repo-small`, registered with
> `kholisrag/labirin`) was removed once that work moved into the `<org>` org.
> The fork still supports the scope — set `repository: <owner>/<repo>` on a pool
> *instead of* `organization` + `group_id`, and install the App on that repo's
> owner. `group_id` must be omitted there: user accounts have no runner groups,
> and the two scopes are mutually exclusive per pool. The scopes are never
> interchangeable — GitHub does not offer an org runner to a repo-scoped
> workflow, or the reverse, even with identical labels.

### There is no autoscaler

> [!IMPORTANT]
> `replicas` are **standing** microVMs, not on-demand capacity. Fireactions has
> no webhook handler and no `workflow_job` awareness — its only HTTP surface is
> `/metrics`. `Pool.Run()` simply holds the pool at `replicas` forever, replacing
> each microVM as a job consumes it. **The replica count *is* the concurrency
> limit**, so size it for the widest simultaneous fan-out you expect, not the
> average. Anything beyond it queues.

For a one-off burst there is a live lever that needs no restart and no playbook
run — but it is lost when the service restarts, so mirror any keeper back into
`vars/main.yaml`:

```bash
sudo fireactions pools scale fireactions-small --replicas 8
sudo fireactions pools ls          # CURRENT catches up to DESIRED in ~30-60s
```

### Why the budget overcommits

`mem_size_mib` is a **ceiling, not a reservation**. Firecracker backs guest RAM
with a lazily-populated anonymous mmap, so a microVM only holds what the guest
has actually touched. Measured on these hosts:

```console
$ ps -eo rss,args | grep [f]irecracker      # RSS in MiB
   778  ... fireactions-large    # 12 GiB configured, idle
   684  ... fireactions-medium   #  8 GiB configured, idle
  2898  ... fireactions-small    #  4 GiB configured, running a job
```

So the ceiling column in the table above overcommits ~1.5× against 32 GiB, and
that is fine here: the host has only 8 physical vCPU, so at most ~8 microVMs can
make progress at once; the workload is scanners and Go builds rather than memory
hogs; and the idle floor leaves ~25 GiB of real headroom. There is no swap and
`vm.overcommit_memory` is `0` (heuristic), so if the assumption ever breaks the
OOM killer takes a microVM, not the host. Check `free -m` after raising a tier.

`small` keeps its 4 GiB ceiling rather than being trimmed to buy more replicas —
a live job measured 2.9 GiB, so 3 GiB would start OOM-killing real work.

vCPU is oversubscribed ~3:1 against the VM's 8. Firecracker vCPU threads only
burn host CPU when the guest is actually running, so this costs latency under
full fan-out, not correctness.

Disk is not the constraint: the devmapper thin pool is 190 GiB and each microVM
writes ~600 MiB into it (`lvs containerd` showed 1.36% used across 4 microVMs).

## Verifying

```bash
systemctl status fireactions
journalctl -u fireactions -f
fireactions pools ls
```

All runners should appear as **Idle** at
<https://github.com/organizations/<org>/settings/actions/runners>.

Then run a job against the pool labels:

```yaml
jobs:
  test:
    runs-on: fireactions-small
    steps:
      - run: uname -a && docker --version
```

To get a shell in a live microVM (default password `fireactions`):

```bash
fireactions microvm login <vm-id>
```

## Scaling out across several VMs

A pool is **host-local**: each Fireactions host holds its own `replicas` count,
and there is no cross-host scheduler. To spread one logical pool over several
Proxmox VMs, run this same playbook on each of them with the *same pool name and
labels*. All the runners register under those labels and GitHub load-balances
jobs across them; runner names get a unique suffix per microVM, so there are no
collisions.

Total concurrency is the **sum** of `replicas` over every host — there is no
global cap, so raising host count raises the ceiling.

Two hosts (`fireactions-01`, `fireactions-02`) are currently deployed. Adding a
third is:

1. Add `"fireactions-03" = { vm_id = 111 }` to `local.hosts` in the OpenTofu
   unit, plus a MAC entry in `network.enc.yaml`. The Containerd disk serial is
   scoped per-VM, so it needs no change.
2. Add `fireactions_vm_03` to
   `inventories/.../pve-vms/fireactions/inventory.yaml`.
3. Add the DHCP reservation and SSH alias, then `terragrunt apply` and re-run
   the playbook — it targets the whole group.

`vars/main.yaml` does **not** change when host count changes. Identical pool
definitions on every host is exactly what makes them one logical pool, and
per-host concurrency simply adds up.

> [!CAUTION]
> **`petruk-pve0` is overcommitted on memory allocation.** Physical 251.5 GiB,
> allocated 274.0 GiB with the two hosts deployed. Only ~83 GiB is touched
> today — guest RAM faults in lazily — so nothing is failing, but there is no
> allocation headroom left.
>
> The swing factor is `cantrik-01/02/03`: 120 GiB allocated, ~9 GiB touched,
> `balloon=0` so none of it is reclaimable as Talos takes on workload. 1panel is
> not slack either — it holds all 64 GiB and genuinely uses ~49 GiB. If you need
> headroom back, shrink cantrik or give it a balloon.
>
> Note that **shrinking the pools does not relieve host memory pressure**.
> `floating = 0` means Proxmox commits the full 32 GiB per host regardless of
> how many microVMs run inside it. Only `vm_memory_mib` moves that number.

Note that two hosts on the **same** Proxmox node add no throughput — they
partition the same 80 threads. They buy blast-radius isolation (a wedged
devmapper pool takes out half your capacity, not all) and rolling upgrades.
Real scale-out needs a second node.

## Why the fork

`fireactions_release_repo` points at
[`kholisrag/fireactions`](https://github.com/kholisrag/fireactions), not
`hostinger/fireactions`. Two reasons:

1. **Repository-scoped runners.** Upstream's `RunnerConfig` has an
   `organization` field marked `validate:"required"` and no repository
   equivalent, so personal (user) accounts cannot use Fireactions at all — they
   can't own organisation runners or runner groups. The fork adds `repository`,
   makes the two scopes mutually exclusive, resolves the App installation per
   scope, and defaults `group_id` to `1` where groups don't exist.
2. **A validation bug.** Upstream tags `Pools` as `validate:"required,min=1"`
   with no `dive`, so go-playground applies those rules to the *slice* and never
   descends into the elements — meaning **no field inside any pool was ever
   validated**, upstream's own `required` fields included. `fireactions
   validate` would happily accept a pool with no image and no labels. The fork
   adds `dive`.

Release assets follow upstream's naming exactly, so reverting is just
`fireactions_release_repo` and `fireactions_version`. Downloads are pinned by
SHA-256 against the release's `checksums.txt` — GitHub release assets are
mutable, and this is a fork we control, so the pin is worth having.

Fork tags track upstream with a `-personal.N` suffix
(`v2.0.5` → `v2.0.5-personal.1`).

## Upgrading

Bump `fireactions_version` in `vars/main.yaml` and re-run with `--tags
fireactions`. The config is validated with `fireactions validate` before it is
written, so a schema change in a new release fails the run instead of leaving a
broken service. See the
[upgrade guide](https://fireactions.io/latest/user-guide/upgrade-guide/).

When upstream releases a new version, rebase the fork onto that tag, tag it
`vX.Y.Z-personal.1`, and let the fork's release workflow publish the assets —
then bump `fireactions_version` here.

## Guest kernel: why not Hostinger's

The upstream install docs tell you to download a prebuilt kernel from
`storage.googleapis.com/fireactions/kernels/...`. **That kernel does not work
here.** It is built without ACPI, and every virtio device is rejected at probe
time:

```text
virtio_blk: probe of virtio0 failed with error -22
```

leaving the guest with no root device, so it panics with `Cannot open root
device "vda"` and the runner never comes online. Reproduced identically on
Firecracker 1.9.1 and 1.16.1 and on both published Hostinger builds — it is the
kernel, not the VMM. There is also no `6.1` prebuilt despite the docs implying
one; the bucket only has `amd64/5.10`, `arm64/5.10` and a dated `amd64/5.10`.

This playbook uses the **official Firecracker CI kernel** instead
(`fireactions_kernel_url`), which is ACPI-capable — plus one required change:
`noapic` is removed from `fireactions_kernel_args`. With an ACPI kernel the
virtio-mmio devices are enumerated through ACPI, and `noapic` disables the
IOAPIC so they never get an IRQ (`virtio-mmio LNRO0005:01: IRQ index 0 not
found`). Both changes are needed; either alone still fails.

You will still see this in a healthy microVM — it is harmless. Firecracker
appends its own `virtio_mmio.device=` entries which collide with the regions
ACPI already claimed; the ACPI-discovered devices are the ones that work:

```text
virtio-mmio virtio-mmio.0: can't request region ... failed with error -16
```

A healthy boot shows `virtio_blk virtio0: [vda] ... 30.0 GiB` and reaches
`multi-user.target`.

## Troubleshooting

- `snapshotter not loaded: devmapper: invalid argument` — the thin pool name in
  `/etc/containerd/config.toml` must be `<volume group>-<thin pool>`, i.e.
  `containerd-thinpool`. The playbook asserts `ctr plugins ls` shows devmapper
  `ok`, so this should surface at install time.
- Runners never appear in GitHub — check the App is *installed* on that pool's
  scope, not just created. Each account needs its own installation. Org pools
  need **Self-hosted runners** read+write, repository pools need
  **Administration** read+write.
- `github: finding installation for <owner>: 404` — the App is not installed on
  that account, or the installation excludes that repository.
- Jobs queue forever — the workflow's `runs-on` labels must match the pool's
  `labels` exactly, and the pool must be registered with *that* repository's
  scope. An org runner is never offered to a personal repo's workflow.
- The "Install the Fireactions configuration" task fails with no detail — that
  task is `no_log: true` because the repo sets `diff: always` in `ansible.cfg`
  and a diff would print the private key. Reproduce the error on the host
  instead: `fireactions validate /etc/fireactions/config.yaml`.

More: <https://fireactions.io/latest/help/troubleshooting/>
