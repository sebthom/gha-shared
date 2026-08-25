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
| Dependabot Auto-Merge | `.github/workflows/reusable.dependabot-auto-merge.yml` | Registers native auto-merge for eligible Dependabot pull requests.
| Maven Build           | `.github/workflows/reusable.maven-build.yml`           | Builds, tests, and releases Maven projects with multi-JDK matrix. Includes Dependabot auto-merge.
| Eclipse Plugin Build  | `.github/workflows/reusable.eclipse-plugin-build.yml`  | Builds, tests, and releases Eclipse plugins. Includes Dependabot auto-merge.
| Eclipse Product Build | `.github/workflows/reusable.eclipse-product-build.yml` | Builds, tests, and releases Eclipse products. Includes Dependabot auto-merge.


### <a name="reusable-workflow-dependabot-auto-merge"></a>Reusable Workflow: Dependabot Auto-Merge

Use the **Dependabot Auto-Merge** workflow before the caller's validation job.
The caller must include the `pull_request` event.
The workflow accepts only pull requests authored by Dependabot and skips registration for other events.
Minor and patch updates are eligible by default, while major updates are opt-in.
It registers GitHub native auto-merge and relies on branch protection to prevent the final merge until every
required validation check succeeds.

#### Example

```yaml
jobs:
  dependabot-auto-merge:
    permissions:
      actions: write
      contents: write
      pull-requests: write
    uses: sebthom/gha-shared/.github/workflows/reusable.dependabot-auto-merge.yml@v1
    # All inputs are optional. The values below demonstrate restricting merges
    # to GitHub Actions updates while retaining the default merge behavior.
    with:
      package-ecosystems: '["github-actions"]'
      merge-method: squash
      merge-major-updates: false

  build:
    # Run dependabot auto-merge setup first so GitHub sees this required validation check as pending.
    needs: dependabot-auto-merge
    # A failed or skipped dependabot auto-merge setup must not suppress the normal build.
    if: ${{ !cancelled() }}

    runs-on: ubuntu-latest
    steps:
    - name: Build and test
      run: |
        # Fail safely until this placeholder is replaced with the project's validation commands.
        echo "Replace this placeholder with the project's build and test commands." >&2
        exit 1
```

#### Inputs

| Name                   | Type | Default  | Description
| ---------------------- | ---- | -------- | -----------
| `package-ecosystems`   | str  | `["*"]`  | JSON array of Dependabot ecosystems eligible for merging. Use `["*"]` for all ecosystems or `[]` for none.
| `merge-method`         | str  | `squash` | Merge method for eligible Dependabot PRs. Supported values are `squash` and `rebase`.
| `merge-major-updates`  | bool | `false`  | Whether major Dependabot updates are eligible for merging. Minor and patch updates remain eligible by default.

#### Caller Configuration

Place registration and validation in the same workflow dependency graph.
The `dependabot-auto-merge` job must not depend on validation.
At least one required validation job must depend on it and use `if: ${{ !cancelled() }}` so a failed or skipped
registration does not suppress validation.
If validation has other prerequisite jobs, preserve their success checks explicitly, for example with
`if: ${{ !cancelled() && needs.init.result == 'success' }}`.
Independently triggered workflows do not provide equivalent ordering because GitHub may schedule either one first.
The `dependabot-auto-merge` job must grant these permissions:

```yaml
permissions:
  actions: write
  contents: write
  pull-requests: write
```

