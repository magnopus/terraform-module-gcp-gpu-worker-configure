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
  network     = local.network_name
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

# Auto-allocated NAT addresses can change, which breaks any allowlist built on them.
resource "google_compute_address" "nat" {
  count = var.enable_nat ? var.nat_static_ip_count : 0

  project      = var.project_id
  name         = "${var.network_tag}-nat-${count.index}"
  region       = var.region
  address_type = "EXTERNAL"
  description  = "Static egress address for GPU worker NAT (created by Terraform)"

  depends_on = [google_project_service.this]
}

resource "google_compute_router_nat" "gpu_worker" {
  count = var.enable_nat ? 1 : 0

  project = var.project_id
  name    = "${var.network_tag}-nat"
  region  = var.region
  router  = google_compute_router.gpu_worker[0].name

  nat_ip_allocate_option = var.nat_static_ip_count > 0 ? "MANUAL_ONLY" : "AUTO_ONLY"
  nat_ips                = google_compute_address.nat[*].self_link

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

# ---------------------------------------------------------------------------
# Optional egress
#
# GCP allows all egress by default, so these are only needed where the VPC denies
# it. The deny sits at 65534 so the allows above it still match.
# ---------------------------------------------------------------------------

resource "google_compute_firewall" "egress_google_apis" {
  count = var.manage_egress ? 1 : 0

  project     = var.project_id
  name        = "${var.network_tag}-egress-google-apis"
  network     = local.network_name
  description = "Google APIs and Artifact Registry over Private Google Access. Needs create_pga_dns or equivalent DNS."
  direction   = "EGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges = [local.private_google_access_range]
  target_tags        = [var.network_tag]
}

resource "google_compute_firewall" "egress_api" {
  count = var.manage_egress ? 1 : 0

  project     = var.project_id
  name        = "${var.network_tag}-egress-api"
  network     = local.network_name
  description = "Magnopus API on 443."
  direction   = "EGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges = var.magnopus_api_ips
  target_tags        = [var.network_tag]

  lifecycle {
    precondition {
      condition     = length(var.magnopus_api_ips) > 0
      error_message = "magnopus_api_ips must be set when manage_egress is true. Magnopus supplies it, and it differs per environment."
    }
  }
}

# Separate from the API rule on purpose. One rule carrying both sets of addresses and
# both sets of ports would allow AMQP to the API and 443 to the queue.
resource "google_compute_firewall" "egress_queue" {
  count = var.manage_egress ? 1 : 0

  project     = var.project_id
  name        = "${var.network_tag}-egress-queue"
  network     = local.network_name
  description = "Magnopus job queue over AMQP."
  direction   = "EGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = var.magnopus_queue_ports
  }

  destination_ranges = var.magnopus_queue_ips
  target_tags        = [var.network_tag]

  lifecycle {
    precondition {
      condition     = length(var.magnopus_queue_ips) > 0
      error_message = "magnopus_queue_ips must be set when manage_egress is true. Magnopus supplies it, and it differs per environment."
    }
  }
}

resource "google_compute_firewall" "egress_deny" {
  count = var.manage_egress ? 1 : 0

  project     = var.project_id
  name        = "${var.network_tag}-egress-deny"
  network     = local.network_name
  description = "Deny everything the rules above do not allow."
  direction   = "EGRESS"
  priority    = 65534

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = [var.network_tag]
}

# ---------------------------------------------------------------------------
# Optional private DNS for Private Google Access
#
# Without these, googleapis.com and pkg.dev resolve to public addresses and the
# egress deny blocks them, which looks like a broken firewall rule.
# ---------------------------------------------------------------------------

locals {
  pga_zones = var.create_pga_dns ? {
    googleapis = "googleapis.com."
    pkgdev     = "pkg.dev."
  } : {}
}

resource "google_dns_managed_zone" "pga" {
  for_each = local.pga_zones

  project     = var.project_id
  name        = "${var.network_tag}-${each.key}"
  dns_name    = each.value
  description = "Private Google Access (created by Terraform)"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = var.create_network ? google_compute_network.this[0].id : "projects/${var.project_id}/global/networks/${local.network_name}"
    }
  }

  depends_on = [google_project_service.this]
}

resource "google_dns_record_set" "pga_apex" {
  for_each = local.pga_zones

  project      = var.project_id
  managed_zone = google_dns_managed_zone.pga[each.key].name
  name         = each.value
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"]
}

resource "google_dns_record_set" "pga_wildcard" {
  for_each = local.pga_zones

  project      = var.project_id
  managed_zone = google_dns_managed_zone.pga[each.key].name
  name         = "*.${each.value}"
  type         = "CNAME"
  ttl          = 300
  rrdatas      = [each.value]
}
