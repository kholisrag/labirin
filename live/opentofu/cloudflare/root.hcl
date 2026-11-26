locals {
  provider_vars = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  account_vars  = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  backend_yaml  = yamldecode(sops_decrypt_file("${get_repo_root()}/live/opentofu/cloudflare/backend.enc.yaml"))

  provider_id = local.provider_vars.locals.provider_id
}

terraform_binary = "tofu"

# The API token is scoped to this one account:
#   Account > Cloudflare Tunnel > Edit
#   Account > Zero Trust > Edit
# It lives, with the account ID, in <account>/creds.enc.yaml (sops/age).
generate "cloudflare_provider" {
  path      = format("%s_provider.tf", local.provider_id)
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "${local.provider_id}" {
  api_token = "${local.account_vars.locals.creds_yaml.api_token}"
}
EOF
}

# Same R2 bucket and passphrase as the proxmox tree, separate key prefix.
# State carries every CIDR, endpoint and fingerprint the units manage, so
# state AND plan encryption stay enforced.
generate "r2_backend_remote_state" {
  path      = "cf_r2_backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  backend "s3" {
    bucket                      = "${local.backend_yaml.bucket}"
    key                         = "${format("live/opentofu/cloudflare/%s/default.tfstate", path_relative_to_include())}"
    region                      = "${local.backend_yaml.region}"
    use_lockfile                = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
    access_key                  = "${local.backend_yaml.access_key}"
    secret_key                  = "${local.backend_yaml.secret_key}"
    endpoints = {
      s3 = "${local.backend_yaml.endpoint}"
    }
  }
  encryption {
    key_provider "pbkdf2" "mykey" {
      passphrase = "${local.backend_yaml.pbkdf2_passphrase}"
      key_length = 32
      iterations = 600000
      salt_length = 32
      hash_function = "sha512"
    }
    method "aes_gcm" "passphrase" {
      keys = key_provider.pbkdf2.mykey
    }
    state {
      enforced = true
      method = method.aes_gcm.passphrase
    }
    plan {
      enforced = true
      method = method.aes_gcm.passphrase
    }
    remote_state_data_sources {
      default {
        method = method.aes_gcm.passphrase
      }
    }
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
      ".*Could not retrieve the list of available versions for provider.*",
      ".*context deadline exceeded.*",
      ".*Failed to retrieve available versions for module.*",
      ".*net/http: TLS handshake timeout.*",
      ".*read: connection reset by peer.*",
      ".*Failed to resolve provider packages.*",
    ]
    max_attempts       = 10
    sleep_interval_sec = 10
  }
}
