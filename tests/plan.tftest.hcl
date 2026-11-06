# Offline regression tests. No GCP access needed and nothing is created.
#
# Every resource in this module is a create, so `plan` never reads real state and
# the provider never has to authenticate against anything. A syntactically valid
# but fake credential is enough to let the provider configure.
#
#   ./tests/run.sh
#
# run.sh sets GOOGLE_CREDENTIALS to the fake key. Credentials cannot be wired up
# from inside a .tftest.hcl provider block, since those cannot reference path.module.
#
# These cover the cases that can be checked without a project. The findings that
# needed a real one are noted in the README: the default VPC ingress union, the
# permission denials, and IAM propagation delay.

variables {
  project_id       = "test-project"
  operator_members = ["user:a@example.com"]

  # Required from v1. Every run below names them, as a customer now has to.
  network    = "worker-vpc"
  enable_nat = false
}

run "single_operator" {
  command = plan
}

run "default_names_carry_no_codename" {
  command = plan

  variables {
    manage_egress      = true
    magnopus_api_ips   = ["192.0.2.10/32"]
    magnopus_queue_ips = ["192.0.2.20/32"]
  }

  assert {
    condition     = google_service_account.gpu_worker.account_id == "gpu-worker" && output.network_tag == "gpu-worker"
    error_message = "service_account_id and network_tag should both default to gpu-worker."
  }

  # Every name derived from the tag must stay a valid GCP name: lowercase, a letter
  # first, no trailing hyphen, at most 63 characters.
  assert {
    condition = alltrue([
      for n in [
        google_compute_firewall.iap_ssh[0].name,
        google_compute_firewall.egress_google_apis[0].name,
        google_compute_firewall.egress_api[0].name,
        google_compute_firewall.egress_queue[0].name,
        google_compute_firewall.egress_deny[0].name,
      ] : can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", n)) && !strcontains(n, "musubi")
    ])
    error_message = "Firewall rule names derived from the default tag should be valid and carry no codename."
  }
}

run "default_names_valid_for_created_network_nat_and_dns" {
  command = plan

  variables {
    network                = null
    create_network         = true
    enable_nat             = true
    region                 = "us-west1"
    nat_static_ip_count    = 1
    additional_nat_regions = { "us-central1" = [] }
    create_pga_dns         = true
  }

  assert {
    condition = alltrue([
      for n in concat(
        [
          google_compute_network.this[0].name,
          google_compute_subnetwork.this[0].name,
          google_compute_router.gpu_worker[0].name,
          google_compute_router_nat.gpu_worker[0].name,
          google_compute_address.nat[0].name,
          google_compute_router.gpu_worker_additional["us-central1"].name,
          google_compute_router_nat.gpu_worker_additional["us-central1"].name,
        ],
        [for a in google_compute_address.nat_additional : a.name],
        [for z in google_dns_managed_zone.pga : z.name],
      ) : can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", n)) && !strcontains(n, "musubi")
    ])
    error_message = "Network, subnet, router, NAT, address and DNS zone names derived from the default tag should be valid and carry no codename."
  }
}

run "v0_names_can_be_kept" {
  command = plan

  variables {
    service_account_id = "musubi-gpu-worker"
    network_tag        = "musubi-gpu-worker"
  }

  # An existing project keeps its account, and with it every grant made against it.
  assert {
    condition     = google_service_account.gpu_worker.account_id == "musubi-gpu-worker" && google_compute_firewall.iap_ssh[0].name == "musubi-gpu-worker-allow-ssh"
    error_message = "Setting both names to musubi-gpu-worker should reproduce the v0.x account and rule."
  }
}

run "service_account_id_must_be_6_to_30_characters" {
  command = plan

  variables {
    service_account_id = "gpu"
  }

  expect_failures = [var.service_account_id]
}

run "service_account_survives_destroy_and_reapply" {
  command = plan

  # Magnopus grants the worker its models and images against this account. A
  # deleted and recreated account under the same email holds none of them.
  assert {
    condition     = google_service_account.gpu_worker.deletion_policy == "ABANDON"
    error_message = "Destroy should leave the runtime account in GCP."
  }

  assert {
    condition     = google_service_account.gpu_worker.create_ignore_already_exists == true
    error_message = "A re-apply should adopt the abandoned account rather than fail on already exists."
  }
}

run "network_has_no_default" {
  command = plan

  variables {
    network             = null
    enable_ssh_firewall = false
  }

  # The old default was the default VPC, whose default-allow-ssh is open to the
  # internet. Omitting network is a missing required variable; null must not be a
  # way back to an unnamed network either. The SSH rule is off here because, when a
  # firewall rule or router is planned, its own "network is required" error fires
  # first. This covers the case where nothing else would have caught it.
  expect_failures = [output.network]
}

run "created_network_needs_no_network_name" {
  command = plan

  variables {
    network        = null
    create_network = true
    region         = "us-west1"
  }

  assert {
    condition     = output.network == "gpu-worker-vpc"
    error_message = "With create_network, the worker should use the network the module creates."
  }
}

