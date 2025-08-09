# **Labirin**

A Monorepo for Centralized Sources of Truth for My Personal Projects, that can be published.

## Known Use Cases

1. Infrastructure as Code (IaC) using `terragrunt` and `opentofu`

2. Configuration Management, Application Deployment, and Orchestration using `ansible`

## For My Self

- [ ] Documents the Proxmox template creation

- [ ] Start to use `terragrunt` and `opentofu` for Proxmox VM creation

## Ansible Playbook

```bash
uv venv .labirin_venv/ --python 3.14
source .labirin_venv/bin/activate

uv pip <subcommand>
uv pip freeze > requirements.txt
```
