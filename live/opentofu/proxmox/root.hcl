locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  backend_yaml    = yamldecode(sops_decrypt_file("${get_repo_root()}/live/opentofu/proxmox/backend.enc.yaml"))

  provider_id = local.provider_vars.locals.provider_id
}

terraform_binary = "tofu"

generate "proxmox_provider" {
  path      = format("%s_provider.tf", local.provider_id)
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "${local.provider_id}" {
  endpoint  = "${local.datacenter_vars.locals.creds_yaml.pve_endpoint}"
  api_token = "${local.datacenter_vars.locals.creds_yaml.pve_api_token}"
  insecure  = true
  ssh {
    agent    = true
    username = "root"
  }
}
EOF
}

generate "r2_backend_remote_state" {
  path      = "cf_r2_backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  backend "s3" {
    bucket                      = "${local.backend_yaml.bucket}"
    key                         = "${format("live/opentofu/proxmox/%s/default.tfstate", path_relative_to_include())}"
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

  before_hook "setup_ssh_agent" {
    commands = ["apply", "plan", "destroy", "init", "validate"]
    execute = [
      "bash", "-c",
      <<-EOT
        SSH_KEY_FILE=$(mktemp)
        echo '${local.datacenter_vars.locals.creds_yaml.pve_ssh_private_key}' > "$SSH_KEY_FILE"
        chmod 600 "$SSH_KEY_FILE"

        if [ -z "$SSH_AUTH_SOCK" ]; then
          eval "$(ssh-agent -s)"
        fi

        ssh-add "$SSH_KEY_FILE" 2>/dev/null
        rm -f "$SSH_KEY_FILE"
      EOT
    ]
  }

  after_hook "cleanup_ssh_agent" {
    commands     = ["apply", "plan", "destroy", "init", "validate"]
    execute      = ["bash", "-c", "ssh-agent -k 2>/dev/null || true"]
    run_on_error = true
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
      ".*If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry.*"
    ]
    max_attempts       = 30
    sleep_interval_sec = 10
  }
}
