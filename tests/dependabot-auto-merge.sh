#!/usr/bin/env bash
# SPDX-FileCopyrightText: © Sebastian Thomschke
# SPDX-FileContributor: Sebastian Thomschke (https://sebthom.de/)
# SPDX-License-Identifier: MIT
# SPDX-ArtifactOfProjectHomePage: https://github.com/sebthom/gha-shared
#
# Regression-tests eligibility normalization and native auto-merge registration contracts.

set -euo pipefail

WORKFLOW_FILE=${1:-.github/workflows/reusable.dependabot-auto-merge.yml}
CALLER_WORKFLOW_FILES=(
  .github/workflows/reusable.maven-build.yml
  .github/workflows/reusable.eclipse-plugin-build.yml
  .github/workflows/reusable.eclipse-product-build.yml
)
TEST_TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP_DIR"' EXIT

ECOSYSTEM_SCRIPT="$TEST_TMP_DIR/ecosystem.sh"
MERGE_SCRIPT="$TEST_TMP_DIR/merge.sh"
MOCK_BIN_DIR="$TEST_TMP_DIR/bin"
CALL_LOG="$TEST_TMP_DIR/gh-calls.log"
ECOSYSTEM_OUTPUT="$TEST_TMP_DIR/ecosystem-output.log"
CALLER_AUTO_MERGE_JOB_BLOCK="$TEST_TMP_DIR/caller-auto-merge-job.yml"
CALLER_BUILD_JOB_BLOCK="$TEST_TMP_DIR/caller-build-job.yml"

# Exercise the workflow's actual shell block so the test cannot drift into validating a separate implementation.
extract_run_script() {
  local step_name=$1
  local output_file=$2

  awk -v step_name="$step_name" '
    /\r$/ { sub(/\r$/, "") }
    $0 == "    - name: " step_name { found_step = 1; next }
    found_step && $0 == "      run: |" { in_run = 1; next }
    in_run && ($0 == "" || $0 ~ /^        /) {
      sub(/^        /, "")
      print
      next
    }
    in_run { exit }
  ' "$WORKFLOW_FILE" >"$output_file"
}

# Ignore YAML line wrapping so the contract assertion changes only when the expression tokens change.
extract_step_if_expression() {
  local step_name=$1

  awk -v step_name="$step_name" '
    /\r$/ { sub(/\r$/, "") }
    $0 == "    - name: " step_name { found_step = 1; next }
    found_step && $0 == "      if: >-" { in_if = 1; next }
    in_if && $0 ~ /^        / {
      sub(/^        /, "")
      if ($0 == "${{" || $0 == "}}") next
      gsub(/[[:space:]]/, "")
      printf "%s", $0
      next
    }
    in_if { exit }
  ' "$WORKFLOW_FILE"
}

extract_run_script "Normalize Dependabot package ecosystem" "$ECOSYSTEM_SCRIPT"
extract_run_script "Enable auto-merge for eligible Dependabot PR" "$MERGE_SCRIPT"

# This searches the extracted source for the literal variable reference, not for its current test value.
# shellcheck disable=SC2016
if ! grep -Fq 'enablePullRequestAutoMerge' "$MERGE_SCRIPT"; then
  echo "Could not extract the Dependabot merge script from $WORKFLOW_FILE" >&2
  exit 1
fi

if ! grep -Fq 'RAW_PACKAGE_ECOSYSTEM' "$ECOSYSTEM_SCRIPT"; then
  echo "Could not extract the package ecosystem normalization script from $WORKFLOW_FILE" >&2
  exit 1
fi

mkdir -p "$MOCK_BIN_DIR"
cat >"$MOCK_BIN_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$CALL_LOG"

if [[ $1 != api ]]; then
  echo "Unexpected gh command: $*" >&2
  exit 2
fi

