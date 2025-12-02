locals {
  provider_vars    = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  account_vars     = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  provider_id      = local.provider_vars.locals.provider_id
  aws_account_id   = local.account_vars.locals.creds_yaml.aws_account_id
  aws_account_name = local.account_vars.locals.creds_yaml.aws_account_name
  aws_region       = local.region_vars.locals.region
  environment      = local.environment_vars.locals.environment

  name = basename(get_terragrunt_dir())
  tags = {
    environment = local.environment
    region      = local.aws_region
    account     = local.aws_account_name
    opentofu    = "true"
  }
}

terraform {
  source = "tfr:///terraform-aws-modules/eks/aws//modules/karpenter?version=21.10.1"
}
