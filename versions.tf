terraform {
  required_providers {
    # To check for an upgrade: <https://github.com/hashicorp/terraform-provider-google/releases>
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
  # To check for an upgrade: <https://www.terraform.io/downloads.html> release notes: <https://github.com/hashicorp/terraform/releases>
  required_version = "~> 1.0"
}
