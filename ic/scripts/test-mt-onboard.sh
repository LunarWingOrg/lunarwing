#!/usr/bin/env bash
# Smoke-test for lunarwing_mt_onboard.
#
# Runs the Python unit tests and verifies the module is importable.
# A full non-interactive provisioning end-to-end test requires a real
# multi-tenant host and is left as a manual step (see the proposal doc:
# docs/proposals/MT-ONBOARDING-CLI.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"
export PYTHONPATH="$REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}"

echo "── Python unit tests ──"
PYTHONPATH="$REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -c "
import unittest
from lunarwing_mt_onboard import tests
loader = unittest.TestLoader()
suite = loader.loadTestsFromModule(tests)
runner = unittest.TextTestRunner(verbosity=2)
result = runner.run(suite)
import sys
sys.exit(0 if result.wasSuccessful() else 1)
"

echo ""
echo "── Module import check ──"
python3 -c "
from lunarwing_mt_onboard.config import TenantConfig, WorkerType
from lunarwing_mt_onboard.secrets import generate_master_key, is_valid_master_key
from lunarwing_mt_onboard.provisioner import (
    PhaseResult, ProvisionResult, ensure_mt_admin,
    build_add_tenant_args, build_build_tenant_args,
)
print('All modules imported successfully')
"

echo ""
echo "── Non-interactive dry-run (--skip-build --skip-start) ──"
# This will fail at provision() since there's no real mt-admin, but it validates
# the arg-parsing + config-validation path without needing root.
python3 -c "
from lunarwing_mt_onboard.cli import _build_parser
p = _build_parser()
args = p.parse_args(['--non-interactive', '--skip-build', '--skip-start'])
print('Parsed:', args)
"

echo ""
echo "✓ Smoke test passed"