run "no_nat_means_external_ips" {
  command = plan

  assert {
    condition     = length(google_compute_router_nat.gpu_worker) == 0 && output.nat_enabled == false && length(output.nat_regions) == 0
    error_message = "enable_nat = false should create no NAT and report it, so the VM is given an external IP."
  }
}

run "os_admin_login_is_not_granted" {
  command = plan

  # Never used: SSH goes through instance metadata keys, not OS Login.
  assert {
    condition     = !contains(local.operator_project_roles, "roles/compute.osAdminLogin")
    error_message = "roles/compute.osAdminLogin was dropped in v1 and should not be granted."
  }

  assert {
    condition     = alltrue([for b in google_project_iam_member.operator : b.role != "roles/compute.osAdminLogin"])
    error_message = "No project binding should carry roles/compute.osAdminLogin."
  }
}

run "duplicate_members_do_not_crash" {
  command = plan

  variables {
    operator_members = ["user:a@example.com", "user:a@example.com"]
  }

  # Regression: the map key for the role bindings used to collide on a repeated
  # member, which killed the whole plan with "Duplicate object key". Easy to hit by
  # concatenating a group with someone already in it.
  assert {
    condition     = length(google_service_account_iam_member.operator_act_as) == 1
    error_message = "A repeated member should collapse to a single actAs binding."
  }
}

run "no_operators_grants_nothing" {
  command = plan

  variables {
    operator_members = []
  }

  assert {
    condition     = length(google_project_iam_member.operator) == 0
    error_message = "No members should mean no project bindings."
  }
}

run "firewall_opt_out_withholds_security_admin" {
  command = plan

  variables {
    grant_firewall_management = false
  }

  assert {
    condition     = !contains(local.operator_project_roles, "roles/compute.securityAdmin")
    error_message = "securityAdmin should be withheld when grant_firewall_management is false."
  }
}

run "firewall_default_grants_security_admin" {
  command = plan

  # Not merely ergonomic: the provisioning tooling creates its own per instance
  # rules, so withholding this breaks provisioning rather than removing a nicety.
  assert {
    condition     = contains(local.operator_project_roles, "roles/compute.securityAdmin")
    error_message = "securityAdmin should be granted by default."
  }
}

run "quota_read_role_is_always_granted" {
  command = plan

  # The module enables cloudquotas.googleapis.com. cloudquotas.quotas.get lives in
  # none of the compute roles, so without this an operator gets a live 403.
  assert {
    condition     = contains(local.operator_project_roles, "roles/cloudquotas.viewer")
    error_message = "cloudquotas.viewer must be granted or the enabled quota API cannot be called."
  }
}

run "ssh_firewall_can_be_disabled" {
  command = plan

  variables {
    enable_ssh_firewall = false
  }

  assert {
    condition     = length(google_compute_firewall.iap_ssh) == 0
    error_message = "No firewall rule should be planned when enable_ssh_firewall is false."
  }
}

run "nat_without_region_fails_at_plan" {
  command = plan

  variables {
    enable_nat = true
  }

  # Must fail at plan. Failing at apply would leave the APIs, service account, IAM
  # bindings and firewall rule already created in a half configured project.
  expect_failures = [google_compute_router.gpu_worker]
}

run "nat_with_region_is_clean" {
  command = plan

  variables {
    enable_nat = true
    region     = "us-west1"
  }

  assert {
    condition     = length(google_compute_router_nat.gpu_worker) == 1
    error_message = "NAT should be planned when enable_nat is true and a region is set."
  }
}

run "nat_defaults_to_every_subnet" {
  command = plan

  variables {
    enable_nat = true
    region     = "us-west1"
  }

  assert {
    condition     = google_compute_router_nat.gpu_worker[0].source_subnetwork_ip_ranges_to_nat == "ALL_SUBNETWORKS_ALL_IP_RANGES"
    error_message = "With no nat_subnets, NAT should cover the whole region."
  }
}

run "nat_can_be_scoped_to_subnets" {
  command = plan

  variables {
    enable_nat  = true
    region      = "us-west1"
    nat_subnets = ["worker-subnet"]
  }

  # On an established project, region-wide NAT silently gives outbound internet to
  # existing VMs that deliberately had none.
  assert {
    condition     = google_compute_router_nat.gpu_worker[0].source_subnetwork_ip_ranges_to_nat == "LIST_OF_SUBNETWORKS"
    error_message = "Naming subnets should scope NAT to them."
  }
}

