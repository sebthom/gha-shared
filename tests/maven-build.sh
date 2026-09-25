#!/usr/bin/env bash
# SPDX-FileCopyrightText: © Sebastian Thomschke
# SPDX-FileContributor: Sebastian Thomschke (https://sebthom.de/)
# SPDX-License-Identifier: MIT
# SPDX-ArtifactOfProjectHomePage: https://github.com/sebthom/gha-shared
#
# Exercises Maven deployment policy, release credential isolation, and artifact ownership without remote services.

set -euo pipefail

REPO_DIR=$(cd "${1:-.}" && pwd)
BUILD_SCRIPT="$REPO_DIR/resources/maven/build.sh"
WORKFLOW_FILE="$REPO_DIR/.github/workflows/reusable.maven-build.yml"
TEST_TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP_DIR"' EXIT
CALL_LOG="$TEST_TMP_DIR/maven.log"
BUILD_OUTPUT="$TEST_TMP_DIR/build.log"

mkdir -p "$TEST_TMP_DIR/bin" "$TEST_TMP_DIR/project"
cat >"$TEST_TMP_DIR/project/pom.xml" <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0"><version>1.2.3-SNAPSHOT</version></project>
EOF

# Stub only external commands; execute the real build/configuration scripts to cover argument propagation.
cat >"$TEST_TMP_DIR/project/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'central=%s\n' "${DEPLOY_RELEASES_TO_MAVEN_CENTRAL:-unset}" >"$CALL_LOG"
printf 'arg=%s\n' "$@" >>"$CALL_LOG"
echo '[INFO] Mock Maven invocation'
exit "${MOCK_MAVEN_EXIT:-0}"
EOF

cat >"$TEST_TMP_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  branch) echo main ;;
  config) ;; # GitHub Actions sets the release author; never change the developer's Git configuration.
  *) echo "Unexpected Git command: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$TEST_TMP_DIR/bin/git" "$TEST_TMP_DIR/project/mvnw"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "Expected '$2' in $1"
}

assert_not_contains() {
  if grep -Fq -- "$2" "$1"; then
    fail "Did not expect '$2' in $1"
  fi
}

run_build() {
  local can_release=$1
  local deploy=$2
  local release_version=$3
  local on_actions=${4:-false}
  cat >"$TEST_TMP_DIR/release-trigger.sh" <<EOF
POM_CURRENT_VERSION="$release_version"
POM_RELEASE_VERSION="1.2.3"
SKIP_TESTS=false
DRY_RUN=false
EOF
  (
    cd "$TEST_TMP_DIR/project"
    # Do not depend on or print a developer's Maven JVM settings, which can contain local credentials.
    env -u MAVEN_SETTINGS_FILE -u MAVEN_TOOLCHAINS_FILE -u DEPLOY_RELEASES_TO_MAVEN_CENTRAL \
      PATH="$TEST_TMP_DIR/bin:$PATH" \
      CALL_LOG="$CALL_LOG" \
      MAVEN_VERSION=mvnw \
      MAVEN_OPTS='' \
      MAVEN_DEPLOY="$deploy" \
      CAN_CREATE_RELEASE="$can_release" \
      RELEASE_TRIGGER_FILE="$TEST_TMP_DIR/release-trigger.sh" \
      GITHUB_ACTIONS="$on_actions" \
      GITHUB_ENV="$TEST_TMP_DIR/github-env" \
      SNAPSHOTS_BRANCH=test-snapshots \
      JAVADOC_BRANCH=test-javadoc \
      bash "$BUILD_SCRIPT" -Dcaller.option=kept
  ) >"$BUILD_OUTPUT" 2>&1 || {
    local result=$?
    cat "$BUILD_OUTPUT" >&2
    return "$result"
  }
}

# Turning publishing off must also bypass branch publication, even on an eligible Actions run.
run_build true false disabled
assert_contains "$CALL_LOG" 'arg=verify'
assert_not_contains "$CALL_LOG" 'arg=deploy'
assert_contains "$CALL_LOG" 'arg=-Dcaller.option=kept'
run_build true false disabled true
assert_contains "$CALL_LOG" 'arg=verify'

# Omitted deployment policy preserves the existing deploy default; PRs never deploy.
run_build true '' disabled
assert_contains "$CALL_LOG" 'arg=deploy'
run_build false true 1.2.3-SNAPSHOT
assert_contains "$CALL_LOG" 'arg=verify'
assert_not_contains "$CALL_LOG" 'arg=release:perform'

# A version/tag release is still allowed without publication. The skip must reach forked Maven.
run_build true false 1.2.3-SNAPSHOT
assert_contains "$CALL_LOG" 'central=false'
assert_contains "$CALL_LOG" 'arg=release:perform'
# Perform defaults to "deploy site-deploy" when a site is configured; a deploy-plugin skip is insufficient.
assert_contains "$CALL_LOG" 'arg=-Dgoals=install'
grep -F -- 'arg=-Darguments=' "$CALL_LOG" | grep -Fq -- '-Dmaven.deploy.skip=true' \
  || fail 'Deployment skip did not reach forked Maven'

