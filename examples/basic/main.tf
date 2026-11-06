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
      version = "~> 7.33"
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

variable "network" {
  type        = string
  description = "The VPC the GPU worker attaches to. Required: there is no default."
}

variable "enable_nat" {
  type        = bool
  description = "true gives the VM Cloud NAT in region, so it needs no external IP. false creates no NAT, so the VM must get an external IP. Required: there is no default."
}

module "gpu_worker_project" {
  # Local so CI validates the example against this commit. In your own configuration
  # use the released module:
  #   source = "github.com/magnopus/terraform-module-gcp-gpu-worker-configure?ref=v1.0.0"
  source = "../../"

  project_id       = var.project_id
  operator_members = var.operator_members

  network    = var.network
  region     = var.region
  enable_nat = var.enable_nat

  # Upgrading a project first applied with v0.x? Uncomment both to keep its runtime
  # account, network tag and the grants made against them. See the README.
  # service_account_id = "musubi-gpu-worker"
  # network_tag        = "musubi-gpu-worker"
}

# The whole module, not a selection of its outputs: the provisioning side reads all
# of them, and an exported module keeps its nulls (region when NAT is off) where a
# root output set to null is dropped. Send `terraform output -json` back as is.
output "gpu_worker" {
  description = "Send these values to whoever is provisioning the GPU worker."
  value       = module.gpu_worker_project
}
