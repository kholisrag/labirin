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

  prefix_name = "microservices-demo"
  name        = format("%s/%s", local.prefix_name, basename(get_terragrunt_dir()))
  tags = {
    name        = local.name
    environment = local.environment
    region      = local.aws_region
    account     = local.aws_account_name
    opentofu    = "true"
  }
}

terraform {
  source = format("%s/modules/opentofu/aws/ecr//3.1.0", get_repo_root())
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

prevent_destroy = false

inputs = {
  create          = true
  region          = local.aws_region
  tags            = local.tags
  repository_name = local.name
  repository_type = "private"

  repository_read_write_access_arns = []

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 10 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 10
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  create_registry_policy = false
  # registry_policy = jsonencode({
  #   "Version" : "2008-10-17",
  #   "Statement" : [
  #     {
  #       "Sid" : "AllowOrgs",
  #       "Effect" : "Allow",
  #       "Principal" : {
  #         "AWS" : "*"
  #       },
  #       "Action" : [
  #         "ecr:BatchCheckLayerAvailability",
  #         "ecr:BatchGetImage",
  #         "ecr:DescribeRepositories",
  #         "ecr:GetAuthorizationToken",
  #         "ecr:GetDownloadUrlForLayer",
  #         "ecr:GetRepositoryPolicy",
  #         "ecr:ListImages"
  #       ],
  #       "Condition" : {
  #         "ForAnyValue:StringLike" : {
  #           "aws:PrincipalOrgPaths" : "o-3w5f5dhflr/*"
  #         }
  #       }
  #     }
  #   ]
  # })

  repository_image_tag_mutability = "MUTABLE"
}
