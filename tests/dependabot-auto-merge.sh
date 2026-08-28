#!/usr/bin/env bash
# SPDX-FileCopyrightText: © Sebastian Thomschke
# SPDX-FileContributor: Sebastian Thomschke (https://sebthom.de/)
# SPDX-License-Identifier: MIT
# SPDX-ArtifactOfProjectHomePage: https://github.com/sebthom/gha-shared
#
# Regression-tests ecosystem normalization, merge eligibility, authentication, trust boundaries, and caller ordering.

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
APP_AUTH_SCRIPT="$TEST_TMP_DIR/app-auth.sh"
MERGE_SCRIPT="$TEST_TMP_DIR/merge.sh"
MOCK_BIN_DIR="$TEST_TMP_DIR/bin"
CALL_LOG="$TEST_TMP_DIR/gh-calls.log"
ECOSYSTEM_OUTPUT="$TEST_TMP_DIR/ecosystem-output.log"
APP_AUTH_OUTPUT="$TEST_TMP_DIR/app-auth-output.log"
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
extract_run_script "Validate GitHub App configuration" "$APP_AUTH_SCRIPT"
extract_run_script "Merge eligible Dependabot PR" "$MERGE_SCRIPT"

# This searches the extracted source for the literal variable reference, not for its current test value.
# shellcheck disable=SC2016
if ! grep -Fq 'pulls/$PR_NUMBER/merge' "$MERGE_SCRIPT"; then
  echo "Could not extract the Dependabot merge script from $WORKFLOW_FILE" >&2
  exit 1
fi

if ! grep -Fq 'GITHUB_APP_CLIENT_ID' "$APP_AUTH_SCRIPT"; then
  echo "Could not extract the GitHub App validation script from $WORKFLOW_FILE" >&2
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
  repos/owner/repo/pulls/42/merge)
    if [[ ${FAIL_REST:-false} == true ]]; then
      exit 3
    fi
    printf '%s\n' "${MERGED_RESULT:-true}"
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

run_app_auth_script() {
  local client_id=${1:-}
  local private_key=${2:-}

  : >"$APP_AUTH_OUTPUT"

  env \
    GITHUB_APP_CLIENT_ID="$client_id" \
    GITHUB_APP_PRIVATE_KEY="$private_key" \
    GITHUB_OUTPUT="$APP_AUTH_OUTPUT" \
    bash -euo pipefail "$APP_AUTH_SCRIPT"
}

