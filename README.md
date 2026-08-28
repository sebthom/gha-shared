# gha-shared

[![License](https://img.shields.io/github/license/sebthom/gha-shared.svg?color=blue)](LICENSE.txt)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-v2.1%20adopted-ff69b4.svg)](CODE_OF_CONDUCT.md)

1. [What is it?](#what-is-it)
1. [Reusable Workflows](#reusable-workflows)
   1. [Dependabot Auto-Merge](#reusable-workflow-dependabot-auto-merge)
   1. [Maven Build](#reusable-workflow-maven-build)
   1. [Eclipse Plugin Build](#reusable-workflow-eclipse-plugin-build)
   1. [Eclipse Product Build](#reusable-workflow-eclipse-product-build)
1. [Shared Actions](#shared-actions)
   1. [Build Release Notes](#shared-action-build-release-notes)
   1. [Cleanup Release](#shared-action-cleanup-release)
   1. [Stale](#shared-action-stale)
1. [License](#license)


## <a name="what-is-it"></a>What is it?

A collection of reusable GitHub Actions **workflows** and **composite actions**.

These components help standardize CI/CD pipelines across multiple repositories by centralizing common build, test, and deployment logic.


## <a name="reusable-workflows"></a>Reusable Workflows

| Workflow Name         | Path                                                   | Description
| ----------------------| ------------------------------------------------------ | -----------
| Dependabot Auto-Merge | `.github/workflows/reusable.dependabot-auto-merge.yml` | Merges eligible Dependabot pull requests after validation, with optional GitHub App authentication.
| Maven Build           | `.github/workflows/reusable.maven-build.yml`           | Builds, tests, and releases Maven projects with multi-JDK matrix. Includes Dependabot auto-merge.
| Eclipse Plugin Build  | `.github/workflows/reusable.eclipse-plugin-build.yml`  | Builds, tests, and releases Eclipse plugins. Includes Dependabot auto-merge.
| Eclipse Product Build | `.github/workflows/reusable.eclipse-product-build.yml` | Builds, tests, and releases Eclipse products. Includes Dependabot auto-merge.


### <a name="reusable-workflow-dependabot-auto-merge"></a>Reusable Workflow: Dependabot Auto-Merge

Use the **Dependabot Auto-Merge** workflow after the caller's validation job.
The caller must include the `pull_request` event.
The workflow accepts only Dependabot-initiated events for pull requests authored by Dependabot and skips all other
events.
Minor and patch updates are eligible by default, while major updates are opt-in.
The merge request is pinned to the validated pull request head SHA.
Repository auto-merge and branch protection are not required.

The built-in `github.token` remains the credential-free default.
However, it cannot reliably merge concurrent Dependabot pull requests that both modify `.github/workflows/**`.
Configure the optional GitHub App credentials when these workflow-file updates must merge without manual recovery.

#### Example

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - name: Build and test
      run: |
        # Fail safely until this placeholder is replaced with the project's validation commands.
        echo "Replace this placeholder with the project's build and test commands." >&2
        exit 1

  dependabot-auto-merge:
    # A failed or skipped build must never reach the merge workflow.
    needs: build
    # Check both the actor and PR author so this write-capable job only runs for Dependabot updates.
    if: >-
      needs.build.result == 'success' &&
      github.event_name == 'pull_request' &&
      github.actor == 'dependabot[bot]' &&
      github.event.pull_request.user.login == 'dependabot[bot]'
    permissions:
      contents: write
      pull-requests: write
    uses: sebthom/gha-shared/.github/workflows/reusable.dependabot-auto-merge.yml@v1
    # All inputs are optional. These values restrict merges to GitHub Actions updates.
    with:
      package-ecosystems: '["github-actions"]'
      merge-method: squash
      merge-major-updates: false
      # Optional permission-complete path for concurrent workflow-file updates:
      # github-app-client-id: ${{ vars.DEPENDABOT_MERGE_GITHUB_APP_CLIENT_ID }}
    # Omit this block when using the built-in github.token.
    # secrets:
    #   DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY: ${{ secrets.DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY }}
```

#### Inputs

| Name                   | Type | Default  | Description
| ---------------------- | ---- | -------- | -----------
| `package-ecosystems`   | str  | `["*"]`  | JSON array of Dependabot ecosystems eligible for merging. Use `["*"]` for all ecosystems or `[]` for none.
| `merge-method`         | str  | `squash` | Merge method for eligible Dependabot PRs. Supported values are `squash` and `rebase`.
| `merge-major-updates`  | bool | `false`  | Whether major Dependabot updates are eligible for merging. Minor and patch updates remain eligible by default.
| `github-app-client-id` | str  | -        | Optional GitHub App client ID. It must be supplied together with `DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY`.

#### Secrets

| Name                                      | Description
| ----------------------------------------- | -----------
| `DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY` | Optional GitHub App private key. Store it as a Dependabot secret and supply it together with `github-app-client-id`.

#### Caller Configuration

Make the merge job depend on every job that must succeed before the pull request is merged.
A dependency on a matrix job waits for all matrix cells, so no branch-rule status-check configuration is needed.
Keep validation and merging in the same workflow dependency graph so `needs` provides the ordering guarantee.

The calling job must grant these permissions for the built-in-token path:

```yaml
permissions:
  contents: write
  pull-requests: write
```

By default, every Dependabot package ecosystem is eligible.
Set `package-ecosystems` only when you want an allowlist.
Use the `package-ecosystem` names from `.github/dependabot.yml`, for example:

```yaml
with:
  package-ecosystems: '["github-actions","maven"]'
```

Always use the public names accepted in `.github/dependabot.yml`.
For example, use `github-actions`, `npm`, `gomod`, and `mix` rather than the internal names
`github_actions`, `npm_and_yarn`, `go_modules`, and `hex` returned by the metadata action.
The workflow translates these internal names before applying the allowlist.

#### Repository Configuration

Enable the merge method selected by `merge-method` under **Settings > General > Pull Requests**.
No other repository setting is required by this workflow.
In particular, **Allow auto-merge**, branch protection, rulesets, and required status checks are unnecessary unless
the repository uses them for reasons unrelated to Dependabot.
Existing branch rules still apply and can reject the direct merge after validation.
Protected branches are supported, but the workflow makes one merge request and does not wait for unmet branch
requirements.
Required checks and approvals must already be complete, and any requirement that the branch be up to date must be
satisfied when the merge job runs.
Otherwise, the merge fails and leaves the pull request open.
Make a standalone merge job depend on every required validation job in the same workflow.
The embedded Maven and Eclipse workflows wait for their build matrix only, so required checks from other workflows
must finish before the merge job runs or the failed merge job must be rerun afterward.
The optional GitHub App follows the same branch rules unless the App is explicitly configured as a bypass actor.

#### Optional GitHub App Authentication

The GitHub App is optional for ordinary dependency updates.
It is the permission-complete path for repositories that need concurrent Dependabot workflow-file updates to merge
without manual recovery.

1. Create a GitHub App with repository permissions **Contents: Read and write** and
   **Workflows: Read and write**.
1. Install the App on each repository that will use it.
1. Store its client ID in a repository variable such as `DEPENDABOT_MERGE_GITHUB_APP_CLIENT_ID`.
1. Store its private key as a repository or organization **Dependabot secret** named
   `DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY`.
   An Actions secret with the same name is not available to a Dependabot-triggered `pull_request` workflow.
1. Pass the variable and secret as shown in the commented lines of the example.

Both values must be present or both must be omitted.
The workflow fails explicitly on partial App configuration.
The generated installation token is scoped to the current repository, requests only the two permissions above,
and is revoked when the merge job ends.

The private key must only be passed to a trusted published revision of this reusable workflow, such as the `@v1`
reference shown above or an immutable commit SHA.
Do not pass it to a same-repository `./.github/workflows/...` workflow selected by a pull request commit.
GitHub resolves a local reusable workflow from the same commit as its caller, which would expand the private key's
trust boundary to pull request code.
The workflow also requires both `github.actor` and the pull request author to be Dependabot before the secret-bearing
job can run.
A manual rerun keeps the original actor, while a human-generated pull request event is skipped.

See [GitHub's App permission documentation](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
and [Dependabot secret documentation](https://docs.github.com/en/code-security/reference/secret-security/secret-types#dependabot-secrets).

#### Blocking Issue: Concurrent Workflow-File Updates

The recurring platform limitation across the evaluated designs is specific and important:
**two or more concurrent Dependabot pull requests modify files under `.github/workflows/**`.**

The first pull request can merge successfully with the built-in token.
After it changes the target branch, GitHub may treat the next merge as creating or updating the combined workflow
file and reject the `github-actions[bot]` token because that token has no **Workflows** repository permission:

```text
auto-merge was automatically disabled
Tried to create or update workflow without `workflows` permission
```

This happened when
[`docker-graalvm-maven#63`](https://github.com/vegardit/docker-graalvm-maven/pull/63) merged while
[`docker-graalvm-maven#60`](https://github.com/vegardit/docker-graalvm-maven/pull/60) was also passing CI.
Native auto-merge did not fix the problem: registration succeeded for both PRs, but GitHub disabled auto-merge for
the remaining PR after the first workflow update reached the target branch.
`workflows: write` is not a valid job `permissions` key for the built-in `github.token`.
`actions: write` is a different permission and does not authorize workflow-file changes.
The optional App supplies the separate **Workflows: write** repository permission through its installation token.

Without App credentials, recover by commenting `@dependabot rebase` on the remaining PR.
The resulting force-push reruns validation and makes another merge attempt against the updated target branch.
With App credentials, the merge request uses a short-lived token that explicitly has **Workflows: write**.

#### Credential-Free Mitigation

If GitHub App credentials are not available, serialize GitHub Actions version updates in `.github/dependabot.yml`:

```yaml
version: 2
updates:
- package-ecosystem: github-actions
  directory: /
  schedule:
    interval: daily
  open-pull-requests-limit: 1
```

`open-pull-requests-limit: 1` allows only one open version-update pull request for this update entry.
The `daily` schedule checks for updates every weekday, so the next waiting version update can be opened on a later
scheduled run after the current pull request is merged or closed.
These settings reduce overlapping workflow-file updates but do not give the built-in token **Workflows: write**.
They also do not limit security-update pull requests, so overlap can still occur.
An unresolved version-update pull request delays later version updates for this entry.
If overlap still occurs, use the `@dependabot rebase` recovery described above or configure the GitHub App.

*For implementation details, see
[.github/workflows/reusable.dependabot-auto-merge.yml](.github/workflows/reusable.dependabot-auto-merge.yml).
For evaluated alternatives and observed failures, see
[.github/workflows/reusable.dependabot-auto-merge.md](.github/workflows/reusable.dependabot-auto-merge.md).*


### <a name="reusable-workflow-maven-build"></a>Reusable Workflow: Maven Build

To use the **Maven Build** workflow, reference its YAML file in your repository's workflow definition.
This workflow includes [Dependabot Auto-Merge](#reusable-workflow-dependabot-auto-merge) for eligible
Dependabot pull requests after the build succeeds.
Its embedded auto-merge call is limited to the `maven` and `github-actions` package ecosystems.
Use the standalone workflow for any additional ecosystems.
The built-in token is used by default.
Configure the optional GitHub App credentials described above when concurrent Dependabot workflow-file updates
must merge without manual recovery.

#### Example

```yaml
name: Maven CI
on:
  push:
    branches-ignore:  # build all branches except:
    - 'dependabot/**'  # prevent GHA triggered twice (once for commit to the branch and once for opening/syncing the PR)
    tags-ignore:  # don't build tags
    - '**'
  pull_request:
  workflow_dispatch:
    # https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#workflow_dispatch
    inputs:
      debug-with-ssh:
        description: "Start an SSH session for debugging purposes at the end of the build:"
        default: never
        type: choice
        options: [ always, on_failure, on_failure_or_cancelled, never ]
      debug-with-ssh-only-for-actor:
        description: "Restrict SSH debug session access to the GitHub user who triggered the workflow"
        default: true
        type: boolean

jobs:
  build:
    uses: sebthom/gha-shared/.github/workflows/reusable.maven-build.yml@v1
    with:
      runs-on: ubuntu-latest,macos-latest!,windows-latest
      compile-jdk: 17
      test-jdks: 11,17,21,24!

      maven-jdk: 21
      maven-versions: |
        3.8.4
        4.0.0-rc-2!
        mvnw

      javadoc-branch: gh-pages
      snapshots-branch: mvn-snapshots

      before-build: |
        if [[ $OSTYPE == linux* ]] && ! hash ping &>/dev/null; then
          (set -x; sudo apt-get install iputils-ping)
        fi

      debug-logging: false
      debug-with-ssh: ${{ inputs.debug-with-ssh }}
      debug-with-ssh-only-for-actor: ${{ inputs.debug-with-ssh-only-for-actor }}
      debug-with-ssh-only-jobs-matching: ${{ inputs.debug-with-ssh-only-jobs-matching }}

      # Optional permission-complete path for concurrent workflow-file updates:
      # dependabot-github-app-client-id: ${{ vars.DEPENDABOT_MERGE_GITHUB_APP_CLIENT_ID }}

    secrets:
      SONATYPE_CENTRAL_USER:  ${{ secrets.SONATYPE_CENTRAL_USER }}
      SONATYPE_CENTRAL_TOKEN: ${{ secrets.SONATYPE_CENTRAL_TOKEN }}
      GPG_SIGN_KEY:           ${{ secrets.GPG_SIGN_KEY }}
      GPG_SIGN_KEY_PWD:       ${{ secrets.GPG_SIGN_KEY_PWD }}
      CODECOV_TOKEN:          ${{ secrets.CODECOV_TOKEN }}
      # DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY: ${{ secrets.DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY }}

    permissions:
      actions: write        # to delete action cache entries
      contents: write       # to create releases (commit to dev branch, create tags)
      pull-requests: write  # for dependabot PR auto merges
```

#### Inputs

| Name                                | Type | Default                  | Description
| ----------------------------------- | ---- | ------------------------ | -----------
|**Runner:**
| `runs-on`                           | str  | `ubuntu-latest`          | A comma- or newline-separated list of GitHub Actions runner labels (e.g. `ubuntu-latest,windows-latest`). Append `!` to any label to allow its job to fail without failing the overall workflow (e.g. `windows-latest!`).    |
| `timeout-minutes`                   | int  | `30`                     | Maximum runtime (in minutes) for each job before GitHub cancels it.
|**Dependabot:**
| `dependabot-merge-method`           | str  | `squash`                 | Merge method for eligible Dependabot PRs. Supported values are `squash` and `rebase`.
| `dependabot-merge-major-updates`    | bool | `false`                  | Whether major Dependabot updates are eligible for merging. Minor and patch updates remain eligible by default.
| `dependabot-github-app-client-id`   | str  | -                        | Optional GitHub App client ID. It must be supplied together with `DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY`.
|**Java:**
| `compile-jdk`                       | str  | -                        | **REQUIRED** The JDK for compilation, either a major version (e.g. `11`, `17`) or vendor-qualified (`temurin@11`).
| `test-jdks`                         | str  | -                        | A comma- or newline-separated list of additional JDKs to run unit tests against (e.g. `11,17` or `temurin@11`). Append `!` to allow failures for that JDK (e.g. `17!`).
| **Maven:**
| `maven-jdk`                         | str  | `temurin@25`             | The JDK used to run Maven itself, by major version or with vendor (e.g. `17` or `temurin@17`).
| `maven-versions`                    | str  | -                        | A comma- or newline-separated list of Maven runtimes (e.g. `latest,3.6.1,mvnw`). Use `mvnw` to invoke `./mvnw`; otherwise specify a version or `latest`. Append `!` to allow failures (e.g. `3.6.3!`).
| `extra-maven-args`                  | str  | -                        | Additional command-line flags to append to every Maven invocation (e.g. `-DskipTests`).
| `maven-settings-file`               | str  | -                        | Path to a custom Maven `settings.xml`. If unset, the workflow uses [resources/maven/settings.xml](resources/maven/settings.xml)).
| **Deployment:**
| `development-branch`                | str  | `main`                   | Long-lived development branch that serves as the source for cutting Maven releases and publishing SNAPSHOT version (e.g., 'main' or 'develop').
| `release-trigger-file`              | str  | `.ci/release-trigger.sh` | Path to a shell script that defines variables evaluated by the workflow to decide whether to perform an automatic Maven release. Defines `POM_CURRENT_VERSION`, `POM_RELEASE_VERSION`, `DRY_RUN`, and `SKIP_TESTS`. When on `development-branch` and versions match, a release is cut automatically.
| `javadoc-branch`                    | str  | -                        | Branch where generated Javadoc HTML is published (e.g. `gh-pages`). Omit or leave blank to skip Javadoc deployment.
| `snapshots-branch`                  | str  | -                        | Branch to which SNAPSHOT artifacts are deployed (e.g. `mvn-snapshots`). Omit or leave blank to skip snapshot publishing.
| **Hooks:**
| `before-build`                      | str  | -                        | Bash commands to run **before** the Maven build starts.
| `after-build`                       | str  | -                        | Bash commands to run **after** the Maven build completes.
|**Debugging:**
| `debug-logging`                     | bool | `false`                  | Print diagnostic context, matrix, outputs, and environment details to job logs.
| `debug-with-ssh`                    | str  | `never`                  | When to open an SSH session for post-build debugging: `always`, `on_failure`, `on_failure_or_cancelled`, or `never`.
| `debug-with-ssh-only-for-actor`     | bool | `true`                   | Restrict SSH debug session access to the GitHub user who triggered the workflow.
| `debug-with-ssh-only-jobs-matching` | str  | `.*`                     | Only start SSH session for jobs matching this regex pattern.

#### Secrets

| Name                     | Description
| ------------------------ | -----------
| `SONATYPE_CENTRAL_USER`  | Sonatype Central username (required for publishing releases to Maven Central).
| `SONATYPE_CENTRAL_TOKEN` | Sonatype Central API token (required for publishing releases to Maven Central).
| `GPG_SIGN_KEY`           | Base64-encoded GPG private key for signing release artifacts.
| `GPG_SIGN_KEY_PWD`       | Passphrase for the GPG signing keys.
| `CODECOV_TOKEN`          | Codecov upload token for publishing test coverage reports.
| `DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY` | Optional GitHub App private key. Store it as a Dependabot secret and supply it together with `dependabot-github-app-client-id`.

*For full details, see the [.github/workflows/reusable.maven-build.yml](.github/workflows/reusable.maven-build.yml)*


### <a name="reusable-workflow-eclipse-plugin-build"></a>Reusable Workflow: Eclipse Plugin Build

To use the **Eclipse Plugin Build** workflow, reference its YAML file in your repository's workflow definition.
This workflow includes [Dependabot Auto-Merge](#reusable-workflow-dependabot-auto-merge) for eligible
Dependabot pull requests after the build succeeds.
Its embedded auto-merge call is limited to the `maven` and `github-actions` package ecosystems.
Use the standalone workflow for any additional ecosystems.
The built-in token is used by default.
Configure the optional GitHub App credentials described above when concurrent Dependabot workflow-file updates
must merge without manual recovery.

#### Example

```yaml
name: Maven CI
on:
  push:
    branches-ignore:  # build all branches except:
    - 'dependabot/**'  # prevent GHA triggered twice (once for commit to the branch and once for opening/syncing the PR)
    tags-ignore:  # don't build tags
    - '**'
  pull_request:
  workflow_dispatch:
    # https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#workflow_dispatch
    inputs:
      debug-with-ssh:
        description: "Start an SSH session for debugging purposes at the end of the build:"
        default: never
        type: choice
        options: [ always, on_failure, on_failure_or_cancelled, never ]
      debug-with-ssh-only-for-actor:
        description: "Restrict SSH debug session access to the GitHub user who triggered the workflow"
        default: true
        type: boolean

jobs:
  build:
    uses: sebthom/gha-shared/.github/workflows/reusable.eclipse-plugin-build.yml@v1
    with:
      timeout-minutes: 30

      target-files: |
        target-platforms/oldest.target
        target-platforms/latest.target
        target-platforms/unstable.target!

      development-branch: main
      development-updatesite-branch: updatesite-preview
      release-branch: release
      release-updatesite-branch: updatesite
      release-archive-name: org.haxe4e.plugin.updatesite.zip

      debug-logging: false
      debug-with-ssh: ${{ inputs.debug-with-ssh }}
      debug-with-ssh-only-for-actor: ${{ inputs.debug-with-ssh-only-for-actor }}
      debug-with-ssh-only-jobs-matching: ${{ inputs.debug-with-ssh-only-jobs-matching }}

      # Optional permission-complete path for concurrent workflow-file updates:
      # dependabot-github-app-client-id: ${{ vars.DEPENDABOT_MERGE_GITHUB_APP_CLIENT_ID }}

    # Omit this block when using the built-in github.token.
    # secrets:
    #   DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY: ${{ secrets.DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY }}

    permissions:
      actions: write       # to delete action cache entries
      contents: write      # to create releases (commit to updatesite branches)
      pull-requests: write # for dependabot auto merges
```

#### Dependabot Inputs

| Name                                      | Type | Default  | Description
| ----------------------------------------- | ---- | -------- | -----------
| `dependabot-merge-method`                 | str  | `squash` | Merge method for eligible Dependabot PRs. Supported values are `squash` and `rebase`.
| `dependabot-merge-major-updates`          | bool | `false`  | Whether major Dependabot updates are eligible for merging. Minor and patch updates remain eligible by default.
| `dependabot-github-app-client-id`         | str  | -        | Optional GitHub App client ID. It must be supplied together with `DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY`.

#### Dependabot Secrets

| Name                                      | Description
| ----------------------------------------- | -----------
| `DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY` | Optional GitHub App private key. Store it as a Dependabot secret and supply it together with `dependabot-github-app-client-id`.

*For full details, see the [.github/workflows/reusable.eclipse-plugin-build.yml](.github/workflows/reusable.eclipse-plugin-build.yml)*


### <a name="reusable-workflow-eclipse-product-build"></a>Reusable Workflow: Eclipse Product Build

To use the **Eclipse Product Build** workflow, reference its YAML file in your repository's workflow definition.
This workflow includes [Dependabot Auto-Merge](#reusable-workflow-dependabot-auto-merge) for eligible
Dependabot pull requests after the build succeeds.
Its embedded auto-merge call is limited to the `maven` and `github-actions` package ecosystems.
Use the standalone workflow for any additional ecosystems.
The built-in token is used by default.
Configure the optional GitHub App credentials described above when concurrent Dependabot workflow-file updates
must merge without manual recovery.

#### Example

```yaml
name: Maven CI
on:
  push:
    branches-ignore:  # build all branches except:
    - 'dependabot/**'  # prevent GHA triggered twice (once for commit to the branch and once for opening/syncing the PR)
    tags-ignore:  # don't build tags
    - '**'
  pull_request:
  workflow_dispatch:
    # https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#workflow_dispatch
    inputs:
      debug-with-ssh:
        description: "Start an SSH session for debugging purposes at the end of the build:"
        default: never
        type: choice
        options: [ always, on_failure, on_failure_or_cancelled, never ]
      debug-with-ssh-only-for-actor:
        description: "Restrict SSH debug session access to the GitHub user who triggered the workflow"
        default: true
        type: boolean

jobs:
  build:
    uses: sebthom/gha-shared/.github/workflows/reusable.eclipse-product-build.yml@v1
    with:
      timeout-minutes: 30

      product-files: product/haxe-studio.product
      target-files: build.target

      development-branch: main
      development-updatesite-branch: updatesite-preview
      release-branch: release
      release-updatesite-branch: updatesite

      debug-logging: false
      debug-with-ssh: ${{ inputs.debug-with-ssh }}
      debug-with-ssh-only-for-actor: ${{ inputs.debug-with-ssh-only-for-actor }}
      debug-with-ssh-only-jobs-matching: ${{ inputs.debug-with-ssh-only-jobs-matching }}

      # Optional permission-complete path for concurrent workflow-file updates:
      # dependabot-github-app-client-id: ${{ vars.DEPENDABOT_MERGE_GITHUB_APP_CLIENT_ID }}

    # Omit this block when using the built-in github.token.
    # secrets:
    #   DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY: ${{ secrets.DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY }}

    permissions:
      actions: write       # to delete action cache entries
      contents: write      # to create releases (commit to updatesite branches)
      pull-requests: write # for dependabot auto merges
```

#### Dependabot Inputs

| Name                                      | Type | Default  | Description
| ----------------------------------------- | ---- | -------- | -----------
| `dependabot-merge-method`                 | str  | `squash` | Merge method for eligible Dependabot PRs. Supported values are `squash` and `rebase`.
| `dependabot-merge-major-updates`          | bool | `false`  | Whether major Dependabot updates are eligible for merging. Minor and patch updates remain eligible by default.
| `dependabot-github-app-client-id`         | str  | -        | Optional GitHub App client ID. It must be supplied together with `DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY`.

#### Dependabot Secrets

| Name                                      | Description
| ----------------------------------------- | -----------
| `DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY` | Optional GitHub App private key. Store it as a Dependabot secret and supply it together with `dependabot-github-app-client-id`.

*For full details, see the [.github/workflows/reusable.eclipse-product-build.yml](.github/workflows/reusable.eclipse-product-build.yml)*


## <a name="shared-actions"></a>Shared Actions

| Action Name           | Path                                             | Description
| ----------------------| -------------------------------------------------| -----------
| `build-release-notes` | `.github/actions/build-release-notes/action.yml` | Builds GitHub release notes from commits (preview vs stable aware).
| `cleanup-release`     | `.github/actions/cleanup-release/action.yml`     | Deletes or archives the previous release (stable-aware) before creating a new one.
| `stale`               | `.github/actions/stale/action.yaml`              | Marks dormant issues as stale

### <a name="shared-action-build-release-notes"></a>Shared Action: Build Release Notes

A composite action that builds GitHub release notes from commits between a baseline release and the current commit.
It is aware of preview vs stable releases, so preview release notes can be generated relative to the latest stable release.

Behavior:
1. Fetches enough history (for shallow checkouts) for the current branch and configured preview/stable tags.
1. Determines the base commit:
   - For the configured preview release name (default `preview`): uses the target commit of the configured stable release (default `stable`).
   - For any other release name (e.g. `stable`): uses the previous release with the same tag name.
   - If no suitable baseline release exists, falls back to the last 50 commits.
1. Groups commits into sections based on their Conventional Commit-style prefix:
   - `feat(...)` → **Features**
   - `fix(...)` (excluding `fix(deps):`) → **Fixes**
   - `fix(deps):` → **Dependency updates**
   - everything else → **Other changes**
1. Enriches entries with GitHub logins (e.g. `(@user)`) when resolvable via the GitHub API.

#### Example

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 1 # not strictly required; the action will fetch what it needs

      - name: Build release notes from commits
        id: release_notes
        uses: sebthom/gha-shared/.github/actions/build-release-notes@v1
        with:
          release-name: preview
          github-token: ${{ secrets.GITHUB_TOKEN }}
          # optional overrides (defaults shown):
          # preview-release-name: preview
          # stable-release-name: stable

      - name: Create GitHub release
        env:
          RELEASE_NOTES_FILE: ${{ steps.release_notes.outputs.release-notes-file }}
        run: |
          gh release create "preview" \
            --title "preview" \
            --prerelease \
            --notes-file "$RELEASE_NOTES_FILE" \
            --target "${GITHUB_SHA}"
```

#### Inputs

| Input Name            | Type   | Default               | Description
| --------------------- | ------ | --------------------- | -----------
| `release-name`        | string | -                     | **Required.** Name of the release/tag being created (e.g. `preview`, `stable`, or any other tag).
| `github-token`        | string | `${{ github.token }}` | Token used for GitHub API calls (`gh api`).
| `preview-release-name`| string | `preview`             | Tag name that identifies preview releases; used to decide when to diff against the stable baseline.
| `stable-release-name` | string | `stable`              | Tag name that identifies the stable baseline release used for preview diffs.

#### Outputs

| Output Name         | Description
| ------------------- | -----------
| `release-notes-file`| Path to the generated release notes file (Markdown), suitable for `gh release create --notes-file`.

*For full details, see the [.github/actions/build-release-notes/action.yml](.github/actions/build-release-notes/action.yml)*

### <a name="shared-action-cleanup-release"></a>Shared Action: Cleanup Release

A composite action that deletes or archives an existing release before creating a new one.

Behavior:
1. If `release-name != stable-release-name`:
   - Deletes the existing release (if present) and its tag using `gh release delete --cleanup-tag`.
1. If `release-name == stable-release-name`:
   - If the stable tag points at the current commit: deletes the existing stable release/tag instead of archiving.
   - If the stable tag points at an older commit and a stable release exists:
     - Derives a timestamp from the old release's `publishedAt` and builds `stable.YYYY-MM-DD_HH-MM-SS`.
     - Creates and pushes that tag on the old commit and edits the old release to use that tag/title.
     - Deletes the plain stable tag so the new stable release can be created on the current commit.
   - If there is only a stable tag and no release: deletes the tag without archiving.

#### Example

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Cleanup previous stable release
        uses: sebthom/gha-shared/.github/actions/cleanup-release@v1
        with:
          release-name: stable
          github-token: ${{ secrets.GITHUB_TOKEN }}
          # stable-release-name defaults to 'stable'
```

#### Inputs

| Input Name           | Type   | Default               | Description
| -------------------- | ------ | --------------------- | -----------
| `release-name`       | string | -                     | **Required.** Name of the release/tag being created (e.g. `preview`, `stable`).
| `stable-release-name`| string | `stable`              | Name of the release/tag treated as "stable" for archiving behavior.
| `github-token`       | string | `${{ github.token }}` | Token used for GitHub CLI/API calls.

*For full details, see the [.github/actions/cleanup-release/action.yml](.github/actions/cleanup-release/action.yml)*

### <a name="shared-action-stale"></a>Shared Action: Stale

A composite action that leverages the official [`actions/stale`](https://github.com/actions/stale) action to automatically mark
and close stale issues and pull requests.

Behavior:
1. **Standard stale pass**
   - Targets all issues and PRs (except those labeled `enhancement`) inactive for 90 days, adding the `stale` label.
   - After an additional 14 days of inactivity, closes them with the `wontfix` label.
1. **Enhancement-specific pass**
   - Specifically targets issues labeled `enhancement` inactive for 360 days, adding the `stale` label.
   - After an additional 14 days of inactivity, closes them with the `wontfix` label.
1. **Pinned exemption**
   - Any issue or PR labeled `pinned` or `security` is completely exempt from both stale passes and
     will never be marked `stale` or `closed`.

#### Example

```yaml
name: Stale issues

on:
  schedule:
    - cron: '0 15 1,15 * *'
  workflow_dispatch:

permissions:
  issues: write
  pull-requests: write

jobs:
  stale:
    runs-on: ubuntu-latest
    steps:
      - name: Run stale defaults
        uses: sebthom/gha-shared/.github/actions/stale@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```


#### Inputs

| Input Name     | Type   | Default               | Description
| -------------- | ------ | --------------------- | -----------
| `github-token` | string | `${{ github.token }}` | Personal Access Token for GitHub API authentication.


*For full details, see the [.github/actions/stale/action.yml](.github/actions/stale/action.yml)*


## <a name="license"></a>License

All files are released under the [MIT License](LICENSE.txt).

Individual files contain the following tag instead of the full license text:
```
SPDX-License-Identifier: MIT License
```

This enables machine processing of license information based on the SPDX License Identifiers available at https://spdx.org/licenses/.

An exception is made for:
1. files in readable text which contain their own license information, or
2. files in a directory containing a separate `LICENSE.txt` file, or
3. files where an accompanying file exists in the same directory with a `.LICENSE.txt` suffix added to the base-name of the original file.
   For example `foobar.js` is may be accompanied by a `foobar.LICENSE.txt` license file.
