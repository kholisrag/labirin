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

variable "k8s" {
  description = "The k8s config"
  type        = any
}