`actions: write` is an empirically successful compatibility workaround for native auto-merge registrations that
modify `.github/workflows/**`.
GitHub does not document it as a substitute for the separate GitHub App **Workflows** permission.
It also did not fix the earlier direct REST merge implementation; see the
[design history](.github/workflows/reusable.dependabot-auto-merge.md#3-direct-rest-merge-after-validation)
for the distinction and supporting evidence.

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

GitHub permits native auto-merge registration only while a pull request is waiting for at least one merge
requirement.
Even if the repository otherwise does not need merge restrictions, this workflow therefore needs one required
validation check on every branch targeted by Dependabot.

Use this minimal configuration:

##### Settings > General > Pull Requests

1. Enable **Allow auto-merge**.
1. Enable the selected merge method.
   Enable **Allow squash merging** for `merge-method: squash` or **Allow rebase merging** for
   `merge-method: rebase`.

##### Settings > Rulesets

1. Run the validation workflow successfully once if its check is not yet available for selection.
   GitHub only offers
   [checks that completed successfully in the repository during the previous seven days](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks).
1. Create a **New branch ruleset**.
1. Enter a descriptive **Ruleset name**, such as `Required validation for auto-merge`, and set
   **Enforcement status** to **Active**.
   The name does not select a branch.
1. Under **Target branches**, select **Add target > Include default branch**.
   Select a branch explicitly instead if Dependabot targets a branch other than the default branch.
1. Optionally, configure the **Bypass list** if selected users should still be allowed to push directly:
   - If this ruleset exists only to enable Dependabot auto-merge, add your user account and select
     **Always allow**.
     This keeps direct pushes available to that account without exempting Dependabot from validation.
     Add a team or repository role instead only when every member should have the same bypass permission.
   - If direct pushes must also pass the required check, leave the bypass list empty.
   Do not add Dependabot or GitHub Actions to the bypass list because Dependabot pull requests must remain
   subject to the required validation check.
   See [GitHub's ruleset bypass documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository#granting-bypass-permissions-for-your-branch-or-tag-ruleset)
   for the available bypass actors and modes.
1. Under **Branch rules**, enable **Require status checks to pass**.
   This workflow does not require any other branch rule.
   Enable additional rules such as **Require a pull request before merging**, **Restrict deletions**, or
   **Block force pushes** when they match the repository's policy.
1. Expand the additional settings for **Require status checks to pass** and select **Add checks**.
   The dropdown may initially be empty because GitHub treats it as a search field rather than a list.
   For a non-matrix job, type its exact displayed name, for example `build`, then select the matching result.
   [GitHub matches required checks by job name and does not interpret matrix configuration as one combined check](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/troubleshooting-rules#troubleshooting-required-status-checks).
   For a matrix job, GitHub reports a separate check for every matrix cell, such as
   `build (latest, 11, false)` and `build (latest, 17, false)`.
   Select every matrix check that must pass before merging.
   Do not select only the unsuffixed name `build` unless the workflow contains a separate job that reports that
   exact name; otherwise the pull request waits indefinitely for a check that never runs.
   If the matrix changes frequently, consider requiring a stable aggregate job instead of updating the ruleset
   for every matrix change:

   ```yaml
   build-result:
     name: build-result
     needs: build
     # A failed dependency normally skips this job, and GitHub treats skipped required checks as successful.
     if: ${{ always() }}
     runs-on: ubuntu-latest
     steps:
       - name: Verify build matrix
         env:
           BUILD_RESULT: ${{ needs.build.result }}
         run: test "$BUILD_RESULT" = success
   ```

   Require `build-result` in the ruleset when using this pattern.
   At least one required validation check must run on every Dependabot pull request, but GitHub does not wait
   for any unselected checks.
   Do not select the `dependabot-pr-auto-merge` registration check.
   Leave **Require branches to be up to date before merging** disabled.
   See [GitHub's ruleset documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
   for details about the available rules.

Do not make the auto-merge registration job a required check.
Instead, make at least one required validation job depend on the registration job and use
`if: ${{ !cancelled() }}` so validation still runs if registration fails or is skipped.
The Maven and Eclipse reusable build workflows already define this dependency.
A standalone caller must preserve the dependency shown in the example above.
This dependency guarantees that validation cannot finish before registration is attempted; it does not rely on
workflow scheduling or relative runtime.
A required branch condition is therefore still unsatisfied when GitHub evaluates
[native auto-merge](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/automatically-merging-a-pull-request)
for the pull request.
After registration, GitHub waits for every branch requirement and performs the final merge.

The workflow uses the enable-only
[`enablePullRequestAutoMerge` mutation](https://docs.github.com/en/graphql/reference/pulls#enablepullrequestautomerge).
It never falls back to a direct merge.
Missing required status checks, a non-required validation check,
or incompatible repository settings therefore leave the pull request open instead of bypassing validation.
Target branches that require a merge queue are not supported because the built-in `github.token` cannot add a
pull request to that queue.

##### Concurrent Pull Requests

Each workflow run only registers native auto-merge for its own pull request.
GitHub waits for the required checks and coordinates the final merges across concurrent pull requests.
If the branch rule requires pull requests to be up to date, a newer target-branch commit can require another
Dependabot update and validation run before GitHub merges the remaining pull request.

*For implementation details, see
[.github/workflows/reusable.dependabot-auto-merge.yml](.github/workflows/reusable.dependabot-auto-merge.yml).
For evaluated alternatives and observed failures, see
[.github/workflows/reusable.dependabot-auto-merge.md](.github/workflows/reusable.dependabot-auto-merge.md).*


### <a name="reusable-workflow-maven-build"></a>Reusable Workflow: Maven Build

To use the **Maven Build** workflow, reference its YAML file in your repository's workflow definition.
This workflow includes [Dependabot Auto-Merge](#reusable-workflow-dependabot-auto-merge) for eligible
Dependabot pull requests.
Its embedded auto-merge call is limited to the `maven` and `github-actions` package ecosystems.
Use the standalone workflow for any additional ecosystems.
Repositories using Dependabot with this workflow must complete the
[repository configuration](#repository-configuration).

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

    secrets:
      SONATYPE_CENTRAL_USER:  ${{ secrets.SONATYPE_CENTRAL_USER }}
      SONATYPE_CENTRAL_TOKEN: ${{ secrets.SONATYPE_CENTRAL_TOKEN }}
      GPG_SIGN_KEY:           ${{ secrets.GPG_SIGN_KEY }}
      GPG_SIGN_KEY_PWD:       ${{ secrets.GPG_SIGN_KEY_PWD }}
      CODECOV_TOKEN:          ${{ secrets.CODECOV_TOKEN }}

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

*For full details, see the [.github/workflows/reusable.maven-build.yml](.github/workflows/reusable.maven-build.yml)*


### <a name="reusable-workflow-eclipse-plugin-build"></a>Reusable Workflow: Eclipse Plugin Build

To use the **Eclipse Plugin Build** workflow, reference its YAML file in your repository's workflow definition.
This workflow includes [Dependabot Auto-Merge](#reusable-workflow-dependabot-auto-merge) for eligible
Dependabot pull requests.
Its embedded auto-merge call is limited to the `maven` and `github-actions` package ecosystems.
Use the standalone workflow for any additional ecosystems.
Repositories using Dependabot with this workflow must complete the
[repository configuration](#repository-configuration).

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

*For full details, see the [.github/workflows/reusable.eclipse-plugin-build.yml](.github/workflows/reusable.eclipse-plugin-build.yml)*


### <a name="reusable-workflow-eclipse-product-build"></a>Reusable Workflow: Eclipse Product Build

To use the **Eclipse Product Build** workflow, reference its YAML file in your repository's workflow definition.
This workflow includes [Dependabot Auto-Merge](#reusable-workflow-dependabot-auto-merge) for eligible
Dependabot pull requests.
Its embedded auto-merge call is limited to the `maven` and `github-actions` package ecosystems.
Use the standalone workflow for any additional ecosystems.
Repositories using Dependabot with this workflow must complete the
[repository configuration](#repository-configuration).

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
