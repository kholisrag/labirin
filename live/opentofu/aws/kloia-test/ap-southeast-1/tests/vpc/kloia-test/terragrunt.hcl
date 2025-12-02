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
  cidr = "10.1.0.0/16"

  azs = [
    format("%sa", local.aws_region),
    format("%sb", local.aws_region),
    format("%sc", local.aws_region),
  ]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.cidr, 8, k + 52)]
}

terraform {
  source = format("%s/modules/opentofu/aws/vpc//v6.5.1", get_repo_root())
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

prevent_destroy = false

inputs = {
  name = local.name
  tags = local.tags
  cidr = local.cidr
  azs  = local.azs

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
  intra_subnets   = local.intra_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  vpc_tags = merge(
    local.tags,
    {
      name = format("%s-vpc", local.name)
    }
  )
  dhcp_options_tags = merge(
    local.tags,
    {
      name = format("%s-dhcp-options", local.name)
    }
  )
  public_subnet_tags = merge(
    local.tags,
    {
      "kubernetes.io/role/elb" = 1
      subnet                   = "public"
    }
  )
  public_subnet_tags_per_az = {
    for idx, az in local.azs :
    az => merge(
      local.tags,
      {
        subnet = "public"
        az     = az
      }
    )
  }
  public_route_table_tags = merge(
    local.tags,
    {
      subnet = "public"
    }
  )
  private_subnet_tags = merge(
    local.tags,
    {
      "kubernetes.io/role/internal-elb" = "1"
      "karpenter.sh/discovery"          = local.name
      subnet                            = "private"
    }
  )
  private_subnet_tags_per_az = {
    for idx, az in local.azs :
    az => merge(
      local.tags,
      {
        subnet = "private"
        az     = az
      }
    )
  }
  private_route_table_tags = merge(
    local.tags,
    {
      subnet = "private"
    }
  )
}