run_merge_script() {
  local merge_method=${1:-squash}
  local fail_rest=${2:-false}
  local merged_result=${3:-true}

  : >"$CALL_LOG"

  env \
    PATH="$MOCK_BIN_DIR:$PATH" \
    CALL_LOG="$CALL_LOG" \
    FAIL_REST="$fail_rest" \
    MERGED_RESULT="$merged_result" \
    GH_TOKEN=test-token \
    GITHUB_REPOSITORY=owner/repo \
    PR_NUMBER=42 \
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
actual_eligibility_expression=$(extract_step_if_expression "Merge eligible Dependabot PR")
expected_eligibility_expression="(contains(fromJSON(inputs.package-ecosystems),'*')\
||contains(fromJSON(inputs.package-ecosystems),steps.ECOSYSTEM.outputs.name))\
&&(steps.METADATA.outputs.update-type=='version-update:semver-minor'\
||steps.METADATA.outputs.update-type=='version-update:semver-patch'\
||(inputs.merge-major-updates\
&&steps.METADATA.outputs.update-type=='version-update:semver-major'))"
if [[ $actual_eligibility_expression != "$expected_eligibility_expression" ]]; then
  fail "Dependabot eligibility policy changed unexpectedly: $actual_eligibility_expression"
fi

# Both boundaries are required before the workflow receives a write-capable token.
assert_contains "$WORKFLOW_FILE" "github.event.pull_request.user.login == 'dependabot[bot]'"
assert_contains "$WORKFLOW_FILE" "github.actor == 'dependabot[bot]'"
assert_contains "$WORKFLOW_FILE" "github-app-client-id:"
assert_contains "$WORKFLOW_FILE" "DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY:"
assert_contains "$WORKFLOW_FILE" "uses: actions/create-github-app-token@"
assert_contains "$WORKFLOW_FILE" "permission-contents: write"
# Metadata uses github.token, so the App token needs only the permissions used by the merge operation.
assert_not_contains "$WORKFLOW_FILE" "permission-pull-requests: write"
assert_contains "$WORKFLOW_FILE" "permission-workflows: write"
# Escape '$' because these assertions match literal workflow and embedded-script source.
assert_contains "$WORKFLOW_FILE" "GH_TOKEN: \${{steps.APP_TOKEN.outputs.token || github.token}}"
assert_not_contains "$WORKFLOW_FILE" "actions: write"
assert_not_contains "$WORKFLOW_FILE" "enablePullRequestAutoMerge"
assert_not_contains "$WORKFLOW_FILE" "queue: max"
assert_contains "$WORKFLOW_FILE" "pulls/\$PR_NUMBER/merge"

# Both App values form one optional authentication mode; partial configuration must fail visibly.
run_app_auth_script
assert_contains "$APP_AUTH_OUTPUT" "enabled=false"

run_app_auth_script test-client-id test-private-key
assert_contains "$APP_AUTH_OUTPUT" "enabled=true"

if run_app_auth_script test-client-id >/dev/null 2>&1; then
  fail "Expected App authentication with only a client ID to fail"
fi

if run_app_auth_script "" test-private-key >/dev/null 2>&1; then
  fail "Expected App authentication with only a private key to fail"
fi

# Embedded callers merge only after the complete build succeeds and preserve both bot boundaries.
for caller_workflow_file in "${CALLER_WORKFLOW_FILES[@]}"; do
  extract_caller_job "$caller_workflow_file" dependabot-pr-auto-merge "$CALLER_AUTO_MERGE_JOB_BLOCK"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "needs: build"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "needs.build.result == 'success'"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "github.event_name == 'pull_request'"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "github.event.pull_request.user.login == 'dependabot[bot]'"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "github.actor == 'dependabot[bot]'"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "contents: write"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "pull-requests: write"
  assert_not_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "actions: write"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "uses: ./.github/workflows/reusable.dependabot-auto-merge.yml"
  # Escape '$' so caller expressions are matched literally rather than expanded by this test shell.
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "github-app-client-id: \${{ inputs.dependabot-github-app-client-id }}"
  assert_contains "$CALLER_AUTO_MERGE_JOB_BLOCK" "DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY: \${{ secrets.DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY }}"

  assert_contains "$caller_workflow_file" "dependabot-github-app-client-id:"
  assert_contains "$caller_workflow_file" "DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY:"

  extract_caller_job "$caller_workflow_file" build "$CALLER_BUILD_JOB_BLOCK"
  assert_contains "$CALLER_BUILD_JOB_BLOCK" "needs: [ init ]"
  assert_not_contains "$CALLER_BUILD_JOB_BLOCK" "dependabot-pr-auto-merge"
  assert_not_contains "$CALLER_BUILD_JOB_BLOCK" "if: \${{ !cancelled() && needs.init.result == 'success' }}"
done

run_merge_script squash
assert_contains "$CALL_LOG" "--method PUT"
assert_contains "$CALL_LOG" "repos/owner/repo/pulls/42/merge"
assert_contains "$CALL_LOG" "--raw-field sha=0123456789abcdef"
assert_contains "$CALL_LOG" "--raw-field merge_method=squash"

run_merge_script rebase
assert_contains "$CALL_LOG" "--raw-field merge_method=rebase"

if run_merge_script squash true; then
  fail "Expected a REST merge API failure to propagate"
fi
assert_contains "$CALL_LOG" "repos/owner/repo/pulls/42/merge"

if run_merge_script squash false false; then
  fail "Expected a non-merged REST response to fail"
fi

if run_merge_script merge; then
  fail "Expected an unsupported merge method to fail"
fi
if [[ -s "$CALL_LOG" ]]; then
  fail "An unsupported merge method must fail before calling GitHub"
fi

echo "Dependabot auto-merge regression tests passed."
