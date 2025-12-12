# talos-init

This directory contains the declarative approach for the Talos init configuration.
Redundant with [talos-init extra-manifest](../../../../../../ansible/playbooks/talos-k8s/upload-extra-manifests.yaml)

Why this happen because many times if we want to upgrade after the cluster is already running, we need to update the extra-manifest to make sure the new version / configuration is used.
