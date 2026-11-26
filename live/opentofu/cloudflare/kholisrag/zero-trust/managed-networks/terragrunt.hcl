# Managed networks: how the Cloudflare One client knows it is at home.
#
# The client probes `tls_sockaddr` and compares the certificate against
# `sha256`. The endpoint is served from the cloudflared VM by
# live/ansible/playbooks/cloudflared/install-managed-network-endpoint.yaml,
# whose vault holds the same address and fingerprint. Change one, change both.
#
# Address and fingerprint live in values.enc.yaml (sops).
locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  values       = yamldecode(sops_decrypt_file(format("%s/values.enc.yaml", get_terragrunt_dir())))
}

terraform {
  source = "git::https://github.com/kholisrag/iac-modules.git?ref=cloudflare-zero-trust-device-managed-networks/v0.1.0"
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  account_id       = local.account_vars.locals.creds_yaml.account_id
  managed_networks = local.values.managed_networks
}
