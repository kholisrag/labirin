variable "gke_cluster_name" {
  description = "The name of the GKE cluster"
  type        = string
}

variable "gke_cluster_location" {
  description = "The location of the GKE cluster"
  type        = string
}

variable "private_endpoint" {
  description = "Use private endpoint or public"
  type        = bool
  default     = true
}

variable "helm_releases" {
  description = "Map of Helm releases to install"
  type        = any
  default     = {}
}

variable "kubectl_manifest_files" {
  description = "The kubectl manifest file to apply"
  type        = any
  default     = {}
}
