variable "project_id" {
  type        = string
  description = "The GCP project to configure. This module never creates the project, it only configures one that already exists."
}

variable "operator_members" {
  type        = list(string)
  description = "IAM members granted access to provision and manage the GPU worker VM. Use the full member syntax, e.g. [\"group:gpu-operators@example.com\"]. A group is preferred over individual users so that staffing changes do not require a Terraform run in this project."

  validation {
    condition     = alltrue([for m in var.operator_members : can(regex("^(user|group|serviceAccount):", m))])
    error_message = "Each member must be prefixed with user:, group: or serviceAccount:."
  }
}

variable "service_account_id" {
  type        = string
  description = "Account ID of the service account the GPU worker VM runs as. The resulting email is <id>@<project_id>.iam.gserviceaccount.com."
  default     = "musubi-gpu-worker"
}

variable "network_tag" {
  type        = string
  description = "Network tag applied to GPU worker VMs. The SSH firewall rule is scoped to this tag so it never applies to other machines in the project."
  default     = "musubi-gpu-worker"
}

variable "grant_firewall_management" {
  type        = bool
  description = "Grant the operators roles/compute.securityAdmin so they can adjust the SSH source range without raising a change request. Set to false if you would rather own the firewall rule yourself. Note that GCP cannot scope firewall permissions to a single rule, so this role covers all firewalls in the project."
  default     = true
}

variable "enable_ssh_firewall" {
  type        = bool
  description = "Create the inbound SSH rule allowing Google's IAP forwarding range to reach tagged VMs on port 22. This is the only inbound rule the GPU worker needs."
  default     = true
}

variable "enable_nat" {
  type        = bool
  description = "Create a Cloud Router and Cloud NAT so the VM can reach the internet without an external IP. Required when org policy enforces constraints/compute.vmExternalIpAccess. Leave false if the VM will be given an external IP."
  default     = false
}

variable "region" {
  type        = string
  description = "Region for the Cloud Router and NAT. Required when enable_nat is true."
  default     = null
}

variable "network" {
  type        = string
  description = "Name or self link of the VPC network the GPU worker attaches to. Required when enable_nat or enable_ssh_firewall is true."
  default     = "default"
}

variable "enabled_apis" {
  type        = list(string)
  description = "APIs enabled on the project. compute is required to create the VM, iap backs SSH without a public IP, and cloudquotas allows the GPU quota to be managed through the API rather than the console."
  default = [
    "compute.googleapis.com",
    "iap.googleapis.com",
    "cloudquotas.googleapis.com",
  ]
}
