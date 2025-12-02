module "github_oidc_role" {
  source  = "voquis/github-actions-oidc-role/aws"
  version = "0.0.5"

  name                               = var.name
  federated_subject_claims           = var.federated_subject_claims
  url                                = var.url
  client_id_list                     = var.client_id_list
  thumbprint_list                    = var.thumbprint_list
  provider_tags                      = var.provider_tags
  create_terraform_s3_backend_policy = var.create_terraform_s3_backend_policy
  terraform_policy_name              = var.terraform_policy_name
  terraform_s3_bucket_arn            = var.terraform_s3_bucket_arn
  terraform_dynamodb_table_arn       = var.terraform_dynamodb_table_arn
  create_ecr_push_policy             = var.create_ecr_push_policy
  ecr_push_policy_name               = var.ecr_push_policy_name
  ecr_repository_arns                = var.ecr_repository_arns
  create_s3_sync_policy              = var.create_s3_sync_policy
  s3_sync_policy_name                = var.s3_sync_policy_name
  s3_sync_bucket_arns                = var.s3_sync_bucket_arns

}
