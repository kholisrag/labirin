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
}

generate "aws_provider" {
  path      = format("%s_provider.tf", local.provider_id)
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "${local.provider_id}" {
  region = "${local.aws_region}"
  allowed_account_ids = ["${local.aws_account_id}"]
  access_key = "${local.account_vars.locals.creds_yaml.aws_access_key_id}"
  secret_key = "${local.account_vars.locals.creds_yaml.aws_secret_access_key}"
}
EOF
}

remote_state {
  backend = "s3"
  config = {
    bucket       = format("%s-terraform-remote-state-%s", local.aws_region, local.aws_account_name)
    key          = format("%s/terraform.tfstate", path_relative_to_include())
    region       = local.aws_region
    encrypt      = true
    use_lockfile = true
  }
}

generate "aws_s3_backend_remote_state" {
  path      = "aws_s3_backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  backend "s3" {
    bucket                      = "${format("%s-terraform-remote-state-%s", local.aws_region, local.aws_account_name)}"
    key                         = "${format("live/opentofu/aws/%s/default.tfstate", path_relative_to_include())}"
    region                      = "${local.aws_region}"
    use_lockfile                = true
    access_key = "${local.account_vars.locals.creds_yaml.aws_access_key_id}"
    secret_key = "${local.account_vars.locals.creds_yaml.aws_secret_access_key}"
  }
}
EOF
}

terraform {
  extra_arguments "add_signatures_for_other_platforms" {
    commands = contains(get_terraform_cli_args(), "lock") ? ["providers"] : []
    env_vars = {
      TF_CLI_ARGS_providers_lock = "-platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=darwin_amd64"
    }
  }
}

errors {
  retry "transient_errors" {
    retryable_errors = [
      ".*Error installing provider.*connection reset by peer.*",
      ".*Error while installing.*tcp.*i/o timeout.*",
      ".*Error while installing.*could not query provider.*",
      ".*Error while installing.*exceeded while awaiting headers.*",
      ".*ssh_exchange_identification.*Connection closed by remote host.*",
      ".*failed to create kubernetes rest client for update of resource.*",
      ".*Could not retrieve the list of available versions for provider.*",
      ".*context deadline exceeded.*",
      ".*Failed to retrieve available versions for module.*",
      ".*net/http: TLS handshake timeout.*",
      ".*dial.*connect: connection refused.*",
      ".*read: connection reset by peer.*",
      ".*read: connection timed out.*",
      ".*When expanding the plan for.*to include new values learned so far during apply, provider.*changed the planned action from NoOp to Create.*",
      ".*Terraform failed to fetch the requested providers for.*",
      ".*Error building changeset.*but it already exists.*",
      ".*If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry.*",
      ".*Failed to resolve provider packages.*",
    ]
    max_attempts       = 10
    sleep_interval_sec = 10
  }
}
