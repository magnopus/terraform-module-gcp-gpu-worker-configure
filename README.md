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
terraform output -json
```

Use `-json` rather than plain `terraform output`. When `enable_nat` is false the
region is null, which the human-readable form prints as `tostring(null)` and reads
like a fault rather than "NAT is disabled".

### Inputs

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `project_id` | yes | | The project to configure. Never created by this module |
| `operator_members` | yes | | Who gets access. `user:`, `group:` or `serviceAccount:`. A group is preferred so staffing changes need no further Terraform run here |
| `network` | no | `default` | VPC the worker attaches to. See the ingress section below before accepting the default |
| `region` | no | `null` | Region for Cloud NAT. Required when `enable_nat` is true |
| `enable_nat` | no | `false` | Create Cloud Router and NAT. Needed when the VM has no external IP |
| `enable_ssh_firewall` | no | `true` | Create the IAP SSH ingress rule |
| `grant_firewall_management` | no | `true` | Grant `securityAdmin`. Setting false will break provisioning, see the access table |
| `service_account_id` | no | `gpu-worker` | Account ID for the VM's runtime identity |
| `network_tag` | no | `gpu-worker` | Tag the worker VM must carry for the SSH rule to match |
| `enabled_apis` | no | 4 APIs | Override only if your project restricts API enablement |

### Outputs, and what each is for

Send all of these back. They are what the provisioning side needs to create the VM.

| Output | Used for |
|---|---|
| `project_id` | Target project for the VM |
| `service_account_email` | Passed to `--service-account` at VM create. The worker runs as this identity |
| `network` | VPC the VM attaches to |
| `network_tag` | Tag applied to the VM so the SSH rule matches it |
| `region` | NAT region. Null when `enable_nat` is false, meaning any region with quota can be used |
| `nat_enabled` | False means the VM needs an external IP to reach the internet |
| `ssh_firewall_rule` | Name of the ingress rule, or null when the project owner owns it |
| `firewall_management_granted` | Whether ingress can be adjusted without a change request |
| `granted_roles` | The roles actually granted, for review |

### Wait a minute before provisioning

IAM changes take up to a minute to propagate. Applying and then immediately handing
the outputs to the provisioning tooling can produce a spurious 403 on a correctly
configured project. Measured at roughly 40 seconds for the quota read to start
working after a clean apply.

This matters because the symptom is not a clean error. A 403 on the quota check makes
the provisioner fall back to scanning every region, so the run appears to work while
behaving as though the project has no quota. On a first run, retry a 403 before
treating it as a permissions problem.

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
| `roles/cloudquotas.viewer` | Read GPU quota. Newer cards report through the Cloud Quotas API rather than the legacy per region metrics |
| `roles/compute.securityAdmin` | The provisioning tooling creates a firewall rule per worker, so this is required for provisioning rather than a convenience. See `grant_firewall_management` |
| `roles/iam.serviceAccountUser` | Attach the runtime service account when creating the VM. Granted on the service account, not the project |

These are used day to day rather than once. GPU VMs are stopped when idle to
avoid cost, restarted on demand, and rebuilt when capacity moves to a different
zone or a new worker image ships.

`roles/compute.securityAdmin` is the broadest of these, and GCP cannot scope
firewall permissions to a single rule, so it covers all firewalls in the
project. Setting `grant_firewall_management = false` will make provisioning fail. A non-owner
operator is denied `compute.firewalls.create` partway through, which is a permission
error midway rather than a clean refusal up front. Only set it false if the project
owner is creating ingress rules for each worker by hand.

## The runtime service account is the only one to grant actAs on

The operators receive `roles/iam.serviceAccountUser` on the service account this
module creates, and on nothing else. That is deliberate and should not be widened.

In particular, do not grant it on the project's **default compute service account**.
That account carries `roles/editor` on virtually every GCP project, so combining it
with `compute.instanceAdmin.v1` and VM startup scripts amounts to arbitrary code
execution as Editor across the whole project. It would also contradict this document,
which describes a small set of narrowly scoped roles.

If provisioning fails with "The user does not have access to service account", the
cause is that the VM is being created without `--service-account` and is falling back
to the default compute account. The fix is to attach the runtime account from
`service_account_email`, not to widen the grant.

## Changes that need coordinating with the provisioning tooling

Some changes here are correct in isolation but break provisioning unless the tooling
changes at the same time. Sequence these deliberately.

| Change | Why it breaks | Land with |
|---|---|---|
| `service_account_id` default | Tooling that reconstructs the account email rather than reading `service_account_email` will point at an account that no longer exists, and every VM create fails | Tooling switching to the output, or both together |
| `network_tag` default | The tag on created VMs stops matching this module's firewall rule, quietly leaving the rule dead | Tooling switching to the output, or both together |
| Enabling OS Login | SSH currently works through instance metadata keys. Turning OS Login on disables that path | The tooling adopting OS Login at the same time |

Changing `service_account_id` on an **existing** project is a breaking change rather
than a cosmetic one. The account email is derived from it, so a re-apply creates a new
account rather than renaming the old. Any grants made elsewhere against the old email
keep pointing at the old account, which still exists.

## Check existing ingress on the network you supply

GCP firewall rules are additive. Priority only arbitrates between allow and deny,
so a narrow allow rule does **not** override a broad one. Both simply apply.

This matters because GCP's auto-created `default` VPC ships with
`default-allow-ssh`, which permits `0.0.0.0/0` to tcp:22 with no target tags. On a
project using that network, a worker with an external IP is reachable over SSH from
the internet, regardless of the tag-scoped IAP rule this module creates. Verified on
a fresh project: enabling the compute API created the default VPC with that rule at
priority 65534, alongside this module's rule at priority 1000. The lower number looks
like it wins. It does not, because both are allow rules.

Before applying, audit ingress on whichever network you pass:

```bash
gcloud compute firewall-rules list --project=PROJECT_ID \
  --filter="direction=INGRESS AND sourceRanges:0.0.0.0/0" \
  --format="table(name,network,priority,allowed[].map().firewall_rule().list(),targetTags.list())"
