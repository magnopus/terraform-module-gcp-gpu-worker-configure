locals {
  service_account_email = "${var.service_account_id}@${var.project_id}.iam.gserviceaccount.com"

  # Google's IAP TCP forwarding range. Fixed and owned by Google, so this rule
  # never needs editing as engineers or their addresses change. Access is
  # controlled by IAM (roles/iap.tunnelResourceAccessor) rather than by source IP.
  iap_forwarding_range = "35.235.240.0/20"

  # Private Google Access virtual range. Reaches Google APIs and Artifact Registry
  # without the traffic leaving Google's network.
  private_google_access_range = "199.36.153.8/30"

  network_name = var.create_network ? google_compute_network.this[0].name : var.network
  subnet_name  = var.create_network ? google_compute_subnetwork.this[0].name : var.subnet
}

# ---------------------------------------------------------------------------
# Optional dedicated network
#
# A stock project uses the auto-created default VPC, which carries
# default-allow-ssh from anywhere. Creating a network here avoids inheriting that,
# and lets the subnet be created with Private Google Access already on.
# ---------------------------------------------------------------------------

resource "google_compute_network" "this" {
  count = var.create_network ? 1 : 0

  project                 = var.project_id
  name                    = "${var.network_tag}-vpc"
  auto_create_subnetworks = false
  description             = "GPU worker network (created by Terraform)"

  depends_on = [google_project_service.this]
}

resource "google_compute_subnetwork" "this" {
  count = var.create_network ? 1 : 0

  project                  = var.project_id
  name                     = "${var.network_tag}-subnet"
  region                   = var.region
  network                  = google_compute_network.this[0].id
  ip_cidr_range            = var.network_cidr
  private_ip_google_access = true

  lifecycle {
    precondition {
      condition     = var.region != null
      error_message = "region must be set when create_network is true. Subnets are regional."
    }
  }
}

# ---------------------------------------------------------------------------
# APIs
# disable_on_destroy is false deliberately. Destroying this module should give
# back the access it granted, not disable APIs that other workloads in the
# project may depend on.
# ---------------------------------------------------------------------------

resource "google_project_service" "this" {
  for_each = toset(var.enabled_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# The GPU worker's runtime service account
#
# The VM runs as this identity rather than the default compute service account,
# which keeps it obvious what the worker is doing. It is intentionally granted
# nothing in this project. Everything the worker reads, model weights and
# container images, is granted to this account on the Musubi side.
# ---------------------------------------------------------------------------

resource "google_service_account" "gpu_worker" {
  project      = var.project_id
  account_id   = var.service_account_id
  display_name = "GPU worker runtime identity (created by Terraform)"
  description  = "Attached to GPU worker VMs. Holds no permissions in this project by design."

  depends_on = [google_project_service.this]
}
