# ---------------------------------------------------------------------------
# Operator access
#
# The roles the engineer needs to find GPU capacity, create the VM, get onto it
# and keep it running. Capacity moves between zones and machines are stopped and
# rebuilt regularly, so these are day to day rather than one time.
# ---------------------------------------------------------------------------

locals {
  operator_project_roles = concat(
    [
      # Find a zone with GPU capacity: machine types, accelerator types, quota.
      "roles/compute.viewer",
      # Create, start, stop, delete the VM and its boot disk.
      "roles/compute.instanceAdmin.v1",
      # Use the subnet and an ephemeral external IP.
      "roles/compute.networkUser",
      # SSH with sudo, to install drivers and run the worker stack.
      "roles/compute.osAdminLogin",
      # Reach the VM through Google's IAP tunnel when it has no public IP.
      "roles/iap.tunnelResourceAccessor",
      # Serial console and VM logs when a boot or driver install fails.
      "roles/logging.viewer",
      # VM and GPU metrics.
      "roles/monitoring.viewer",
    ],
    var.grant_firewall_management ? ["roles/compute.securityAdmin"] : [],
  )

  operator_role_bindings = {
    for pair in setproduct(local.operator_project_roles, var.operator_members) :
    "${pair[0]}|${pair[1]}" => {
      role   = pair[0]
      member = pair[1]
    }
  }
}

resource "google_project_iam_member" "operator" {
  for_each = local.operator_role_bindings

  project = var.project_id
  role    = each.value.role
  member  = each.value.member

  depends_on = [google_project_service.this]
}

# Granted on the service account itself rather than the project. Without it the
# operator cannot pass --service-account when creating the VM, and the failure
# is an opaque permission error at create time.
resource "google_service_account_iam_member" "operator_act_as" {
  for_each = toset(var.operator_members)

  service_account_id = google_service_account.gpu_worker.name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}
