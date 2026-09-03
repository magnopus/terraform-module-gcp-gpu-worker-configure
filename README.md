# terraform-module-gcp-gpu-worker-configure

Prepares an existing GCP project to host a **GPU worker**: a VM running GPU
inference containers that pull jobs from a remote queue and write results back.
This module configures the project, it never creates it.

What it configures:

- **APIs** — `compute`, `iap` and `cloudquotas`. IAP is what allows SSH without
  giving the VM a public IP.
- **Runtime service account** — the identity the GPU VM runs as, instead of the
  default compute service account. It is granted nothing in this project by
  design.
- **Operator access** — the IAM roles an engineer needs to find GPU capacity,
  create the VM, connect to it and keep it running. Listed in full below.
- **Inbound SSH rule** (optional) — scoped to Google's IAP forwarding range and
  the worker's network tag. The only inbound rule needed.
- **Cloud NAT** (optional) — outbound access for VMs with no external IP.

## Usage

```hcl
module "gpu_worker_project" {
  source = "github.com/magnopus/terraform-module-gcp-gpu-worker-configure?ref=v1.0.0"

  project_id       = "acme-gpu-prod"
  operator_members = ["group:gpu-operators@example.com"]

  # Only required when the VM will have no external IP.
  enable_nat = true
  region     = "us-west1"
}
```

Then send the outputs back to whoever is provisioning:

```bash
terraform output
```

## Access granted

All are granted at project level to every member of `operator_members`, except
`roles/iam.serviceAccountUser`, which is granted on the runtime service account
only and is therefore much narrower than it looks.

| Role | Why |
|---|---|
| `roles/compute.viewer` | Read machine types, accelerator types, zones and quota, to find a zone with GPU capacity |
| `roles/compute.instanceAdmin.v1` | Create, start, stop and delete the VM and its boot disk |
| `roles/compute.networkUser` | Use the subnet and an ephemeral external IP |
| `roles/compute.osAdminLogin` | SSH with sudo, to install drivers and run the worker stack |
| `roles/iap.tunnelResourceAccessor` | Reach the VM through Google's IAP tunnel |
| `roles/logging.viewer` | Serial console and VM logs when a boot or driver install fails |
| `roles/monitoring.viewer` | VM and GPU metrics |
| `roles/compute.securityAdmin` | Adjust the SSH rule without a change request. Optional, see `grant_firewall_management` |
| `roles/iam.serviceAccountUser` | Attach the runtime service account when creating the VM. Granted on the service account, not the project |

These are used day to day rather than once. GPU VMs are stopped when idle to
avoid cost, restarted on demand, and rebuilt when capacity moves to a different
zone or a new worker image ships.

`roles/compute.securityAdmin` is the broadest of these, and GCP cannot scope
firewall permissions to a single rule, so it covers all firewalls in the
project. Set `grant_firewall_management = false` if you would rather own the
SSH rule yourself.

## Prerequisites this module cannot cover

**GPU quota.** New projects start at zero for the cards used here. Request
`GPUS_PER_GPU_FAMILY` with dimension `gpu_family: NVIDIA_RTX_PRO_6000`,
8 per region across the US regions you expect to use. These cards are not
generally available, so the quota is granted per project by a Google
representative rather than self serve, and it does not carry across projects in
the same organisation. This has the longest lead time of anything here, so start
it before running this module.

**Org policy.** Two constraints block provisioning and cannot be worked around
with IAM:

| Constraint | Effect if enforced |
|---|---|
| `compute.trustedImageProjects` | The VM boots a Deep Learning VM image and will not start unless `projects/deeplearning-platform-release` is allowlisted |
| `compute.vmExternalIpAccess` | The VM cannot have an external IP, so `enable_nat` must be true |

**Outbound network access.** The worker needs outbound HTTPS to the job queue
(AMQPS 5671), the job API, `*.googleapis.com` for model weights and storage, and
the container registry. First boot additionally reaches `get.docker.com`,
`download.docker.com`, `nvidia.github.io`, `packages.cloud.google.com` and the
Ubuntu package mirrors. Private Google Access on the subnet covers the Google
destinations without traversing the public internet.

Two grants also sit outside this module because they are not project scoped:
`roles/billing.viewer` on the billing account, which is optional and gives cost
visibility, and `roles/compute.osLoginExternalUser` at organisation level, which
is required when the operator identity sits outside your organisation. Without
the latter, SSH fails with an error that does not explain why.
