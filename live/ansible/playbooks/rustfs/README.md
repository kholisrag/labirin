# rustfs

[RustFS](https://docs.rustfs.com/) is an S3-compatible object store — a single
static Rust binary in front of one XFS volume. This deployment is **SNSD**
(Single Node, Single Disk): one volume, therefore **no erasure coding**. Losing
the data device loses the data; the durability story is the array under the
`sas` datastore plus the PVE backup on that disk.

| Piece | Role |
| --- | --- |
| `/usr/local/bin/rustfs` | the whole server — no database, no sidecars |
| `/etc/default/rustfs` | every setting, read from the environment at start |
| `/etc/systemd/system/rustfs.service` | `Type=notify`, restart-always |
| `/data/rustfs0` on a dedicated XFS disk | the object store |
| Two 1Panel websites | TLS termination for the API and the console |

## Layout

```text
live/ansible/playbooks/rustfs/
├── install-rustfs.yaml    # entrypoint
├── tasks/                 # one file per component
├── templates/
│   ├── rustfs.env.j2      # /etc/default/rustfs
│   └── rustfs.service.j2  # the systemd unit
└── vars/
    ├── main.yaml          # version, listeners, volume, sizing
    └── vault.yaml         # root access key + secret (ansible-vault)
```

The VM itself is provisioned by OpenTofu at
`live/opentofu/proxmox/petruk-pve/petruk-pve0/vms/rustfs/`.

> [!WARNING]
> RustFS is **pre-1.0** — every published release so far is tagged a
> prerelease, the on-disk format is not promised stable across them, and there
> is no documented in-place downgrade. Treat a bump of `rustfs_version` as a
> change that wants a backup of `/data` taken first.

## Where the traffic actually goes

```text
  aws-cli / SDK / browser
        |  https://<s3-host>           (S3 API)
        |  https://<console-host>   (console)
        v
  1Panel VM (10.10.99.10) - OpenResty
        |  TLS terminated with the *.<internal-domain> wildcard
        |  http://10.10.99.14:9000   /   http://10.10.99.14:9001
        v
  rustfs-01 (10.10.99.14) - RustFS, plain HTTP
        v
  /data/rustfs0  (XFS on scsi1, 200 GiB, `sas` datastore)
```

Three names, and mixing them up is the most likely thing to go wrong:

| Name | Resolves to | For |
| --- | --- | --- |
| `<s3-host>` | Unbound **alias** → `<panel-host>` | Every S3 client. This is the endpoint URL. |
| `<console-host>` | Unbound **alias** → `<panel-host>` | The web console, in a browser. |
| `<rustfs-guest>` | **A record** → `10.10.99.14` | SSH, Ansible, and the 1Panel upstream. Not an S3 endpoint. |

> [!NOTE]
> The console lives at **`/rustfs/console/`**, not at the root. The root of the
> `:9001` listener is the same S3-style handler as `:9000` and answers an
> unauthenticated request with `<Error><Code>AccessDenied</Code></Error>` — which
> reads like a broken reverse proxy and is not. The console site's proxy block
> carries a `location = /` that 302s to the real path, so the bare hostname
> works in a browser.

### Why the API and the console are separate hostnames

Not style — a hard constraint. S3 clients sign the **request path** as part of
AWS Signature V4. Serving the API under a prefix such as `/s3/` means RustFS
receives `/s3/<bucket>/<key>`, reads `s3` as the bucket name, and fails
signature validation on every request.
[Upstream is explicit about it](https://docs.rustfs.com/integration/nginx).

### Path-style addressing only

`RUSTFS_SERVER_DOMAINS` is deliberately unset, so buckets are addressed as
`https://<s3-host>/<bucket>/<key>` and **not** as
`https://<bucket>.<s3-host>/<key>`.

The blocker is the certificate, not RustFS: the Let's Encrypt wildcard OPNsense
renews covers `*.<internal-domain>`, which matches exactly **one** label, so
`mybucket.<s3-host>` is a level too deep and does not verify.
Enabling virtual-host style needs a `*.<s3-host>` wildcard issued
and pushed into 1Panel, plus a matching DNS wildcard in Unbound.

In practice: configure SDKs for path style (`force_path_style` / `AWS_S3_FORCE_PATH_STYLE`),
which aws-cli does automatically when given `--endpoint-url`.

## Prerequisites

### 1. DNS

**Do this before applying the OpenTofu unit.** The DHCP reservation is what
makes the guest come up on `10.10.99.14`; add it afterwards and the VM takes
whatever the pool hands out first, and you get to reboot it.

Four records, and they are the one part of this that is **not** in the repo as
declarative source — `live/ansible/playbooks/opnsense/vars/vault.yaml` is
ansible-vault encrypted, so they have to be pasted in by hand.

| Record | Kind | Value |
| --- | --- | --- |
| `rustfs-01` DHCP reservation | `dnsmasq_hosts` | `BC:24:11:88:AB:23` → `10.10.99.14` |
| `<rustfs-guest>` | `unbound_hosts` | `10.10.99.14` |
| `<s3-host>` | `unbound_host_aliases` | → `<panel-host>` |
| `<console-host>` | `unbound_host_aliases` | → `<panel-host>` |

```bash
ansible-vault edit live/ansible/playbooks/opnsense/vars/vault.yaml
```

Append to `dnsmasq_hosts` (the `.<public-zone>` domain here is the DHCP reservation's
own zone, mirroring `harbor.<public-zone>` — the name clients use is the Unbound alias
further down, not this):

```yaml
  - description: RustFS Object Storage Host 01
    domain: rustfs.<public-zone>
    hardware_addr:
      - BC:24:11:88:AB:23
    host: rustfs-01
    ip:
      - 10.10.99.14
    local: true
```

Append to `unbound_hosts`:

```yaml
  - description: RustFS Object Storage Host 01
    domain: <internal-domain>
    enabled: true
    hostname: rustfs-01
    record_type: A
    state: present
    value: 10.10.99.14
```

Append to `unbound_host_aliases` — **both** of them; the S3 API and the console
are separate hostnames for the reason in the section above:

```yaml
  - alias: rustfs
    description: Alias for RustFS S3 API
    domain: <internal-domain>
    enabled: true
    state: present
    target: <panel-host>
  - alias: rustfs-console
    description: Alias for RustFS Console
    domain: <internal-domain>
    enabled: true
    state: present
    target: <panel-host>
```

Then apply:

```bash
ansible-playbook live/ansible/playbooks/opnsense/manage-dnsmasq-host-overrides.yaml \
  -e opnsense_host=opnsense.<internal-domain>
ansible-playbook live/ansible/playbooks/opnsense/manage-local-dns.yaml \
  -e opnsense_host=opnsense.<internal-domain>
```

> [!NOTE]
> `opnsense_host` in that vault is `opnsense.<public-zone>`, which does not resolve
> from a workstation whose `/etc/resolver/` only covers `<internal-domain>`.
> Hence the `-e` override — same box, and the wildcard covers it, so TLS still
> verifies.

### 2. The VM

```bash
cd live/opentofu/proxmox/petruk-pve/petruk-pve0/vms/rustfs
terragrunt apply
```

Then add the SSH alias the inventory resolves through:

```sshconfig
Host petruk-pve0-rustfs-01
    hostname 10.10.99.14
    port 22
    user ansible
```

### 3. Secrets

```bash
sops -d .vault_pass.enc > .vault_pass && chmod 600 .vault_pass
ansible-vault edit live/ansible/playbooks/rustfs/vars/vault.yaml
```

`vault_rustfs_access_key` and `vault_rustfs_secret_key` are generated already.
Unlike Harbor's admin password these are **not** first-boot-only — RustFS reads
them from the environment on every start, so rotating them is: edit the vault,
re-run the playbook, service restarts. Update anything holding the old key in
the same change.

`tasks/preflight.yaml` refuses to run if they are still the upstream default
`rustfsadmin`/`rustfsadmin`, which would leave the store open to the whole LAN.

## Usage

```bash
source .labirin_venv/bin/activate

# Everything
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/rustfs \
  live/ansible/playbooks/rustfs/install-rustfs.yaml

# A single component (tags: dependencies, data-volume, install, config)
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/rustfs \
  live/ansible/playbooks/rustfs/install-rustfs.yaml --tags config
```

Then publish the two websites:

```bash
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/1panel \
  live/ansible/playbooks/1panel/manage-websites.yaml
```

And narrow the WAF rule that blocks aws-cli — **without this, every aws-cli v2
call gets a 403 that looks exactly like bad credentials**:

```bash
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/1panel \
  live/ansible/playbooks/1panel/manage-waf-overrides.yaml
```

### aws-cli v2 vs 1Panel's WAF

1Panel enables its WAF (1pwaf) on every website it creates, and one stock rule
in `rules/header.json` is fatal here:

```json
{"name": "appFilter1", "rule": "TomcatBypass|Command|Base64", "type": "appFilter"}
```

That is substring-matched, case-insensitively, against the request **headers** —
and aws-cli v2 appends the subcommand you ran to its own User-Agent:

```text
aws-cli/2.36.8 … md/installer#source md/prompt#off md/command#s3.ls
                                                      ^^^^^^^
```

So OpenResty answers with its 403 block page before RustFS is ever reached. What
you see is:

```text
An error occurred (403) when calling the ListBuckets operation: Forbidden
```

which is indistinguishable from a credentials problem. Two things tell them
apart: the WAF's response carries `Server: openresty`, `Content-Type: text/html`
and **no** `x-request-id`, whereas a genuine RustFS refusal is a 110-byte
`<Error><Code>AccessDenied</Code></Error>`; and the same request signed by hand
with any other User-Agent succeeds.

`manage-waf-overrides.yaml` drops the `Command` alternative from that one rule,
for these two sites only. Everything else stays on — the log4shell/JNDI rule and
the scanner rule in the same file, and every other WAF module (sql, xss, args,
cookie, methodWhite, …).

## Why not the upstream one-liner

`curl -O https://rustfs.com/install_rustfs.sh && bash install_rustfs.sh` is what
the docs recommend, and this playbook does not use it — for two reasons that
are not stylistic:

1. **It is interactive.** It `read`s the service port, the console port and the
   data directory from a TTY, with no non-interactive flag. Feeding it answers
   would be a fragile way to reproduce something the tasks express directly.
2. **It downloads `…-latest.zip`.** The installed version becomes whenever you
   happened to run it, which is the opposite of what this repo is for.

`tasks/install.yaml` lays down exactly what that script does — the binary at
`/usr/local/bin/rustfs`, `/etc/default/rustfs`, the systemd unit — from a
pinned, SHA256-verified artifact. The unit is upstream's, with the two
deviations noted in `templates/rustfs.service.j2`.

## Creating buckets

Not managed here. There is no Ansible module that speaks SigV4 without pulling
in `amazon.aws` and boto3, and a bucket is not the kind of thing worth a
hand-rolled signing implementation. Use the console, or aws-cli:

```bash
export AWS_ACCESS_KEY_ID=...        # vault_rustfs_access_key
export AWS_SECRET_ACCESS_KEY=...    # vault_rustfs_secret_key
export AWS_DEFAULT_REGION=us-east-1

aws --endpoint-url https://<s3-host> s3 mb s3://scratch
aws --endpoint-url https://<s3-host> s3 cp ./file s3://scratch/
aws --endpoint-url https://<s3-host> s3 ls s3://scratch/
```

## Sizing

| | |
| --- | --- |
| vCPU | 4 (2 cores × 2 sockets) |
| RAM | 8 GiB, balloons to 4 GiB |
| Root disk | 40 GiB, `local-lvm`, backed up |
| `/data/rustfs0` | 200 GiB, `sas`, **backed up** |

The RAM is not for RustFS itself — it does no in-process caching of object data,
so almost all of it ends up as page cache in front of the data volume.

`/data` **is** backed up, unlike Harbor's. Harbor's `/data` is a cache whose
every byte re-pulls from the internet on demand; this one holds the only copy of
whatever is written to the buckets, and with a single volume there is no parity
to recover from. The PVE backup *is* the durability story.

Growing the volume is two steps and is the only reversible direction, since XFS
grows online and never shrinks:

1. raise `vm_data_disk_size` in the OpenTofu unit and apply
2. `sudo xfs_growfs /data/rustfs0` in the guest

### Going multi-disk is a rebuild

SNMD (erasure coding across several disks) is not a config change. RustFS writes
its erasure layout at first format, so switching means attaching more devices,
mounting them at `/data/rustfs1…N`, **wiping `/data`**, and setting
`rustfs_volumes` to the ellipsis form `"/data/rustfs{0...3}"`.

It also costs roughly half the raw capacity to parity while every one of those
virtual disks still sits on the same PVE datastore — the failure domain barely
narrows. That is why this is SNSD.

## Verifying

```bash
# On the host
systemctl status rustfs --no-pager
curl -fsS http://127.0.0.1:9000/health/ready
findmnt /data/rustfs0
tail -f /var/log/rustfs/rustfs.log

# From the LAN
curl -fsS https://<s3-host>/health/ready
aws --endpoint-url https://<s3-host> s3 ls
```

`journalctl -u rustfs` shows startup and systemd messages only — with
`RUSTFS_OBS_LOG_DIRECTORY` set, the request log goes to files under
`/var/log/rustfs` instead of stdout.

## Troubleshooting

- **Every aws-cli v2 call returns `403 … Forbidden`, but a hand-signed curl
  works** — 1Panel's WAF, not RustFS or the credentials. See the aws-cli section
  above; run `manage-waf-overrides.yaml`.
- **`AccessDenied` XML at the console root** — the console is at
  `/rustfs/console/`. The bare hostname 302s there; if it does not, the proxy
  block is stale, so re-run `manage-websites.yaml`.
- **`NoSuchBucket` / `403` on a bucket that plainly exists** — almost always
  nginx, not RustFS. `proxy_cache_convert_head off` must be present on the site;
  without it nginx rewrites `HEAD` to `GET`, the method no longer matches the
  one inside the SigV4 signature, and the error points nowhere near the cause.
  See `live/ansible/playbooks/1panel/templates/proxy-rustfs-s3.conf.j2`.
- **`SignatureDoesNotMatch` on every request** — the proxy is rewriting `Host`.
  The template sets `proxy_set_header Host $http_host`; `$host` strips the port
  and falls back to `server_name`, and the client signed the header it sent.
- **`413 Request Entity Too Large` on an upload** — OpenResty, not RustFS.
  `client_max_body_size` must be `0` on that site (1Panel's global default is
  50m).
- **A client insists on `<bucket>.<s3-host>`** — it is using
  virtual-host addressing. Force path style; see above for why the certificate
  cannot cover the other form.
- **The service is `active` but nothing answers** — `Type=notify` reports ready
  at the sd_notify handshake, which precedes the volume scan. That is what
  `/health/ready` is for, and what the playbook waits on.
- **RustFS started but the store is empty and `/data/rustfs0` is on the root
  disk** — the mount did not take and RustFS initialised a store underneath it.
  `tasks/data-volume.yaml` asserts against this with `findmnt` before the
  service is touched; if it fires, check `dmesg` and the disk serial.
- **Nothing resolves** — the Unbound aliases are missing. The names are nothing
  until both OPNsense and `manage-websites.yaml` have run.
