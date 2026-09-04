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
  description = "Grant the operators roles/compute.securityAdmin. The provisioning tooling creates its own per instance firewall rules, so this is required for provisioning to work rather than a convenience. Setting it false will make provisioning fail: a non-owner operator is denied compute.firewalls.create partway through, verified against a scoped identity. Note that GCP cannot scope firewall permissions to a single rule, so this role covers all firewalls in the project, which matters more on an established project than a dedicated one."
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

variable "nat_subnets" {
  type        = list(string)
  description = "Subnet names or self links that Cloud NAT applies to. Leave empty to cover every subnet in the region, which is fine on a dedicated project. On an established project, name the worker's subnet so existing VMs do not silently gain outbound internet access."
  default     = []
}

variable "enabled_apis" {
  type        = list(string)
  description = "APIs enabled on the project. compute is required to create the VM, iap backs SSH without a public IP, cloudquotas allows GPU quota to be read through the API rather than the console, and cloudresourcemanager backs this module's own project IAM bindings when it is applied by a service account."
  default = [
    "compute.googleapis.com",
    "iap.googleapis.com",
    "cloudquotas.googleapis.com",
    # Project IAM bindings are Resource Manager calls. When this module is applied
    # by a service account rather than a human, the quota project resolves to the
    # target project and the API must be enabled there or the bindings fail. User
    # credentials resolve elsewhere and mask this, so it only shows up in CI.
    "cloudresourcemanager.googleapis.com",
  ]
}