run_build true true 1.2.3-SNAPSHOT
assert_contains "$CALL_LOG" 'central=true'
assert_contains "$CALL_LOG" 'arg=release:perform'
# Publishing builds must retain the caller's configured release goals, including site deployment.
assert_not_contains "$CALL_LOG" 'arg=-Dgoals='
assert_not_contains "$CALL_LOG" '-Dmaven.deploy.skip=true'

export MOCK_MAVEN_EXIT=42
if run_build true false disabled >"$TEST_TMP_DIR/expected-failure.log" 2>&1; then
  fail 'A failed Maven invocation must fail the build'
else
  result=$?
  [[ $result == 42 ]] || fail "Expected Maven exit code 42, got $result"
fi
unset MOCK_MAVEN_EXIT

# Extract the real matrix builder, as the existing routing tests do for embedded workflow scripts.
awk '
  /\r$/ { sub(/\r$/, "") }
  $0 == "    - name: Parse inputs" { found_step = 1; next }
  found_step && $0 == "      run: |" { in_run = 1; next }
  in_run && ($0 == "" || $0 ~ /^        /) { sub(/^        /, ""); print; next }
  in_run { exit }
' "$WORKFLOW_FILE" >"$TEST_TMP_DIR/matrix.py"

run_matrix() {
  : >"$TEST_TMP_DIR/matrix-output"
  env \
    RUNS_ON=ubuntu-latest,windows-latest \
    COMPILE_JDK=temurin@17 \
    TEST_JDKS=temurin@21 \
    MAVEN_JDK=temurin@25 \
    MAVEN_VERSIONS=mvnw,3.9.9 \
    ON_DEV_BRANCH="$1" \
    DISABLE_RELEASES=false \
    CODECOV_TOKEN='' \
    BUILD_ARTIFACT_NAME="${2:-build-artifacts}" \
    BUILD_ARTIFACT_PATHS=target/example.jar \
    GITHUB_WORKFLOW=tests \
    GITHUB_OUTPUT="$TEST_TMP_DIR/matrix-output" \
    python "$TEST_TMP_DIR/matrix.py" >"$TEST_TMP_DIR/matrix.log" 2>&1
}

# Both release and PR matrices must upload once, regardless of extra runners, Maven versions, or test JDKs.
for on_dev_branch in true false; do
  run_matrix "$on_dev_branch"
  python - "$TEST_TMP_DIR/matrix-output" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as output:
    matrix = json.loads(output.read().removeprefix("MATRIX="))
owners = [entry for entry in matrix if entry["UPLOAD_BUILD_ARTIFACT"]]
assert len(owners) == 1, owners
owner = owners[0]
assert owner["RUNS_ON"] == "ubuntu-latest", owner
assert owner["MAVEN_VERSION"] == "mvnw", owner
assert owner["TEST_JDK_VERSION"] == "17", owner
PY
done

# The uploader trims inputs, including UTF-8 BOMs, before coverage cleanup sees the artifact name.
for artifact_name in coverage-build ' coverage-build ' $'\tcoverage-build\r\n' $'\357\273\277 coverage-build'; do
  if run_matrix false "$artifact_name"; then
    fail "Build artifacts must not use the coverage cleanup namespace: [$artifact_name]"
  fi
  assert_contains "$TEST_TMP_DIR/matrix.log" "reserved for coverage"
done
run_matrix false ' build-artifacts '

# Checkout persists an authorization header that takes precedence over Maven's URL credentials.
# Evaluate the actual checkout input so a correct Maven environment alone cannot satisfy this test.
python - "$WORKFLOW_FILE" <<'PY'
import re, sys
from pathlib import Path
from types import SimpleNamespace

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
build_job = re.search(r"(?ms)^  build:\n(.*?)(?=^  [\w-]+:|\Z)", workflow).group(1)
checkout = re.search(r"(?ms)^    - name: Git Checkout\n(.*?)(?=^    - name:|\Z)", build_job).group(1)
token_input = re.search(r"(?m)^        token:\s*\$\{\{(.+?)\}\}\s*$", checkout)
expression = token_input.group(1).strip() if token_input else "github.token"
# This bounded expression uses only context reads and boolean operators. For these boolean and
# string fixtures, Python's operators preserve the same short-circuit and fallback semantics.
assert re.fullmatch(r"[\w.\s()&|!]+", expression), expression
expression = expression.replace("&&", " and ").replace("||", " or ").replace("!", " not ")
for can_release, act, release_token, expected in (
    (True,  "",     "release-token", "release-token"),
    (True,  "",     "",              "builtin-token"),
    (False, "",     "release-token", "builtin-token"),
    (False, "",     "",              "builtin-token"),
    (True,  "true", "release-token", "builtin-token"),
    (False, "true", "release-token", "builtin-token"),
):
    context = {
        "matrix": SimpleNamespace(CAN_CREATE_RELEASE=can_release),
        "env": SimpleNamespace(ACT=act),
        "secrets": SimpleNamespace(RELEASE_TOKEN=release_token, GITHUB_TOKEN="builtin-token"),
        "github": SimpleNamespace(token="builtin-token"),
    }
    actual = eval(expression, {"__builtins__": {}}, context)
    assert actual == expected, (can_release, act, release_token, actual, expected)
PY

echo 'Maven build regression tests passed.'