run "additional_nat_regions_get_their_own_nat" {
  command = plan

  variables {
    enable_nat  = true
    region      = "us-west4"
    nat_subnets = ["worker-us-west4"]
    additional_nat_regions = {
      "us-west1"    = ["worker-us-west1"]
      "us-central1" = []
    }
  }

  # The NAT in region keeps its address, so upgrading does not replace the NAT that
  # running workers depend on.
  assert {
    condition     = length(google_compute_router_nat.gpu_worker) == 1 && google_compute_router_nat.gpu_worker[0].region == "us-west4"
    error_message = "Adding regions should leave the NAT in region where it is."
  }

  # Each region takes its own subnets. A subnet from another region fails at apply.
  assert {
    condition     = [for s in google_compute_router_nat.gpu_worker_additional["us-west1"].subnetwork : s.name] == ["worker-us-west1"]
    error_message = "An additional region should be scoped to its own subnets only."
  }

  assert {
    condition     = google_compute_router_nat.gpu_worker_additional["us-central1"].source_subnetwork_ip_ranges_to_nat == "ALL_SUBNETWORKS_ALL_IP_RANGES"
    error_message = "A region with no subnets listed should cover the whole region."
  }

  assert {
    condition     = output.nat_regions == tolist(["us-central1", "us-west1", "us-west4"])
    error_message = "nat_regions should list region and every additional region."
  }
}

run "additional_nat_region_cannot_repeat_region" {
  command = plan

  variables {
    enable_nat             = true
    region                 = "us-west4"
    additional_nat_regions = { "us-west4" = [] }
  }

  # A second router of the same name in the same region plans clean and fails at apply.
  expect_failures = [google_compute_router.gpu_worker_additional]
}

run "static_nat_ips_reserved_in_every_region" {
  command = plan

  variables {
    enable_nat             = true
    region                 = "us-west4"
    nat_static_ip_count    = 1
    additional_nat_regions = { "us-west1" = [] }
  }

  # An allowlist built from nat_ip_addresses would otherwise miss workers outside region.
  assert {
    condition     = length(google_compute_address.nat_additional) == 1 && google_compute_router_nat.gpu_worker_additional["us-west1"].nat_ip_allocate_option == "MANUAL_ONLY"
    error_message = "Each additional region should reserve its own static addresses."
  }
}

run "nat_router_joins_the_created_network" {
  command = plan

  variables {
    network        = null
    create_network = true
    enable_nat     = true
    region         = "us-west1"
  }

  # Regression: the router took var.network, so with a created network NAT landed on
  # the default VPC and the worker had no egress.
  assert {
    condition     = google_compute_router.gpu_worker[0].network == "gpu-worker-vpc"
    error_message = "The NAT router should attach to the network the worker uses."
  }
}

run "network_can_be_created_with_pga" {
  command = plan

  variables {
    create_network = true
    region         = "us-west1"
  }

  assert {
    condition     = google_compute_subnetwork.this[0].private_ip_google_access
    error_message = "A created subnet should have Private Google Access on."
  }
}

run "created_network_without_region_fails_at_plan" {
  command = plan

  variables {
    create_network = true
  }

  expect_failures = [google_compute_subnetwork.this]
}

run "egress_requires_magnopus_addresses" {
  command = plan

  variables {
    manage_egress = true
  }

  # Silently granting no egress would leave a worker that boots and cannot reach us.
  expect_failures = [
    google_compute_firewall.egress_api,
    google_compute_firewall.egress_queue,
  ]
}

run "egress_creates_allow_and_deny" {
  command = plan

  variables {
    manage_egress      = true
    magnopus_api_ips   = ["192.0.2.10/32"]
    magnopus_queue_ips = ["192.0.2.20/32"]
  }

  assert {
    condition     = google_compute_firewall.egress_deny[0].priority == 65534
    error_message = "The deny must sit below the allows so they still match."
  }

  # The queue address must not gain 443, and the API address must not gain AMQP.
  assert {
    condition     = google_compute_firewall.egress_api[0].destination_ranges == toset(["192.0.2.10/32"])
    error_message = "The API rule should only cover the API addresses."
  }

  assert {
    condition     = google_compute_firewall.egress_queue[0].destination_ranges == toset(["192.0.2.20/32"])
    error_message = "The queue rule should only cover the queue addresses."
  }
}

run "static_nat_ips_switch_to_manual" {
  command = plan

  variables {
    enable_nat          = true
    region              = "us-west4"
    nat_static_ip_count = 1
  }

  # Auto-allocated addresses can change under an allowlist.
  assert {
    condition     = google_compute_router_nat.gpu_worker[0].nat_ip_allocate_option == "MANUAL_ONLY"
    error_message = "Reserving NAT addresses should switch NAT to MANUAL_ONLY."
  }

  assert {
    condition     = length(google_compute_address.nat) == 1
    error_message = "One static address should be reserved."
  }
}

run "nat_defaults_to_auto_allocation" {
  command = plan

  variables {
    enable_nat = true
    region     = "us-west4"
  }

  assert {
    condition     = google_compute_router_nat.gpu_worker[0].nat_ip_allocate_option == "AUTO_ONLY"
    error_message = "With no static addresses, NAT should stay AUTO_ONLY."
  }
}
