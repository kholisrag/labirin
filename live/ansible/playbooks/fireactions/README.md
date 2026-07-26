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

### 2. GitHub App on the `oprek-sh` organisation

Fireactions v2 registers runners at **organisation** level only — `organization`
is a required field in the pool config and there is no repository-scoped
alternative (see `RunnerConfig` in `server/config.go` upstream).

1. Go to <https://github.com/organizations/oprek-sh/settings/apps> →
   **New GitHub App**.
2. Name it e.g. `oprek-sh-fireactions`. Homepage URL can be anything.
3. Uncheck **Webhook → Active**. Fireactions has no webhook handler at all — it
   maintains a standing pool of idle runners rather than reacting to queued jobs.
4. Under **Organization permissions**, grant:
   - **Self-hosted runners**: Read and write
   - **Administration**: Read and write
5. Under **Where can this GitHub App be installed?** choose *Only on this account*.
6. Create the App, note the **App ID**, then **Generate a private key** and keep
   the downloaded `.pem`.
7. **Install App** → install it on the `oprek-sh` organisation.

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

Add the VM to `~/.ssh/config` alongside the other guests:

```sshconfig
Host petruk-pve0-fireactions-01
    hostname 10.10.99.11
    port 22
    user ansible
```

The DHCP reservation for MAC `BC:24:11:88:AB:20` still has to be added to
`dnsmasq_hosts` in `live/ansible/playbooks/opnsense/vars/vault.yaml` and applied
with `manage-dnsmasq-host-overrides.yaml`. (`BC:24:11:88:AB:21` → `10.10.99.12`
is reserved for `fireactions-02`.)

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

Three tiers are defined in `vars/main.yaml`. Pick one with `runs-on`:

| Tier | `runs-on` | vCPU | RAM | Replicas | Standing cost |
| --- | --- | --- | --- | --- | --- |
| small | `fireactions-small` | 2 | 4 GiB | 2 | 8 GiB |
| medium | `fireactions-medium` | 4 | 8 GiB | 1 | 8 GiB |
| large | `fireactions-large` | 8 | 12 GiB | 1 | 12 GiB |
| | | | | **per host** | **28 GiB** |

With two hosts deployed those replicas double: 4 small / 2 medium / 2 large
concurrent, 56 GiB of standing microVM RAM across the pair. The table is
per-host because `replicas` is per-host.

Each tier also carries an explicit spec label (`fireactions-2vcpu-4gb` etc.) if
you prefer to pin by shape rather than by name.

> [!IMPORTANT]
> `replicas` are **standing** microVMs, not on-demand capacity. Fireactions has
> no webhook handler and no `workflow_job` awareness — its only HTTP surface is
> `/metrics`. Each pool permanently holds `replicas` idle microVMs and replaces
> them as jobs consume them, so every replica reserves its full `mem_size_mib`
> 24/7 whether or not anything is building.

The VM is 8 vCPU / 32 GiB, leaving ~4 GiB for the host side (containerd, image
pulls, page cache). vCPU is oversubscribed 2:1 — fine for CI, where jobs are
rarely all CPU-saturated at once. **If you raise one tier, lower another.**

## Verifying

```bash
systemctl status fireactions
journalctl -u fireactions -f
fireactions pools ls
```

Runners should appear as **Idle** at
<https://github.com/organizations/oprek-sh/settings/actions/runners>. Then run a
job against the pool labels:

```yaml
jobs:
  test:
    runs-on: fireactions-2vcpu-4gb
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

## Upgrading

Bump `fireactions_version` in `vars/main.yaml` and re-run with `--tags
fireactions`. The config is validated with `fireactions validate` before it is
written, so a schema change in a new release fails the run instead of leaving a
broken service. See the
[upgrade guide](https://fireactions.io/latest/user-guide/upgrade-guide/).

## Troubleshooting

- `snapshotter not loaded: devmapper: invalid argument` — the thin pool name in
  `/etc/containerd/config.toml` must be `<volume group>-<thin pool>`, i.e.
  `containerd-thinpool`. The playbook asserts `ctr plugins ls` shows devmapper
  `ok`, so this should surface at install time.
- Runners never appear in GitHub — check the App is *installed* on the org, not
  just created, and that **Self-hosted runners** permission is read+write.
- Jobs queue forever — the workflow's `runs-on` labels must match the pool's
  `labels` exactly.
- The "Install the Fireactions configuration" task fails with no detail — that
  task is `no_log: true` because the repo sets `diff: always` in `ansible.cfg`
  and a diff would print the private key. Reproduce the error on the host
  instead: `fireactions validate /etc/fireactions/config.yaml`.

More: <https://fireactions.io/latest/help/troubleshooting/>
