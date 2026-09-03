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

  depends_on = [google_project_service.this]
}

resource "google_compute_router_nat" "gpu_worker" {
  count = var.enable_nat ? 1 : 0

  project = var.project_id
  name    = "${var.network_tag}-nat"
  region  = var.region
  router  = google_compute_router.gpu_worker[0].name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