api_endpoint=
for argument in "$@"; do
  case "$argument" in
    graphql | repos/*)
      api_endpoint=$argument
      break
      ;;
  esac
done

case "$api_endpoint" in
  graphql)
    if [[ ${FAIL_GRAPHQL:-false} == true ]]; then
      exit 3
    fi
    ;;
  *)
    echo "Unexpected gh API call: $*" >&2
    exit 4
    ;;
esac
EOF
chmod +x "$MOCK_BIN_DIR/gh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || fail "Expected '$expected' in $file"
}

assert_not_contains() {
  local file=$1
  local unexpected=$2
  if grep -Fq -- "$unexpected" "$file"; then
    fail "Did not expect '$unexpected' in $file"
  fi
}

run_ecosystem_script() {
  local raw_package_ecosystem=$1

  : >"$ECOSYSTEM_OUTPUT"
  env \
    RAW_PACKAGE_ECOSYSTEM="$raw_package_ecosystem" \
    GITHUB_OUTPUT="$ECOSYSTEM_OUTPUT" \
    bash -euo pipefail "$ECOSYSTEM_SCRIPT"
}

assert_ecosystem_mapping() {
  local raw_package_ecosystem=$1
  local expected_package_ecosystem=$2

  run_ecosystem_script "$raw_package_ecosystem"
  assert_contains "$ECOSYSTEM_OUTPUT" "name=$expected_package_ecosystem"
}

extract_caller_job() {
  local caller_workflow_file=$1
  local job_name=$2
  local output_file=$3

  awk -v job_name="$job_name" '
    /\r$/ { sub(/\r$/, "") }
    $0 == "  " job_name ":" { in_job = 1 }
    in_job && $0 != "  " job_name ":" && $0 ~ /^  [[:alnum:]_-]+:/ { exit }
    in_job { print }
  ' "$caller_workflow_file" >"$output_file"
}

run_merge_script() {
  local merge_method=${1:-squash}
  local fail_graphql=${2:-false}

  : >"$CALL_LOG"

  env \
    PATH="$MOCK_BIN_DIR:$PATH" \
    CALL_LOG="$CALL_LOG" \
    FAIL_GRAPHQL="$fail_graphql" \
    GITHUB_TOKEN=test-token \
    PR_NODE_ID=PR_node_id \
    PR_HEAD_SHA=0123456789abcdef \
    MERGE_METHOD="$merge_method" \
    bash -euo pipefail "$MERGE_SCRIPT"
}

# Dependabot branch prefixes use internal package-manager slugs; callers use dependabot.yml ecosystem names.
assert_ecosystem_mapping docker_compose docker-compose
assert_ecosystem_mapping dotnet_sdk dotnet-sdk
assert_ecosystem_mapping git_submodules gitsubmodule
assert_ecosystem_mapping github_actions github-actions
assert_ecosystem_mapping go_modules gomod
assert_ecosystem_mapping hex mix
assert_ecosystem_mapping npm_and_yarn npm
assert_ecosystem_mapping pre_commit pre-commit
assert_ecosystem_mapping rust_toolchain rust-toolchain
assert_ecosystem_mapping maven maven

# Lock the complete eligibility policy so an operator change cannot silently broaden Dependabot auto-merge.
actual_eligibility_expression=$(extract_step_if_expression "Enable auto-merge for eligible Dependabot PR")
expected_eligibility_expression="(contains(fromJSON(inputs.package-ecosystems),'*')"\
"||contains(fromJSON(inputs.package-ecosystems),steps.ECOSYSTEM.outputs.name))"\
"&&(steps.METADATA.outputs.update-type=='version-update:semver-minor'"\
"||steps.METADATA.outputs.update-type=='version-update:semver-patch'"\
"||(inputs.merge-major-updates"\
"&&steps.METADATA.outputs.update-type=='version-update:semver-major'))"
if [[ $actual_eligibility_expression != "$expected_eligibility_expression" ]]; then
  fail "Dependabot eligibility policy changed unexpectedly: $actual_eligibility_expression"
fi

# Embedded callers require successful initialization and prefilter unrelated events.
# The nested job repeats author filtering because standalone callers do not have that outer boundary.
assert_contains "$WORKFLOW_FILE" "github.event.pull_request.user.login == 'dependabot[bot]'"
# Keep the undocumented workflow-file registration workaround at both reusable-workflow permission boundaries.
assert_contains "$WORKFLOW_FILE" "actions: write"
for caller_workflow_file in "${CALLER_WORKFLOW_FILES[@]}"; do
  extract_caller_job "$caller_workflow_file" dependabot-pr-auto-merge "$CALLER_AUTO_MERGE_JOB_BLOCK"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "needs: init"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "needs.init.result == 'success'"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "github.event_name == 'pull_request'"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "github.event.pull_request.user.login == 'dependabot[bot]'"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "actions: write"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "uses: ./.github/workflows/reusable.dependabot-auto-merge.yml"
  assert_not_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "github-app"
  assert_not_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "GITHUB_APP"

  extract_caller_job "$caller_workflow_file" build "$CALLER_BUILD_JOB_BLOCK"
  assert_contains "$CALLER_BUILD_JOB_BLOCK" "needs: [ init, dependabot-pr-auto-merge ]"
  assert_contains "$CALLER_BUILD_JOB_BLOCK" "if: \${{ !cancelled() && needs.init.result == 'success' }}"
done

# Native registration is the only merge path; missing branch requirements must fail instead of falling back.
assert_contains "$WORKFLOW_FILE" "enablePullRequestAutoMerge"
assert_not_contains "$WORKFLOW_FILE" "create-github-app-token"
assert_not_contains "$WORKFLOW_FILE" "queue: max"
assert_not_contains "$WORKFLOW_FILE" 'pulls/$PR_NUMBER/merge'

run_merge_script squash
assert_contains "$CALL_LOG" "graphql"
assert_contains "$CALL_LOG" "--raw-field pullRequestId=PR_node_id"
assert_contains "$CALL_LOG" "--raw-field mergeMethod=SQUASH"
assert_contains "$CALL_LOG" "--raw-field expectedHeadOid=0123456789abcdef"

run_merge_script rebase
assert_contains "$CALL_LOG" "--raw-field mergeMethod=REBASE"

if run_merge_script squash true; then
  fail "Expected native auto-merge registration to fail"
fi
assert_contains "$CALL_LOG" "graphql"

if run_merge_script merge; then
  fail "Expected an unsupported merge method to fail"
fi
if [[ -s "$CALL_LOG" ]]; then
  fail "An unsupported merge method must fail before calling GitHub"
fi

echo "Dependabot auto-merge regression tests passed."
