# Minimal root configuration for the GPU worker project module.
#
# Usage:
#   cp terraform.tfvars.example terraform.tfvars   # then edit
#   terraform init
#   terraform plan
#   terraform apply
#   terraform output

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

output "handover" {
  description = "Send these values to whoever is provisioning the GPU worker."
  value = {
    project_id            = module.gpu_worker_project.project_id
    region                = module.gpu_worker_project.region
    service_account_email = module.gpu_worker_project.service_account_email
    network               = module.gpu_worker_project.network
    network_tag           = module.gpu_worker_project.network_tag
    nat_enabled           = module.gpu_worker_project.nat_enabled
    ssh_firewall_rule     = module.gpu_worker_project.ssh_firewall_rule
  }
}
