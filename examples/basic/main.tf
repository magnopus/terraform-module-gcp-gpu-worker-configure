# Minimal root configuration for the GPU worker project module.
#
# Usage:
#   cp terraform.tfvars.example terraform.tfvars   # then edit
#   terraform init
#   terraform plan
#   terraform apply
#   terraform output -json

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
  required_version = "~> 1.0"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type        = string
  description = "The GCP project to configure."
}

variable "region" {
  type        = string
  description = "Region used for Cloud NAT, and as the provider default."
  default     = "us-west1"
}

variable "operator_members" {
  type        = list(string)
  description = "Who gets access to provision and manage the GPU worker VM."
}

variable "enable_nat" {
  type        = bool
  description = "Set true when the VM will have no external IP."
  default     = false
}

module "gpu_worker_project" {
  source = "../../"

  project_id       = var.project_id
  operator_members = var.operator_members

  region     = var.region
  enable_nat = var.enable_nat
}

# The whole module, not a selection of its outputs: the provisioning side reads all
# of them, and an exported module keeps its nulls (region when NAT is off) where a
# root output set to null is dropped. Send `terraform output -json` back as is.
output "gpu_worker" {
  description = "Send these values to whoever is provisioning the GPU worker."
  value       = module.gpu_worker_project
}
