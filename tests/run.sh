#!/usr/bin/env bash
# Offline regression tests. No GCP access, nothing created, safe in CI.
#
# Every resource here is a create, so plan never reads real state and the provider
# never authenticates. The fake key just lets it configure.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export GOOGLE_CREDENTIALS="$PWD/tests/fake-credentials.json"
export GOOGLE_PROJECT="test-project"
terraform init -backend=false -input=false >/dev/null
terraform test "$@"
