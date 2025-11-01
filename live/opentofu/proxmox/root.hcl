locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))

  provider_id         = local.provider_vars.locals.provider_id
  pm_api_url          = local.datacenter_vars.locals.creds.pm_api_url
  pm_api_token_id     = local.datacenter_vars.locals.creds.pm_api_token_id
  pm_api_token_secret = local.datacenter_vars.locals.creds.pm_api_token_secret
}

terraform_binary = "tofu"

generate "proxmox_provider" {
  path      = format("%s_provider.tf", local.provider_id)
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "${local.provider_id}" {
  pm_api_url          = "${local.pm_api_url}"
  pm_api_token_id     = "${local.pm_api_token_id}"
  pm_api_token_secret = "${local.pm_api_token_secret}"
  pm_tls_insecure     = true
}
EOF
}

