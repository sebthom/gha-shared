#!/usr/bin/env bash
# SPDX-FileCopyrightText: © Sebastian Thomschke
# SPDX-FileContributor: Sebastian Thomschke (https://sebthom.de/)
# SPDX-License-Identifier: MIT
# SPDX-ArtifactOfProjectHomePage: https://github.com/sebthom/gha-shared
#
# Tests Eclipse release token selection and shared API/Git authentication without external services.

set -euo pipefail

python - "$@" <<'PY'
import base64
import http.server
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace as Namespace

repo = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
base_env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
for name in list(base_env):
    if name == "GIT_CONFIG_COUNT" or name.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")):
        del base_env[name]


def run(args, cwd, env=None, check=True):
    result = subprocess.run(args, cwd=cwd, env=dict(base_env, **(env or {})),
                            text=True, capture_output=True, timeout=30)
    if check and result.returncode:
        raise AssertionError(f"{args[0]} failed ({result.returncode}): {result.stdout}\n{result.stderr}")
    return result


def step_blocks(source):
    return re.findall(r"(?ms)^    - name: ([^\n]+)\n(.*?)(?=^    - name:|^  [\w-]+:|\Z)", source)


def block_for(blocks, prefix):
    return next(body for name, body in blocks if name.strip('"').startswith(prefix))


def run_script(block, indent):
    lines = block.split("run: |\n", 1)[1].splitlines()
    body = []
    for line in lines:
        if line and not line.startswith(" " * indent):
            break
        body.append(line[indent:])
    return "\n".join(body)


def expression(block, key):
    value = re.search(r"(?m)^\s+" + re.escape(key) + r":\s*(.+?)\s*$", block).group(1)
    return re.sub(r"^\x24\{\{\s*|\s*\}\}$", "", value)


def evaluate(value, **contexts):
    # Only the bounded boolean/context expressions below are evaluated, as in maven-build.sh.
    assert re.fullmatch(r"[\w.\s()&|!=']+", value), value
    return eval(value.replace("&&", " and ").replace("||", " or "), {"__builtins__": {}}, contexts)