```

On a stock default network the two rules to remove are `default-allow-ssh` and
`default-allow-rdp`:

```bash
gcloud compute firewall-rules delete default-allow-ssh default-allow-rdp \
  --project=PROJECT_ID
```

That leaves `default-allow-icmp` and `default-allow-internal`, which are ping and
intra-VPC traffic, and this module's own tag-scoped IAP rule. Verified on a real
project: afterwards nothing reaches tcp:22 from the internet, the worker is still
reachable over the IAP tunnel, and egress is unaffected.

Removing them does not fight Terraform. Those rules were created by GCP rather than
by this module, so they are not in state and a later `apply` will not recreate them.

The alternative is to give the worker no external IP at all, which makes any
pre-existing ingress unreachable regardless. That is the stronger option and needs
`enable_nat = true` so the VM can still reach the internet.

## Prerequisites this module cannot cover

**GPU quota.** New projects start at zero for the cards used here. Request
`GPUS_PER_GPU_FAMILY` with dimension `gpu_family: NVIDIA_RTX_PRO_6000`,
8 per region across the US regions you expect to use. These cards are not
generally available, so the quota is granted per project by a Google
representative rather than self serve, and it does not carry across projects in
the same organisation. This has the longest lead time of anything here, so start
it before running this module.

Through the Cloud Quotas API the same quota appears as:

```
quotaId  GPUS-PER-GPU-FAMILY-per-project-region
metric   compute.googleapis.com/gpus_per_gpu_family
```

The `gpu_family` dimension enumerates even on a project with no allocation, so the
card can be confirmed as recognised before any quota is granted. Note an unallocated
family returns **null** rather than 0, so anything checking for zero needs to treat
null as unallocated or the comparison will not behave.

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
Ubuntu package mirrors.

**The worker needs an egress path and this module does not create one by default.**
`enable_nat` is false unless you set it. A VM with no external IP and no NAT has no
outbound route at all, and because IAP still gives you a shell, the symptom is a box
you can log into that cannot download anything. Pick one deliberately:

| Egress | What to set | Trade-off |
|---|---|---|
| Cloud NAT | `enable_nat = true` and a `region` | Bills hourly. Required for any worker without an external IP |
| External IP | Leave `enable_nat = false` | Free, but read the ingress section first: on a stock VPC the worker becomes SSH reachable from the internet |

Private Google Access is worth enabling on the subnet, but it is **not** a substitute
for NAT and this module neither enables nor checks it. Auto-created subnets ship with
it disabled. It also only covers Google destinations, and most of the first-boot list
above is not Google, so a worker without an external IP still needs NAT to build
itself even with PGA on.

Two grants also sit outside this module because they are not project scoped:
`roles/billing.viewer` on the billing account, which is optional and gives cost
visibility, and `roles/compute.osLoginExternalUser` at organisation level, which
is required when the operator identity sits outside your organisation. Without
the latter, SSH fails with an error that does not explain why.
