# ansible

This directory contains the ansible playbooks that I used for my experimental environment.

## Bootstrap — four things no playbook creates

Every playbook here assumes all four already exist, and each fails in a way that
does not name itself. A July 2026 drift scan found them assumed by five playbook
READMEs and created by nothing, so they are written down here rather than
rediscovered.

Order matters: each one fails before the next is reached.

### 1. Split DNS for `<internal-domain>`

Nothing in this repo resolves without it. Every playbook targets a
`*.<internal-domain>` name served by Unbound on OPNsense, which is not a public
zone.

```bash
# macOS
sudo mkdir -p /etc/resolver
printf 'nameserver 192.168.3.102\n' | sudo tee /etc/resolver/<internal-domain>
```

On systemd-resolved the equivalent is a per-link domain routing rule
(`resolvectl domain <link> '~<internal-domain>'` plus
`resolvectl dns <link> 192.168.3.102`), not an `/etc/resolv.conf` edit — a
global nameserver there would send every lookup to the homelab.

Without it the failure is `Could not resolve host` from `curl`, or
`nodename nor servname provided` from Ansible's `uri` module. Neither points at
DNS scope.

> [!IMPORTANT]
> **This resolver covers `<internal-domain>` and nothing else.** `<public-zone>` names
> still resolve publicly, and the two differ. The OPNsense vault sets
> `opnsense_host` to `opnsense.<public-zone>`, which therefore does **not** resolve
> from a workstation configured this way — so every OPNsense playbook is run
> with an override:
>
> ```bash
> ansible-playbook live/ansible/playbooks/opnsense/manage-local-dns.yaml \
>   -e opnsense_host=opnsense.<internal-domain>
> ```
>
> Same box, and the wildcard covers both names, so TLS still verifies.

**macOS caches negative answers.** A name that did not resolve a minute ago can
keep returning `NXDOMAIN` from `dscacheutil` after the record exists. `dig` talks
to the resolver directly and bypasses both the cache and `/etc/resolver`, so the
two disagree and neither is wrong:

```bash
dig +short @192.168.3.102 <name>.<internal-domain>   # the truth
sudo dscacheutil -flushcache                        # then the OS agrees
```

### 2. The virtualenv, at `.labirin_venv`

Not optional, and not swappable for a system Ansible: the playbooks hardcode

```yaml
ansible_python_interpreter: "{{ playbook_dir | regex_replace('(.*labirin).*', '\\1') }}/.labirin_venv/bin/python3"
```

so a playbook launched from any other interpreter still executes its modules
under this path, and fails if it is absent.

```bash
python3 -m venv .labirin_venv
.labirin_venv/bin/pip install --upgrade pip
.labirin_venv/bin/pip install -r requirements.txt ansible-core
```

> [!NOTE]
> **`ansible-core` is on that command line rather than in `requirements.txt`,
> and that is an accident rather than a decision.** The file pins the module
> dependencies — `proxmoxer`, `paramiko`, `httpx` and the rest — to exact
> versions, and does not pin Ansible itself. So the file that exists to make
> this reproducible omits the component whose version changes behaviour most.
> Rebuilding the venv gets whatever pip resolves that day; the version in use
> as of July 2026 is **ansible-core 2.21.2**.
>
> Worth fixing with a pin, which is a decision about upgrade cadence rather
> than a typo — hence recorded here instead of quietly changed.

`Taskfile.yaml` at the repo root is currently **empty**, so no `task` target
does any of this.

### 3. The vault password, at `.vault_pass`

`ansible.cfg` sets `vault_password_file = ./.vault_pass`, and that file is not
in the repo — it is decrypted from `.vault_pass.enc` with sops:

```bash
sops -d .vault_pass.enc > .vault_pass && chmod 600 .vault_pass
```

This needs the age key `.sops.yaml` names, found via `SOPS_AGE_KEY_FILE`.

Without it every playbook that reads a vault dies at parse time with
`The vault password file ... was not found`, before any task runs — including
the `--syntax-check` you would reach for to diagnose it.

**Expect to re-run this.** The file is transient and disappears between
sessions; regenerating it is part of starting work, not a sign something broke.

### 4. Galaxy roles and collections

```bash
.labirin_venv/bin/ansible-galaxy install -r requirements.yml
.labirin_venv/bin/ansible-galaxy collection install -r requirements.yml
```

These install to `~/.ansible`, outside the venv, so they survive rebuilding it —
and conversely, another Ansible elsewhere on the machine can shadow them.
`ansible-galaxy` warns when it finds two copies of a collection and says which
one wins.

## Running a playbook

Most run against `localhost` and talk to an API over HTTPS, so they need neither
an inventory nor SSH. The exceptions:

| Playbook | Why it needs `-i` |
| --- | --- |
| `1panel/manage-websites.yaml` | inventory availability |
| `1panel/manage-databases.yaml` | its second play runs on the guest over SSH, to issue a `GRANT` the panel API cannot |
| `1panel/manage-waf-overrides.yaml` | 1pwaf rules are files on disk, not an API surface |

```bash
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/1panel \
  live/ansible/playbooks/1panel/manage-websites.yaml
```

## What is managed here, and what is not

Declared in this tree and reconciled by a playbook: OPNsense Unbound host
overrides and aliases; 1Panel reverse-proxy websites, PostgreSQL databases and
WAF rule overrides; the `athens` and `gha-cache` compose stacks; fireactions
pools and their runner image pin; Harbor, RustFS, Talos, PVE, cloudflared and
cantrik-ci.

Deliberately **not** managed, recorded so a drift scan does not re-raise them:

- **1Panel app-store installs** (`createdBy: Apps` — gitea, n8n, ntfy, ollama,
  pgadmin4, postgresql, redis and the rest). A different management surface;
  their websites are `type: deployment` and are not expressible as a few fields.
- **RustFS buckets.** No Ansible module speaks SigV4 without pulling in
  `amazon.aws` and boto3, and a bucket is not worth a hand-rolled signing
  implementation — see [rustfs](playbooks/rustfs/README.md).
- **This bootstrap section.** Chicken-and-egg: a playbook that configures the
  workstation cannot run before the workstation can run playbooks.