with tempfile.TemporaryDirectory(prefix="eclipse-release-auth-") as temp:
    scratch = Path(temp)
    for kind in ("plugin", "product"):
        workflow = (repo / f".github/workflows/reusable.eclipse-{kind}-build.yml").read_text(encoding="utf-8")
        build = re.search(r"(?ms)^  build:\n(.*?)(?=^  [\w-]+:|\Z)", workflow).group(1)
        blocks = step_blocks(build)
        validation = block_for(blocks, "Validate release GitHub App configuration")
        mint = block_for(blocks, "Create release GitHub App token")
        cleanup = block_for(blocks, "Cleanup previous")
        create = block_for(blocks, "Create '")
        deploy = block_for(blocks, "Deploy p2 update site")
        assert "git-token:" not in cleanup, "Cleanup must use only github-token"

        assert workflow.index("Build with Maven") < workflow.index("Create release GitHub App token")
        assert workflow.index("Create release GitHub App token") < workflow.index('name: "Cleanup previous')
        assert re.search(r"release-github-app-client-id:\n.*\n\s+default: \"\"", workflow)
        assert re.search(r"RELEASE_GITHUB_APP_PRIVATE_KEY:\n.*\n\s+required: false", workflow)
        assert "permission-contents: write" in mint and "permission-workflows: write" in mint
        assert not re.search(r"^\s+(owner|repositories|continue-on-error):", mint, re.MULTILINE)

        for release_name, expected in (("", False), ("preview", True), ("stable", True)):
            assert bool(evaluate(expression(validation, "if"), matrix=Namespace(RELEASE_NAME=release_name))) == expected

        for client_id, private_key, enabled in (("", "", "false"), ("client", "private", "true"),
                                                ("client", "", None), ("", "private", None)):
            output = scratch / "auth-output"
            output.write_text("", encoding="utf-8")
            result = run(["bash", "-c", run_script(validation, 8)], scratch, {
                "GITHUB_APP_CLIENT_ID": client_id, "GITHUB_APP_PRIVATE_KEY": private_key,
                "GITHUB_OUTPUT": str(output),
            }, check=False)
            if enabled is None:
                assert result.returncode != 0 and "must be configured together" in result.stderr
                assert not output.read_text(), "Partial credentials must not silently select the built-in token"
            else:
                assert result.returncode == 0
                assert output.read_text().strip() == f"enabled={enabled}"
                contexts = {"steps": Namespace(RELEASE_APP_AUTH=Namespace(outputs=Namespace(enabled=enabled)))}
                assert bool(evaluate(expression(mint, "if"), **contexts)) == (enabled == "true")

        for token in ("", "release-token"):
            contexts = {
                "steps": Namespace(RELEASE_APP_TOKEN=Namespace(outputs=Namespace(token=token))),
                "secrets": Namespace(GITHUB_TOKEN="builtin-token"),
            }
            for block, key in ((cleanup, "github-token"), (create, "GITHUB_TOKEN"), (deploy, "GITHUB_TOKEN")):
                assert evaluate(expression(block, key), **contexts) == (token or "builtin-token")
        for name, body in blocks:
            if "Cache:" in name:
                assert "RELEASE_APP_TOKEN" not in body, "Release tokens do not have Actions permission"

    action = (repo / ".github/actions/cleanup-release/action.yml").read_text(encoding="utf-8")
    assert "git-token:" not in action, "Cleanup must expose one token for API and Git operations"
    assert expression(action, "GITHUB_TOKEN") == "inputs.github-token"
    script = run_script(action, 6)
    helper = re.search(r"(?ms)^git_remote\(\) \{.*?^\}", script).group(0)

    # Exercise real Git against loopback HTTP, including the saved header used by actions/checkout.
    # A 404 is intentional: no repository service is needed to observe which credentials Git sent.
    received = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            received.append(self.headers.get_all("Authorization"))
            self.send_error(404)

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        origin = f"http://127.0.0.1:{server.server_port}"
        http_repo = scratch / "http"
        http_repo.mkdir()
        run(["git", "init", "-q"], http_repo)
        run(["git", "remote", "add", "origin", origin + "/owner/repo"], http_repo)
        auth_config = scratch / "checkout-auth.config"
        checkout_auth = base64.b64encode(b"x-access-token:checkout-token").decode()
        run(["git", "config", "--file", str(auth_config), f"http.{origin}/.extraheader",
             "AUTHORIZATION: basic " + checkout_auth], http_repo)
        run(["git", "config", "include.path", str(auth_config)], http_repo)
        saved_config = (http_repo / ".git/config").read_bytes()
        saved_auth = auth_config.read_bytes()
        # Both release paths must use the selected API token even when checkout saved a different token.
        for token in ("builtin-token", "release-token"):
            expected = base64.b64encode(f"x-access-token:{token}".encode()).decode()
            received.clear()
            result = run(["bash", "-c", helper + "\ngit_remote ls-remote origin"], http_repo,
                         {"GITHUB_TOKEN": token, "GITHUB_SERVER_URL": origin}, check=False)
            assert result.returncode != 0, "The fixture always responds with HTTP 404"
            assert received == [["basic " + expected]], received
            assert (http_repo / ".git/config").read_bytes() == saved_config
            assert auth_config.read_bytes() == saved_auth, "Release credentials must not persist in checkout config"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()

    # Run the full cleanup script against disposable local repositories. Only GitHub CLI calls are stubbed.
    remote = scratch / "remote.git"
    project = scratch / "project"
    project.mkdir()
    run(["git", "init", "--bare", "-q", str(remote)], scratch)
    run(["git", "init", "-q"], project)
    run(["git", "remote", "add", "origin", str(remote)], project)
    run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
         "commit", "--allow-empty", "-qm", "old"], project)
    old_sha = run(["git", "rev-parse", "HEAD"], project).stdout.strip()
    run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
         "commit", "--allow-empty", "-qm", "new"], project)
    new_sha = run(["git", "rev-parse", "HEAD"], project).stdout.strip()
    archive = "stable.2025-12-07_22-01-44"
    calls = scratch / "gh-calls"

    def reset_stable():
        run(["git", "tag", "-f", "stable", old_sha], project)
        run(["git", "push", "-q", "--force", "origin", "refs/tags/stable"], project)
        calls.write_text("", encoding="utf-8")

    gh_stub = r'''
gh() {
  printf '%s\n' "$*" >>"$CALL_LOG"
  case "$*" in
    'release view stable --json publishedAt --jq .publishedAt') echo 2025-12-07T22:01:44Z ;;
    'release edit stable --tag stable.2025-12-07_22-01-44 --title stable.2025-12-07_22-01-44') ;;
    *) echo "Unexpected GitHub CLI call" >&2; return 98 ;;
  esac
}
'''
    release_env = {
        "RELEASE_NAME": "stable", "STABLE_RELEASE_NAME": "stable", "GITHUB_SHA": new_sha,
        "GITHUB_SERVER_URL": "https://github.com", "CALL_LOG": str(calls),
    }
    for token in ("builtin-token", "release-token"):
        reset_stable()
        run(["bash", "-c", gh_stub + script], project, dict(release_env, GITHUB_TOKEN=token))
        assert run(["git", "--git-dir", str(remote), "rev-parse", "refs/tags/" + archive], scratch).stdout.strip() == old_sha
        assert run(["git", "--git-dir", str(remote), "show-ref", "--verify", "refs/tags/stable"],
                   scratch, check=False).returncode != 0
        assert "release edit stable" in calls.read_text()

    # An unsuccessful archive push must stop before editing the old release or deleting its stable tag.
    reset_stable()
    failing_git = r'''
git() {
  for argument in "$@"; do
    if [[ "$argument" == "refs/tags/stable.2025-12-07_22-01-44" ]]; then
      echo "Simulated archive push rejection" >&2
      return 42
    fi
  done
  command git "$@"
}
'''
    result = run(["bash", "-c", gh_stub + failing_git + script], project, dict(release_env, GITHUB_TOKEN="release-token"),
                 check=False)
    assert result.returncode == 42, result.stderr
    assert "release edit" not in calls.read_text()
    assert run(["git", "--git-dir", str(remote), "rev-parse", "refs/tags/stable"], scratch).stdout.strip() == old_sha

print("Eclipse release authentication tests passed.")
PY
