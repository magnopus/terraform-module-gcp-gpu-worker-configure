# The values the provisioning engineer needs once this module has been applied.
# Running `terraform output` and sending the result back is the whole handover.

output "service_account_email" {
  description = "Email of the GPU worker's runtime service account. Passed to --service-account when the VM is created."
  value       = google_service_account.gpu_worker.email
  sensitive   = false
}

output "project_id" {
  description = "The project the GPU worker runs in."
  value       = var.project_id
  sensitive   = false
}

output "region" {
  description = "Region configured for Cloud NAT. Null when enable_nat is false, in which case any region with GPU quota can be used."
  value       = var.enable_nat ? var.region : null
  sensitive   = false
}

output "network" {
  description = "VPC network the GPU worker attaches to."
  value       = var.network
  sensitive   = false
}

output "network_tag" {
  description = "Network tag that must be applied to GPU worker VMs for the SSH rule to match."
  value       = var.network_tag
  sensitive   = false
}

output "nat_enabled" {
  description = "Whether outbound access is via Cloud NAT. When false the VM needs an external IP to reach the internet."
  value       = var.enable_nat
  sensitive   = false
}

output "ssh_firewall_rule" {
  description = "Name of the inbound SSH rule, or null when the project owner creates it themselves."
  value       = var.enable_ssh_firewall ? google_compute_firewall.iap_ssh[0].name : null
  sensitive   = false
}

output "granted_roles" {
  description = "Project level roles granted to the operators, for review."
  value       = local.operator_project_roles
  sensitive   = false
}
