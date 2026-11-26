# Device profiles.
#
#   Default — the account DEFAULT profile, i.e. away from home. Home CIDRs
#             go through the `petruk-homelab` tunnel.
#   Mobile  — android/ios away from home, same idea with fewer CIDRs.
#   Home    — matched by the `home` managed network. Every home segment
#             routes to every other one directly, so nothing needs the
#             tunnel; Gateway DNS filtering still applies.
#
# The managed-network endpoint IP sits inside an included home /24. The client
# would drop that WHOLE entry from the tunnel, so the outside profiles carry
# the /24 split around the endpoint /32 instead (see values.enc.yaml).
#
# Split Tunnel entries, fallback domains and import IDs live in
# values.enc.yaml (sops).
locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  account_id   = local.account_vars.locals.creds_yaml.account_id
  values       = yamldecode(sops_decrypt_file(format("%s/values.enc.yaml", get_terragrunt_dir())))

  custom_profiles_raw = local.values.custom_profiles
}

terraform {
  source = "git::https://github.com/kholisrag/iac-modules.git?ref=cloudflare-zero-trust-device-profiles/v0.1.0"
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

# A profile names its managed network by key (`managed_network: home`); the
# match expression is built from the managed-networks unit's output so a
# rename there cannot leave a profile matching nothing.
dependency "managed_networks" {
  config_path = "../managed-networks"

  mock_outputs = {
    managed_network_names = { home = "home" }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

# Adopts the default profile, its fallback list, and any custom profile that
# was created in the dashboard. No-ops once in state.
generate "imports" {
  path      = "imports.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
  import {
    to = cloudflare_zero_trust_device_default_profile.default["default"]
    id = "${local.account_id}"
  }
  import {
    to = cloudflare_zero_trust_device_default_profile_local_domain_fallback.default["default"]
    id = "${local.account_id}"
  }
  %{for k, v in local.custom_profiles_raw~}
  %{if lookup(v, "import_id", null) != null~}
  import {
    to = cloudflare_zero_trust_device_custom_profile.custom["${k}"]
    id = "${local.account_id}/${v.import_id}"
  }
  import {
    to = cloudflare_zero_trust_device_custom_profile_local_domain_fallback.custom["${k}"]
    id = "${local.account_id}/${v.import_id}"
  }
  %{endif~}
  %{endfor~}
  EOF
}

inputs = {
  account_id      = local.account_id
  default_profile = local.values.default_profile

  custom_profiles = {
    for k, v in local.custom_profiles_raw : k => merge(
      { for kk, vv in v : kk => vv if !contains(["import_id", "managed_network"], kk) },
      lookup(v, "managed_network", null) == null ? {} : {
        match = format("network == \"%s\"", dependency.managed_networks.outputs.managed_network_names[v.managed_network])
      }
    )
  }
}
