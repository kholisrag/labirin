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
    name        = local.name
    environment = local.environment
    region      = local.aws_region
    account     = local.aws_account_name
    opentofu    = "true"
  }
}

terraform {
  source = format("%s/modules/opentofu/aws/github-actions-oidc-role//0.0.5", get_repo_root())
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

prevent_destroy = false

inputs = {
  name          = local.name
  provider_tags = local.tags

  federated_subject_claims = [
    "repo:kholisrag/microservices-demo:ref:refs/*",
    "repo:kholisrag/microservices-demo:pull_request",
  ]
  create_ecr_push_policy = true
  ecr_repository_arns = [
    "arn:aws:ecr:ap-southeast-1:888688231966:repository/microservices-demo/*"
  ]
}
