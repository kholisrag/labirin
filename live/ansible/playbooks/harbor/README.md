# harbor

[Harbor](https://goharbor.io/docs/2.15.0/) here is not a place to *keep*
images — it is a **pull-through proxy cache** in front of Docker Hub, ghcr.io,
Quay and registry.k8s.io. Every image the homelab pulls goes through it once,
is stored for the project's retention window, and is served from the LAN after
that.

The immediate reason it exists is Fireactions: its microVM runner image is
pulled from ghcr.io on every pool refill, and a busy PR refills a pool a dozen
times. See
[the Fireactions tutorial this is modelled on](https://fireactions.io/latest/tutorials/docker-registry-mirror/)
and [Harbor's proxy cache docs](https://goharbor.io/docs/2.15.0/administration/configure-proxy-cache/).

| Piece | Role |
| --- | --- |
| Docker CE + compose v2 | Harbor ships as a Compose stack |
| `/data` on a dedicated disk | Registry blobs, Postgres, Redis, job logs |
| [`robertdebock.harbor`](https://github.com/robertdebock/ansible-role-harbor) | Unarchives the installer and runs `install.sh` |
| `templates/harbor.yml.j2` | Replaces the role's config — its template predates 2.15 |
| `tasks/proxy-cache.yaml` | Registry endpoints + proxy cache projects, over the API |

## Layout

```text
live/ansible/playbooks/harbor/
├── install-harbor.yaml    # entrypoint
├── tasks/                 # one file per component
├── templates/
│   └── harbor.yml.j2      # replaces the role's 2.6.0-era config
└── vars/
    ├── main.yaml          # versions, upstreams, proxy projects, sizing
    └── vault.yaml         # admin + Postgres passwords, upstream creds (ansible-vault)
```

The VM itself is provisioned by OpenTofu at
`live/opentofu/proxmox/petruk-pve/petruk-pve0/vms/harbor/`.

## Where the traffic actually goes

```text
  runner microVM / workstation / containerd
        |  https://<registry-host>
        v
  1Panel VM (10.10.99.10) - OpenResty
        |  TLS terminated with the *.<internal-domain> wildcard
        |  http://10.10.99.13
        v
  harbor-01 (10.10.99.13) - Harbor on :80
        |  cache miss only
        v
  docker.io / ghcr.io / quay.io / registry.k8s.io
```

Two names, and mixing them up is the most likely thing to go wrong:

| Name | Resolves to | For |
| --- | --- | --- |
| `<registry-host>` | Unbound **alias** → `<panel-host>` | Every client. This is Harbor's `external_url`. |
| `<harbor-guest>` | **A record** → `10.10.99.13` | SSH, Ansible, and the 1Panel upstream. Not a registry endpoint. |

The certificate is the Let's Encrypt wildcard OPNsense renews and pushes into
1Panel (`live/ansible/playbooks/1panel/acme-cert-updater.yaml`), so it is
publicly trusted — **no `insecure-registries` entry is needed anywhere**, and
if you find yourself adding one, something else is wrong.

## Prerequisites

### 1. DNS

Both names are applied from `live/ansible/playbooks/opnsense/vars/vault.yaml`:

| Record | Kind | Value |
| --- | --- | --- |
| `harbor-01` DHCP reservation | `dnsmasq_hosts` | `BC:24:11:88:AB:22` → `10.10.99.13` |
| `<harbor-guest>` | `unbound_hosts` | `10.10.99.13` |
| `<registry-host>` | `unbound_host_aliases` | → `<panel-host>` |

```bash
ansible-playbook live/ansible/playbooks/opnsense/manage-dnsmasq-host-overrides.yaml \
  -e opnsense_host=opnsense.<internal-domain>
ansible-playbook live/ansible/playbooks/opnsense/manage-local-dns.yaml \
  -e opnsense_host=opnsense.<internal-domain>
```

> [!NOTE]
> `opnsense_host` in that vault is `opnsense.<public-zone>`, which does not resolve
> from a workstation whose `/etc/resolver/` only covers `<internal-domain>`.
> Hence the `-e` override above — same box, and the wildcard covers it, so TLS
> still verifies.

Then add the SSH alias the inventory resolves through:

```sshconfig
Host petruk-pve0-harbor-01
    hostname 10.10.99.13
    port 22
    user ansible
```

### 2. The 1Panel reverse proxy

`<registry-host>` is nothing until 1Panel has a website for it:

```bash
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/1panel \
  live/ansible/playbooks/1panel/manage-websites.yaml
```

That playbook is where the registry-specific nginx tuning lives — see its own
section below for why a default reverse proxy is not enough.

### 3. Secrets

```bash
sops -d .vault_pass.enc > .vault_pass && chmod 600 .vault_pass
ansible-vault edit live/ansible/playbooks/harbor/vars/vault.yaml
```

`vault_harbor_admin_password` and `vault_harbor_db_password` are generated
already — both are **first-install-only**, since one seeds Harbor's admin
account and the other initialises Postgres' superuser. The one worth filling in is
`vault_harbor_dockerhub_*`: anonymous Docker Hub pulls are rate-limited **per
source IP**, and this cache is a single source IP for the whole homelab, so
without a token every CI job shares one anonymous quota. Use a Personal Access
Token with public-repo read scope.

> [!NOTE]
> `harbor_admin_password` is only read on the **first** install — it seeds
> Postgres and is ignored on every later run. Rotate it in the UI and mirror it
> back into the vault, or `tasks/proxy-cache.yaml` stops authenticating.

## Usage

```bash
source .labirin_venv/bin/activate
ansible-galaxy role install -r requirements.yml -p .ansible/roles

# Everything
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/harbor \
  live/ansible/playbooks/harbor/install-harbor.yaml

# A single component (tags: dependencies, data-volume, docker, harbor, proxy-cache)
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/harbor \
  live/ansible/playbooks/harbor/install-harbor.yaml --tags proxy-cache
```

## Using the cache

The project name replaces the upstream registry host; the rest of the path is
passed through verbatim.

| Upstream | Through the cache |
| --- | --- |
| `alpine:3` | `<registry-host>/dockerhub/library/alpine:3` |
| `grafana/grafana:11` | `<registry-host>/dockerhub/grafana/grafana:11` |
| `ghcr.io/hostinger/fireactions-images/ubuntu24.04:TAG` | `<registry-host>/ghcr/hostinger/fireactions-images/ubuntu24.04:TAG` |
| `quay.io/prometheus/node-exporter:v1` | `<registry-host>/quay/prometheus/node-exporter:v1` |
| `registry.k8s.io/pause:3.10` | `<registry-host>/k8s/pause:3.10` |

> [!IMPORTANT]
> The `library/` prefix is **not optional**. Docker only expands the bare name
> `alpine` into `library/alpine` for Docker Hub itself — against any other
> registry host, `<registry-host>/dockerhub/alpine:3` is a 404.

Inside a GitHub Actions job, point BuildKit at it rather than rewriting every
`FROM`:

```yaml
- uses: docker/setup-buildx-action@v3
  with:
    install: true
    driver: docker-container
    config-inline: |
      [registry."docker.io"]
        mirrors = ["<registry-host>/dockerhub"]
```

No `http = true` / `insecure = true` here, unlike the upstream Fireactions
tutorial — that tutorial mirrors to a plain HTTP registry on the CNI gateway.
This one is real HTTPS with a publicly trusted certificate.

### The projects are public

Anonymous pull has to work: the Fireactions hosts pull the runner image with
containerd's default resolver, which carries no credentials and has nowhere to
put any. A private project would take CI down. The exposure is bounded — the
projects are reachable only from the LAN, and a proxy cache can serve only what
its upstream already serves anonymously.

### You cannot push here

Every project is a proxy cache, and Harbor rejects pushes to those. If the
homelab ever needs to *store* an image, add an ordinary (non-proxy) project —
and note that a project's `registry_id` cannot be changed after creation, so
the two kinds are decided once, at creation.

## Sizing

| | |
| --- | --- |
| vCPU | 4 (2 cores × 2 sockets) |
| RAM | 8 GiB, balloons to 4 GiB |
| Root disk | 50 GiB, `local-lvm`, backed up |
| `/data` | 300 GiB, `local-lvm`, **not** backed up |

Harbor's published recommendation is 4 vCPU / 8 GiB / 160 GiB. The disk is
larger than that because the recommendation is for a registry holding your own
artifacts, and this one holds a week of everything the homelab pulls from the
internet. Proxy cache projects get a 7-day retention policy automatically, so
300 GiB is a working set rather than an archive.

Trivy is **not** deployed — `install.sh` only ships it when invoked as
`install.sh --with-trivy`, and the role calls it with no flags. Scanning a
pull-through cache would mean scanning the whole internet. Adding it later
means raising the RAM.

`/data` being excluded from backups is deliberate: almost every byte is a
cached upstream layer that re-pulls on demand, and everything else — projects,
registry endpoints, retention, robot accounts — is declared in `vars/main.yaml`
and re-applied by `--tags proxy-cache`. The recovery path is "re-run Ansible",
not "restore".

Paying for this disk is what shrank the Fireactions containerd disks from
200 GiB to 100 GiB in the same change; see that playbook's README.

## How much of the role we actually use

`robertdebock.harbor` is thin — three tasks and a handler — and we use two of
the three:

| Role does | We |
| --- | --- |
| Unarchives the official installer to `/home/harbor` | keep it |
| Templates `harbor.yml` | **overwrite it** — see below |
| Runs `./install.sh` from a handler | keep it |
| — | install Docker ourselves (`tasks/docker.yaml`) |
| — | prepare `/data` ourselves (`tasks/data-volume.yaml`) |

**Its `harbor.yml` template does not work with Harbor 2.15.** It is frozen at
the 2.6.0 schema, and 2.15's `prepare` indexes `jobservice.job_loggers` with no
fallback, so `install.sh` dies before writing a single container config:

```text
File "/usr/src/app/utils/configs.py", line 232, in parse_yaml_config
  config_dict['job_loggers'] = js_config["job_loggers"]
KeyError: 'job_loggers'
```

`tasks/harbor-config.yaml` therefore writes `templates/harbor.yml.j2` over the
role's file. It cannot be done by overriding the template, because Ansible
resolves a `template:` src from inside a role against the role's own
`templates/` directory first — a same-named file here is never reached. Both
tasks notify the same `Run installer` handler, and handlers run once after
every task that notified them, so `install.sh` is invoked exactly once, against
our file.

Two other things that template fixed along the way: `data_volume` is now driven
by `harbor_data_mount` instead of being hardcoded, and `_version` matches the
release we install rather than saying `2.6.0` (harmless on a fresh install —
only `harbor-migrator` reads it — but wrong to leave for a future in-place
upgrade).

The role also declares no dependencies, so **it does not install Docker** — the
docker roles in its `requirements.yml` exist only for its Molecule scenario.

### Quay uses the generic adapter

`harbor_registries` gives quay.io `type: docker-registry`, not `type: quay`,
even though the `quay` adapter exists and Harbor's docs list Quay as supported
for proxy cache. Proxy cache projects are additionally gated on
`PERMITTED_REGISTRY_TYPES_FOR_PROXY_CACHE`, which in 2.15 is:

```text
docker-hub, harbor, azure-acr, ali-acr, aws-ecr, google-gcr,
docker-registry, github-ghcr, jfrog-artifactory
```

A `quay` endpoint is accepted; the *project* then fails with
`bad request: unsupported registry type quay`. quay.io is a plain OCI registry
for public pulls, so the generic adapter is all it needs.

## Verifying

```bash
# On the host
docker ps --format '{{.Names}}\t{{.Status}}'
curl -fsS http://127.0.0.1/api/v2.0/health | jq .status     # "healthy"

# From anywhere on the LAN
docker pull <registry-host>/dockerhub/library/alpine:3
```

A cache hit is visible as the pull completing without upstream traffic; the
authoritative view is **Projects → dockerhub → Repositories** in the UI, which
only lists what has actually been cached.

## Troubleshooting

- **`unauthorized` or `404` on a pull that should work** — check the path has
  the project name as its first segment and `library/` for Docker Hub official
  images.
- **A project exists but does not proxy** — its `registry_id` is 0, which
  happens when a project of that name was created by hand first. It cannot be
  converted; delete it and re-run. `tasks/proxy-cache.yaml` asserts this rather
  than letting it fail at pull time.
- **`413 Request Entity Too Large` on a push or a large layer** — OpenResty on
  1Panel, not Harbor. `client_max_body_size` must be `0` on that site; see
  `live/ansible/playbooks/1panel/manage-websites.yaml`.
- **API tasks fail with 401 after a while** — the admin password was rotated in
  the UI and not mirrored back into `vars/vault.yaml`.
- **Docker Hub `toomanyrequests`** — the anonymous quota for the whole homelab
  is used up. Fill in `vault_harbor_dockerhub_*`.
- **Harbor is down and CI stops refilling pools** — expected. The Fireactions
  runner image is pulled through this cache, so Harbor is a hard dependency for
  CI capacity. The escape hatch is to point `fireactions_runner_image` back at
  `ghcr.io/...` and re-run that playbook with `--tags fireactions`.
