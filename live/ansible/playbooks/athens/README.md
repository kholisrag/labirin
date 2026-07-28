# athens

[Athens](https://docs.gomods.io/) is a **pull-through proxy cache for Go
modules** — the `GOPROXY` equivalent of what
[Harbor](../harbor/README.md) does for container images. Every module any
homelab build asks for is fetched once, stored on disk, and served from the LAN
after that. It also fetches the private `github.com/<org>/*` modules on
behalf of clients, so a runner does not need its own GitHub credentials to
`go mod download`.

Unlike Harbor, Athens does **not** get its own VM. It is a Compose stack on the
1Panel guest, created through 1Panel's API so it appears in
*Containers → Compose* exactly like one made in the dashboard — same place to
read its logs, restart it, or watch it fail.

| Piece | Role |
| --- | --- |
| `gomods/athens` container | The proxy itself, on `127.0.0.1:3300` |
| 1Panel Compose (`from: edit`) | Owns the stack; panel writes the files |
| `./data` beside the compose file | The module cache, owned by uid 1000 |
| `ATHENS_GITHUB_TOKEN` | Becomes `~/.netrc` inside the container at startup |
| 1Panel website + OpenResty | TLS termination for `<goproxy-host>` |

## Layout

```text
live/ansible/playbooks/athens/
├── install-athens.yaml         # entrypoint — talks to the 1Panel API
├── templates/
│   └── docker-compose.yml.j2   # the stack, pushed as `file`/`content`
└── vars/
    ├── main.yaml               # version, paths, download mode, timeouts
    └── vault.yaml              # GitHub token (ansible-vault)
```

The reverse proxy is **not** here — it lives with the other 1Panel websites:

```text
live/ansible/playbooks/1panel/
├── vars/main.yaml                       # the <goproxy-host> entry
└── templates/proxy-athens.conf.j2       # the nginx location block
```

## Where the traffic actually goes

```text
  runner microVM / workstation
        |  GOPROXY=https://<goproxy-host>
        v
  1Panel VM (10.10.99.10) — OpenResty, network_mode: host
        |  TLS terminated with the *.<internal-domain> wildcard
        |  http://127.0.0.1:3300
        v
  athens container, same VM, published on loopback only
        |  cache miss only
        +--> proxy.golang.org        (public modules)
        +--> github.com              (github.com/<org>/*, via the token)
```

`127.0.0.1` in the proxy config is doing real work and is not a copy-paste
slip. 1Panel's OpenResty runs with `network_mode: host`, so its loopback *is*
the host's loopback. That is what lets Athens publish on `127.0.0.1:3300`
instead of `0.0.0.0:3300` — the TLS website becomes the only way in, and
nothing on the LAN can reach the proxy in the clear.

One name, unlike Harbor's two, because there is no second VM to SSH into:

| Name | Resolves to | For |
| --- | --- | --- |
| `<goproxy-host>` | Unbound **alias** → `<panel-host>` | Every client. Nothing else. |

## Prerequisites

### 1. DNS

Add the alias in `live/ansible/playbooks/opnsense/vars/vault.yaml` under
`unbound_host_aliases`, pointing `goproxy` at `<panel-host>` — the
same shape as the existing `harbor` alias. No `dnsmasq_hosts` reservation and
no A record: there is no new guest to address.

```bash
ansible-playbook live/ansible/playbooks/opnsense/manage-local-dns.yaml \
  -e opnsense_host=opnsense.<internal-domain>
```

> [!NOTE]
> `opnsense_host` in that vault is `opnsense.<public-zone>`, which does not resolve
> from a workstation whose `/etc/resolver/` only covers `<internal-domain>`.
> Hence the `-e` override — same box, and the wildcard covers it, so TLS still
> verifies.

### 2. Secrets

```bash
sops -d .vault_pass.enc > .vault_pass && chmod 600 .vault_pass
ansible-vault edit live/ansible/playbooks/athens/vars/vault.yaml
```

`vault_athens_github_token` ships **empty**, which is a supported state, not a
broken one: Athens skips building the `.netrc` entirely and serves public
modules normally. The playbook prints a warning and carries on. **This is how
it is currently deployed.**

What an empty token costs you is `athens_private_patterns` — those return a
bare `404` that reads exactly like a missing tag. Verified: with no
credentials, `/github.com/<org>/<repo>/@v/list` returns 404 while
`/github.com/pkg/errors/@v/list` returns 200.

A classic PAT needs `repo`; a fine-grained token needs *Contents: Read* on the
repositories matched by `athens_private_patterns`.

> [!IMPORTANT]
> Athens does not authenticate its callers. Anyone who can reach
> `https://<goproxy-host>` can pull any module this credential can
> read — and the account this proxy would authenticate as can read private Go
> modules in `kloia`, `TrugoSoftwareTeam`, `togg-trumore` and `rate-mate` as
> well as `<org>`.
>
> This is the argument for a **GitHub App** over a PAT, and it is not about
> token rotation. An App installed only on `<org>` *cannot* read the other
> orgs regardless of what `athens_private_patterns` says; a PAT under your
> account can, and only the pattern list stands between it and a request for
> `github.com/kloia/...`. The image already ships `git-credential-github-app`
> for this — mount a `.gitconfig` at `$HOME/.gitconfig` plus the App private
> key, and drop `ATHENS_GITHUB_TOKEN`.

The 1Panel API key comes from `../1panel/vars/vault.yaml` — same panel, same
key as `manage-websites.yaml`, not duplicated here.

## Install

```bash
# 1. the stack
ansible-playbook live/ansible/playbooks/athens/install-athens.yaml

# 2. the website that puts TLS in front of it
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/1panel \
  live/ansible/playbooks/1panel/manage-websites.yaml
```

Both run against `localhost` and talk to the panel over HTTPS; neither needs
SSH to the 1Panel guest.

Re-running is safe. The playbook creates the stack the first time and pushes
the rendered compose file through `/compose/update` after that, so a version
bump in `vars/main.yaml` is a one-line change plus a re-run.

## Verify

```bash
curl -fsS https://<goproxy-host>/readyz          # storage is writable
curl -fsS https://<goproxy-host>/version         # build info

# a real fetch, public
GOPROXY=https://<goproxy-host> \
  go mod download github.com/pkg/errors@v0.9.1

# and private — no GitHub credentials on this machine required
GOPROXY=https://<goproxy-host> GONOSUMDB='github.com/<org>/*' \
  go list -m github.com/<org>/<repo>@latest
```

`/catalog` lists everything currently cached.

## Using it

```bash
go env -w GOPROXY=https://<goproxy-host>,direct
go env -w GONOSUMDB='github.com/<org>/*'
```

Keep the `,direct` fallback. It is what stops a `go build` from failing
outright when the 1Panel VM is down for a reboot.

Do **not** set `GOPRIVATE` on the client for modules you want Athens to fetch —
`GOPRIVATE` implies `GONOPROXY`, which makes the client bypass Athens entirely
and go straight to GitHub, which is exactly the credential-per-runner problem
Athens is here to remove. `GONOSUMDB` alone is the setting you want.

## Things that will bite

**A cold pull of a big module takes minutes, and that is normal.** Download
mode is `sync`: on a cache miss Athens runs `go mod download`, which is a git
clone, while the client waits. The nginx block
(`../1panel/templates/proxy-athens.conf.j2`) uses a 660s read timeout so that
Athens' own 600s stash timeout always expires first and the client gets a real
error instead of a bare `504`.

**The host port is 3300, not Athens' documented 3000.** Gitea already
publishes `127.0.0.1:3000` on this guest. The container still listens on 3000
internally — only the host side of the mapping moved — so every Athens doc you
read will say 3000 and be right about the inside and wrong about the outside.
`install-athens.yaml` preflights the port against the panel's container list
and refuses to run into a clash, but if you change `athens_port` you must
change the `upstream` in `../1panel/vars/main.yaml` to match; nothing links
them automatically.

**1Panel answers a rejected request body with HTTP 200.** The status line is
not a result — the outcome is the `code` field in the JSON body. This bites
hardest on `/files/owner`, whose `user`/`group` fields are declared as
*strings*: send them as JSON numbers and Gin fails to bind, the handler never
runs, the response is a cheerful `200`, and the cache directory stays
root-owned until the container fails with
`mkdir /var/lib/athens/github.com: permission denied`. Every write task in
`install-athens.yaml` checks `json.code` for this reason.

**The cache only grows.** Athens has no retention policy — nothing evicts a
module once stored. It lives on the 1Panel guest's 50 GiB root disk alongside
every other app on that box. Watch it; Go module zips are small individually
but the transitive closure of a few large projects is not. Clearing it is
`docker compose down`, delete `data/`, `docker compose up` — the next build
just re-fetches.

**`ATHENS_GO_BINARY_ENV_VARS` is semicolon-separated and replaces, not
merges.** Comma is a legal separator *inside* `GOPROXY` and `GOPRIVATE`, so
Athens splits that variable on `;`. And whatever you set overrides the image's
config file wholesale, so every value the `go` subprocess needs has to be on
that one line.

**If private fetches 404 despite a good token**, the likely cause is the
`.netrc` Athens generates: it writes `machine github.com login <token>` with no
`password` field. That works for most tokens, but if yours needs the
`x-access-token` form, mount a full `.netrc` and point `ATHENS_NETRC_PATH` at
it instead — and drop `ATHENS_GITHUB_TOKEN`, because Athens refuses to start
when both are set.

**Do not use the `athens` name for a 1Panel *app*.** The stack is created with
`from: edit`, which writes to `/opt/1panel/docker/compose/athens/`. App-store
installs live under `/opt/1panel/apps/` and are managed by a different part of
the panel; the two would collide on the container name.
