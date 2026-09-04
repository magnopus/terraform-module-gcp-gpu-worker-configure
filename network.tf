# ---------------------------------------------------------------------------
# Inbound SSH
#
# The only inbound rule the GPU worker needs. Scoped to Google's IAP forwarding
# range and to the worker's network tag, so it does not apply to anything else
# in the project and does not expose the VM to the open internet.
# ---------------------------------------------------------------------------

resource "google_compute_firewall" "iap_ssh" {
  count = var.enable_ssh_firewall ? 1 : 0

  project     = var.project_id
  name        = "${var.network_tag}-allow-ssh"
  network     = var.network
  description = "Allow SSH from Google's IAP forwarding range to GPU worker VMs."
  direction   = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [local.iap_forwarding_range]
  target_tags   = [var.network_tag]

  depends_on = [google_project_service.this]
}

# ---------------------------------------------------------------------------
# Outbound access without an external IP
#
# The worker pulls container images and model weights over HTTPS. An external IP
# covers that on its own, so this is only needed when org policy enforces
# constraints/compute.vmExternalIpAccess.
#
# Worth noting NAT restores outbound access only. It does not provide a route in,
# so it is not a substitute for an external IP if direct SSH is wanted as a
# fallback to the IAP tunnel.
# ---------------------------------------------------------------------------

resource "google_compute_router" "gpu_worker" {
  count = var.enable_nat ? 1 : 0

  project = var.project_id
  name    = "${var.network_tag}-router"
  region  = var.region
  network = var.network

  # Fail at plan rather than partway through apply. Without this, enable_nat with no
  # region plans clean and then fails after the APIs, service account, IAM bindings
  # and firewall rule already exist, leaving a half configured project.
  lifecycle {
    precondition {
      condition     = var.region != null
      error_message = "region must be set when enable_nat is true. Cloud Router and NAT are regional resources."
    }
  }

  depends_on = [google_project_service.this]
}

resource "google_compute_router_nat" "gpu_worker" {
  count = var.enable_nat ? 1 : 0

  project = var.project_id
  name    = "${var.network_tag}-nat"
  region  = var.region
  router  = google_compute_router.gpu_worker[0].name

  nat_ip_allocate_option = "AUTO_ONLY"

  # Defaults to every subnet in the region, which on an established project hands
  # outbound internet to existing VMs that deliberately had none. Set nat_subnets to
  # scope it to the worker's subnet only.
  source_subnetwork_ip_ranges_to_nat = length(var.nat_subnets) > 0 ? "LIST_OF_SUBNETWORKS" : "ALL_SUBNETWORKS_ALL_IP_RANGES"

  dynamic "subnetwork" {
    for_each = toset(var.nat_subnets)
    content {
      name                    = subnetwork.value
      source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
    }
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
