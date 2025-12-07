# gha-shared

[![License](https://img.shields.io/github/license/sebthom/gha-shared.svg?color=blue)](LICENSE.txt)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-v2.1%20adopted-ff69b4.svg)](CODE_OF_CONDUCT.md)

1. [What is it?](#what-is-it)
1. [Reusable Workflows](#reusable-workflows)
   1. [Maven Build](#reusable-workflow-maven-build)
   1. [Eclipse Plugin Build](#reusable-workflow-eclipse-plugin-build)
   1. [Eclipse Product Build](#reusable-workflow-product-plugin-build)
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
| Maven Build           | `.github/workflows/reusable.maven-build.yml`           | Builds, tests, and releases Maven projects with multi-JDK matrix.
| Eclipse Plugin Build  | `.github/workflows/reusable.eclipse-plugin-build.yml`  | Builds, tests, and releases Eclipse plugins.
| Eclipse Product Build | `.github/workflows/reusable.eclipse-product-build.yml` | Builds, tests, and releases Eclipse products.


### <a name="reusable-workflow-maven-build"></a>Reusable Workflow: Maven Build

To use the **Maven Build** workflow, reference its YAML file in your repository's workflow definition.

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
|**Java:**
| `compile-jdk`                       | str  | -                        | **REQUIRED** The JDK for compilation, either a major version (e.g. `11`, `17`) or vendor-qualified (`temurin@11`).
| `test-jdks`                         | str  | -                        | A comma- or newline-separated list of additional JDKs to run unit tests against (e.g. `11,17` or `temurin@11`). Append `!` to allow failures for that JDK (e.g. `17!`).
| **Maven:**
| `maven-jdk`                         | str  | `temurin@21`             | The JDK used to run Maven itself, by major version or with vendor (e.g. `17` or `temurin@17`).
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

      debug-with-ssh: ${{ inputs.debug-with-ssh }}
      debug-with-ssh-only-for-actor: ${{ inputs.debug-with-ssh-only-for-actor }}
      debug-with-ssh-only-jobs-matching: ${{ inputs.debug-with-ssh-only-jobs-matching }}

    permissions:
      actions: write       # to delete action cache entries
      contents: write      # to create releases (commit to updatesite branches)
      pull-requests: write # for dependabot auto merges
```

*For full details, see the [.github/workflows/reusable.eclipse-plugin-build.yml](.github/workflows/reusable.eclipse-plugin-build.yml)*


### <a name="reusable-workflow-eclipse-product-build"></a>Reusable Workflow: Eclipse Product Build

To use the **Eclipse Product Build** workflow, reference its YAML file in your repository's workflow definition.

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

      debug-with-ssh: ${{ inputs.debug-with-ssh }}
      debug-with-ssh-only-jobs-matching: ${{ inputs.debug-with-ssh-only-jobs-matching }}

    permissions:
      actions: write       # to delete action cache entries
      contents: write      # to create releases (commit to updatesite branches)
      pull-requests: write # for dependabot auto merges
```

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

*For full details, see the [.github/actions/cleanup-previous-release/action.yml](.github/actions/cleanup-previous-release/action.yml)*

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
