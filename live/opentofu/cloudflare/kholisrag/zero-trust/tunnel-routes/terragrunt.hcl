# Private-network routes published through the `petruk-homelab` tunnel
# (the tunnel itself is remotely managed and its connector token is deployed by
# live/ansible/playbooks/cloudflared). Routes reference the tunnel by ID and
# never own it.
#
# Every CIDR, the tunnel ID and the import IDs live in values.enc.yaml (sops).
locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  account_id   = local.account_vars.locals.creds_yaml.account_id
  values       = yamldecode(sops_decrypt_file(format("%s/values.enc.yaml", get_terragrunt_dir())))

  # `import_id` is bookkeeping for adopting resources created in the
  # dashboard; the module never sees it.
  virtual_networks = {
    for k, v in local.values.virtual_networks : k => { for kk, vv in v : kk => vv if kk != "import_id" }
  }
  routes = {
    for k, v in local.values.routes : k => { for kk, vv in v : kk => vv if kk != "import_id" }
  }
}

terraform {
  source = "git::https://github.com/kholisrag/iac-modules.git?ref=cloudflare-zero-trust-tunnel-routes/v0.1.0"
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

# Adopts what was created in the dashboard. Once in state these blocks are
# no-ops; drop an entry's `import_id` to stop emitting its block.
generate "imports" {
  path      = "imports.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
  %{for k, v in local.values.virtual_networks~}
  %{if lookup(v, "import_id", null) != null~}
  import {
    to = cloudflare_zero_trust_tunnel_cloudflared_virtual_network.virtual_network["${k}"]
    id = "${local.account_id}/${v.import_id}"
  }
  %{endif~}
  %{endfor~}
  %{for k, v in local.values.routes~}
  %{if lookup(v, "import_id", null) != null~}
  import {
    to = cloudflare_zero_trust_tunnel_cloudflared_route.route["${k}"]
    id = "${local.account_id}/${v.import_id}"
  }
  %{endif~}
  %{endfor~}
  EOF
}

inputs = {
  account_id       = local.account_id
  virtual_networks = local.virtual_networks
  routes           = local.routes
}
