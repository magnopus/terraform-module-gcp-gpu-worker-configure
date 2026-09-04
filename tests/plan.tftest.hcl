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
}

run "single_operator" {
  command = plan
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
