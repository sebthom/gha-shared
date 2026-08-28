<!-- Documents the design history, rejected alternatives, and operational failures of the adjacent workflow. -->

# Dependabot auto-merge design history

This document explains the design of
[`reusable.dependabot-auto-merge.yml`](reusable.dependabot-auto-merge.yml)
and records the alternatives that were tested.
It is not the primary usage guide.
See the [repository README](../../README.md#reusable-workflow-dependabot-auto-merge) for setup instructions.

GitHub changes Actions and merge behavior over time.
The linked GitHub documentation is the source of truth if platform behavior changes after this document was written.

## Goals and accepted tradeoffs

The workflow should:

- merge only eligible Dependabot pull requests after the caller's validation succeeds;
- reject the merge if Dependabot changed the pull request head after validation;
- use the built-in `github.token` without extra credentials for the common case;
- offer a permission-complete path for workflow-file updates;
- avoid branch protection and repository auto-merge as requirements; and
- leave the pull request open when a merge cannot be performed.

The REST `sha` field pins the validated pull request head.
It does not pin the target branch.
A newer, conflict-free target branch may therefore be included in the final merge.
That is an intentional tradeoff for this workflow.

## The blocking issue

The recurring blocker that invalidated otherwise-working designs was not ordinary dependency auto-merge.
It was this specific combination:

1. Dependabot opens two or more pull requests at the same time.
1. More than one pull request modifies a file under `.github/workflows/**`.
1. One pull request merges and changes the target branch while another validated pull request is still waiting to merge.
1. GitHub must merge the remaining Dependabot head with a target branch that now contains a different workflow-file change.

With the built-in `github.token`, the remaining merge can be rejected with:

~~~text
auto-merge was automatically disabled
Tried to create or update workflow without `workflows` permission
~~~

This exact sequence occurred when
[`docker-graalvm-maven#63`](https://github.com/vegardit/docker-graalvm-maven/pull/63)
merged while
[`docker-graalvm-maven#60`](https://github.com/vegardit/docker-graalvm-maven/pull/60)
was also passing CI.
Both pull requests modified `.github/workflows/build.yml`.
GitHub then disabled native auto-merge for the remaining pull request.

The first pull request often succeeds.
The later pull request is the important case because its final result combines its Dependabot head with a target
branch whose workflow file changed in the meantime.
GitHub does not document the exact internal distinction, so that explanation is an inference from the repeatable
first-succeeds/later-fails behavior and the reported permission error.

This limitation appeared across direct REST merge and native auto-merge experiments.
Branch protection, required status checks, repository auto-merge, job concurrency, and `actions: write` did not
grant the missing GitHub App **Workflows** repository permission.
They could change merge timing, but they did not remove this trust boundary.

There are now two supported authentication modes:

- The built-in token remains the credential-free default.
  If the concurrent workflow-file case occurs, comment `@dependabot rebase` on the remaining pull request.
- A custom GitHub App is the optional permission-complete path.
  Its short-lived installation token explicitly requests **Workflows: write** in addition to
  **Contents: write**.

The App path follows GitHub's documented permission model.
It still needs a live downstream test with concurrent workflow-file pull requests before it should be considered
empirically verified in every repository configuration.

## Current design

The caller validates first and invokes the reusable merge workflow only after validation succeeds:

~~~yaml
jobs:
  build:
    # ...build and test steps...

  dependabot-auto-merge:
    needs: build
    if: ${{ needs.build.result == 'success' && github.event_name == 'pull_request' && github.actor == 'dependabot[bot]' && github.event.pull_request.user.login == 'dependabot[bot]' }}
    permissions:
      contents: write
      pull-requests: write
    uses: sebthom/gha-shared/.github/workflows/reusable.dependabot-auto-merge.yml@v1
~~~

A dependency on a matrix build waits for every matrix cell.
No required status check, branch protection rule, or repository auto-merge setting is needed by this ordering.
Existing branch rules still apply and may reject the direct merge.
Protected branches are therefore supported only when every required check and approval is complete and any
requirement that the branch be up to date is satisfied when the one-shot REST merge runs.
The merge job should depend on every required validation job in the same workflow.
Requirements reported by independent workflows cannot be expressed through `needs`; if one is still pending, the
merge fails closed and must be rerun after that requirement succeeds.
The embedded Maven and Eclipse callers wait for their build matrix only.
App authentication supplies workflow-file permission but does not bypass branch rules unless the App is separately
configured as a bypass actor.

The reusable workflow repeats the event, actor, and author checks.
That is intentional because the workflow can also be called directly instead of through one of the embedded build
workflows.
The actor check excludes human-generated events on an existing Dependabot pull request without blocking a manual
rerun, which retains the original actor.

[`dependabot/fetch-metadata`](https://github.com/dependabot/fetch-metadata#outputs)
supplies the package ecosystem and semantic update type.
The workflow normalizes metadata's internal ecosystem slugs to the public names used in
`.github/dependabot.yml`.
A grouped pull request uses the highest semantic-version change reported by the metadata action, so a group that
contains a major update is eligible only when `merge-major-updates` is enabled.

### Direct REST merge

The workflow validates the selected merge method and calls GitHub's pull request merge endpoint:

~~~bash
merged=$(gh api \
  --method PUT \
  "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/merge" \
  --raw-field sha="$PR_HEAD_SHA" \
  --raw-field merge_method="$MERGE_METHOD" \
  --jq '.merged')
~~~

Supplying `sha` prevents a later Dependabot force-push from being merged under an earlier CI result.
The workflow fails if GitHub returns anything other than `merged: true`.

See GitHub's
[Merge a pull request REST documentation](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request).

### Optional GitHub App token

When both App credentials are supplied, the workflow creates a repository-scoped installation token:

~~~yaml
- uses: actions/create-github-app-token@<pinned-commit>
  with:
    client-id: ${{ inputs.github-app-client-id }}
    private-key: ${{ secrets.DEPENDABOT_MERGE_GITHUB_APP_PRIVATE_KEY }}
    permission-contents: write
    permission-workflows: write
~~~

The App must be installed on the target repository.
The private key must be stored as a Dependabot secret because Dependabot-triggered workflows do not receive
ordinary Actions secrets.
The workflow fails on partial App configuration instead of silently falling back to the built-in token.
The private key must only be passed to a trusted published revision of this workflow.
A same-repository `./.github/workflows/...` call resolves the called workflow from the caller's commit, so using that
form from a pull request workflow would let pull request code select the secret-bearing workflow definition.
The embedded public workflows are safe when consumers reference their published `sebthom/gha-shared@v1` revision:
their nested local call resolves from that same trusted `gha-shared` revision.

See GitHub's
[GitHub App permission documentation](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
and
[Dependabot secret documentation](https://docs.github.com/en/code-security/reference/secret-security/secret-types#dependabot-secrets).

## Approach comparison

The **Concurrent workflow PRs** column is the deciding column.
Several approaches work for pull requests that do not modify workflow files but do not solve the blocking case
described above.
The current workflow always uses the direct REST merge mechanism: row 3 is its default built-in-token mode, and
row 4 is the same mechanism with optional GitHub App authentication.
`workflows: write` is not a valid job `permissions` key for the built-in `github.token`.
`actions: write` is a different permission and does not authorize workflow-file changes.
The App mode exists because its installation token can explicitly request the separate Workflows repository
permission.

| Approach | Required configuration | PRs not modifying workflow files | Concurrent PRs modifying `.github/workflows/**` | Status
| -------- | ---------------------- | ----------------------- | ------------------------------------------------ | --------
| **1. `gh pr merge --auto` after validation** | Enable repository auto-merge and the selected merge method. Native registration also needs an unmet branch requirement. | Conditional. The CLI may register auto-merge or merge immediately depending on PR state. | **Fails with the built-in token.** The eventual workflow-file merge can still hit the Workflows permission boundary. | Rejected because it does not provide a registration-only contract and does not solve the blocker.
| **2. Caller-selected auto or direct merge** | Expose a mode input and configure either native auto-merge or direct-merge permissions. | Works when each caller selects the correct mode. | **Fails with the built-in token.** Both final merge paths retain the same workflow-file restriction. | Rejected because it exposes two timing and failure contracts without solving the blocker.
| **3. Current REST merge - built-in token (default)** | Allow the selected merge method. Grant `contents: write` and `pull-requests: write`. No branch protection or auto-merge setting is required. | **Works after validation.** | **Known limitation.** After another workflow-file PR merges, GitHub can reject this token for missing Workflows permission. Manual `@dependabot rebase` is the recovery path. | **Selected as the credential-free default.**
| **4. Current REST merge - GitHub App token (optional)** | Install an App. Provide its client ID and Dependabot-secret private key. Grant Contents and Workflows write permissions. | **Works after validation.** | **Expected to work.** The App token explicitly requests Workflows write permission; concurrent downstream verification is still pending. | **Selected as the optional permission-complete mode.**
| **5. Protected-branch routing** | Detect target-branch protection and maintain both GraphQL and REST implementations. | Conditional on correct detection, timing, and repository settings. | **Does not solve the blocker.** Both routes eventually ask GitHub to merge the workflow update. | Rejected because it adds two APIs and two failure models without removing the trust boundary.
| **6. Native GraphQL auto-merge** | Enable repository auto-merge and the selected merge method. Configure an unmet branch requirement and deterministic registration ordering. | **Works when registration is accepted.** | **Failed in the observed concurrent case.** GitHub registered auto-merge, then disabled it for the remaining PR after the first workflow update merged. | Rejected as the default because branch protection added configuration but did not solve the blocker.
| **7. Concurrency groups** | Configure per-PR or repository-wide concurrency; a bounded repository queue of up to 100 pending runs needs `queue: max`. | Can control when merge jobs run. | **Does not grant Workflows permission.** Native final merges happen after registration jobs end, and serialized REST jobs still use the same underprivileged token. | Rejected as a permission workaround.
| **8. `open-pull-requests-limit: 1`** | Add the limit to every relevant `dependabot.yml` update entry. | Reduces overlap inside one update configuration. | Mitigates but does not eliminate overlap across ecosystems or update configurations. It also delays update discovery. | Rejected as a repository-by-repository throttle.
| **9. Rerun, rebase, or recreate** | Manual action on the affected PR. | Useful recovery. | `@dependabot rebase` can regenerate the remaining head against the updated target branch and allow a new validated merge attempt. A rerun alone does not add permission. | Retained as recovery for the built-in-token mode, not as automatic coordination.

## Detailed history

### 1. `gh pr merge --auto` after validation

The first implementation waited for the build and used GitHub CLI:

~~~bash
gh pr merge \
  --auto \
  --match-head-commit "$PR_HEAD_SHA" \
  --squash \
  "$PR_URL"
~~~

This was compact and used a supported CLI command.
However, `--auto` is not an enable-only operation.
If no branch requirement is pending when the command runs, GitHub can merge immediately instead of only
registering future intent.
If native auto-merge is unavailable, it can fail for repository-state reasons unrelated to validation.

Most importantly, the eventual merge still uses the built-in token's authorization context.
The later native GraphQL experiment proved that successful registration did not prevent the concurrent
workflow-file failure.

See the [`gh pr merge` manual](https://cli.github.com/manual/gh_pr_merge).

### 2. Caller-selected auto-merge or direct merge

A later version exposed a `dependabot-use-auto-merge` input:

~~~bash
merge_args=(
  "$merge_method_flag"
  --match-head-commit "$PR_HEAD_SHA"
)
if [[ "$DEPENDABOT_USE_AUTO_MERGE" == "true" ]]; then
  merge_args+=(--auto)
fi
gh pr merge "${merge_args[@]}" "$PR_URL"
~~~

This supported protected and unprotected repositories.
It also required every caller to understand two different contracts:

- auto mode depended on repository auto-merge and an unmet branch requirement;
- direct mode merged immediately after CI.

Both paths retained the workflow-file permission problem.
The mode input was therefore configuration without a solution to the core blocker.

### 3. Current REST merge with the built-in token

The REST endpoint is explicit, supports squash and rebase, and accepts the tested head SHA.
It does not require repository auto-merge or branch protection.
This is now the default because it provides the smallest setup for the common case and matches the accepted
target-branch tradeoff.

Its limitation is also explicit.
The built-in `github.token` cannot request the GitHub App **Workflows** repository permission through a workflow
`permissions` block.
Adding this does not help:

~~~yaml
permissions:
  actions: write
~~~

`actions: write` controls Actions resources, such as workflow runs and caches.
It is not the GitHub App permission to create or update files under `.github/workflows/**`.

Typical REST failure:

~~~text
gh: refusing to allow a GitHub App to create or update workflow
`.github/workflows/build.yml` without `workflows` permission (HTTP 403)
~~~

See GitHub's
[workflow `permissions` reference](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions)
and
[GitHub App permission guidance](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app).

### 4. Current REST merge with a custom GitHub App

The App path was retained as an option instead of making credentials mandatory for every repository.
It requests the Workflows permission needed for workflow-file changes plus the Contents permission required by
the merge endpoint.

Benefits:

- short-lived installation token;
- repository-scoped by the token action;
- no long-lived personal access token; and
- explicit permission for workflow-file updates.

Costs:

- App creation and installation in every target repository;
- client ID configuration;
- private-key storage and rotation; and
- a larger credential trust boundary than the built-in token.

The App token action revokes the token when the job finishes by default.
Because the workflow is triggered by Dependabot, the private key must be a Dependabot secret.

### 5. Protected-branch routing

One version inspected the target branch's protection state and chose GraphQL for protected branches or REST for
unprotected branches.
That appeared to offer automatic configuration detection.

It did not answer the important question.
A protected flag does not prove that native auto-merge is enabled or that an unmet requirement exists.
The REST route still lacked Workflows permission, and the GraphQL route still left the final merge to the same
platform authorization behavior.
Maintaining both APIs made errors harder to diagnose without solving the concurrent workflow-file case.

### 6. Native GraphQL auto-merge

Two orderings were tested.

Registration after validation could fail because the PR was already immediately mergeable:

~~~text
gh: Auto merge is not allowed for this repository
~~~

~~~text
gh: Pull request Pull request is in unstable status
~~~

Making the registration check itself required kept an unmet check pending, but it created a self-referential
branch rule.
Skipped or renamed reusable-workflow checks could then leave human PRs waiting for a status that was never
reported.
See [Community discussion #72708](https://github.com/orgs/community/discussions/72708).

Registration before validation used deterministic job ordering:

~~~yaml
jobs:
  dependabot-auto-merge:
    # ...enable-only GraphQL mutation...

  build:
    needs: dependabot-auto-merge
    if: ${{ !cancelled() }}
~~~

The enable-only mutation pinned registration to the then-current PR head:

~~~bash
gh api graphql \
  --raw-field query='mutation EnablePullRequestAutoMerge(
    $pullRequestId: ID!
    $mergeMethod: PullRequestMergeMethod!
    $expectedHeadOid: GitObjectID!
  ) {
    enablePullRequestAutoMerge(input: {
      pullRequestId: $pullRequestId
      mergeMethod: $mergeMethod
      expectedHeadOid: $expectedHeadOid
    }) {
      pullRequest { id }
    }
  }' \
  --raw-field pullRequestId="$PR_NODE_ID" \
  --raw-field mergeMethod="$GRAPHQL_MERGE_METHOD" \
  --raw-field expectedHeadOid="$PR_HEAD_SHA"
~~~

This ordering solved the registration race.
It required repository auto-merge, a branch rule or ruleset, and at least one required validation check.
That configuration was useful for getting registration accepted, but it did not grant workflow-file permission.

The decisive result was `docker-graalvm-maven#60`.
Registration succeeded and CI passed.
After concurrent `#63` changed the target workflow, GitHub automatically disabled auto-merge with the missing
Workflows permission message.
Native auto-merge therefore coordinated timing but did not solve the blocking authorization case.

The earlier `actions: write` experiment also did not solve this final-merge failure.
Public reports are mixed because GraphQL registration and the later final merge are separate authorization points.
See [GitHub CLI issue #11493](https://github.com/cli/cli/issues/11493) and
[open-contracting/kestrel#8](https://github.com/open-contracting/kestrel/pull/8).

### 7. Concurrency groups

A repository-wide concurrency group was tried to serialize merge jobs:

~~~yaml
concurrency:
  group: dependabot-pr-auto-merge-${{ github.repository }}
  cancel-in-progress: false
~~~

With the default single pending slot, a newer queued run replaces the older pending run.
A burst of Dependabot pull requests can therefore lose intermediate merge jobs even when
`cancel-in-progress` is false.

A per-PR group avoids cross-PR cancellation but does not serialize different pull requests.

GitHub later added a bounded queue mode that retains up to 100 pending runs:

~~~yaml
concurrency:
  group: dependabot-pr-auto-merge-${{ github.repository }}
  queue: max
  cancel-in-progress: false
~~~

This can serialize direct merge jobs, but it cannot add Workflows permission.
For native auto-merge it does not serialize the later GitHub-owned final merge because the registration job has
already ended.
For direct REST it delays jobs but a later merge can still cross the workflow-file permission boundary after an
earlier merge changed the target branch.

Actionlint 1.7.12 did not recognize `queue` when this was evaluated.
See [actionlint issue #657](https://github.com/rhysd/actionlint/issues/657) and
[GitHub's concurrency documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

### 8. Limiting Dependabot to one open pull request

This repository-level workaround was considered:

~~~yaml
# .github/dependabot.yml
updates:
- package-ecosystem: github-actions
  directory: /
  schedule:
    interval: weekly
  open-pull-requests-limit: 1
~~~

It reduces concurrency inside one Dependabot update configuration.
It also delays later updates, must be copied into every repository, and does not prevent overlap across multiple
ecosystems or configurations.
It was rejected as an operational throttle rather than a merge solution.

### 9. Retry, rerun, rebase, or recreate

A workflow rerun uses the original Dependabot-triggered privileges.
It does not acquire the permissions of the user who clicked **Re-run jobs**, so rerunning an unchanged PR does not
fix the Workflows permission.

A Dependabot rebase is different.
Commenting `@dependabot rebase` asks Dependabot to regenerate the PR head against the current target branch.
For the observed first-succeeds/later-fails case, this incorporates the first workflow update into the remaining
Dependabot head, reruns CI, and can allow the built-in token's next merge attempt to succeed.
It does not grant new permission, so it is recovery rather than a general authorization solution.

`@dependabot recreate` can recover a malformed or stale generated update but is more disruptive than a rebase.
Use rebase first for the concurrent workflow-file case.

See [Dependabot on GitHub Actions](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-on-actions).

## Observed error catalogue

Historical run logs can expire or require authentication.

### Observed in these repositories

| Message | Context | Interpretation
| ------- | ------- | --------------
| `PR is not from Dependabot, nothing to do` | `dependabot/fetch-metadata` on an apparently Dependabot-authored PR | The action rejected the event. The root cause was not established and should not be attributed to concurrency without more evidence.
| `refusing to allow a GitHub App to create or update workflow ... without workflows permission (HTTP 403)` | Direct REST merge | The built-in token crossed GitHub's workflow-file trust boundary. `actions: write` did not supply the separate Workflows permission.
| `Auto merge is not allowed for this repository` | GraphQL registration | Repository auto-merge was disabled or the repository or PR was otherwise ineligible.
| `Pull request Pull request is in unstable status` | GraphQL registration after validation | GitHub rejected the current mergeability state without identifying the precise condition.
| `auto-merge was automatically disabled` / `Tried to create or update workflow without workflows permission` | Native final merge after another workflow PR merged | This is the decisive concurrent workflow-file failure. Registration and CI had succeeded, but the final merge was rejected.
| `Expected - Waiting for status to be reported` | Required nested reusable-workflow check | The configured required check name was not emitted, commonly because the reusable caller was skipped under a different check name.
| `unexpected key "queue" for "concurrency" section` | actionlint 1.7.12 | The linter did not yet recognize GitHub's `concurrency.queue` property.

Observed examples:

- [Metadata rejected an apparently Dependabot-authored PR](https://github.com/sebthom/previewer-eclipse-plugin/actions/runs/32604818843/job/97108527657?pr=54)
- [A direct merge failed with the workflow permission error](https://github.com/vegardit/docker-meshcentral/actions/runs/32672738846/job/97276179390?pr=38)
- [Native registration failed with unstable status](https://github.com/vegardit/docker-meshcentral/actions/runs/32745934131/job/97492000833?pr=38)
- [One concurrent direct merge failed](https://github.com/vegardit/docker-gitea-ext/actions/runs/32664564131/job/97256040030?pr=34)
  while [another PR in that repository merged](https://github.com/vegardit/docker-gitea-ext/actions/runs/32664562755?pr=35)
- [Native auto-merge was disabled on the remaining concurrent workflow PR](https://github.com/vegardit/docker-graalvm-maven/pull/60)
  after [the other workflow PR merged](https://github.com/vegardit/docker-graalvm-maven/pull/63)
- [A Dependabot rebase command was used as recovery](https://github.com/futures4j/futures4j/pull/60#issuecomment-5316933465)

### External reports considered

- [GitHub CLI issue #11493](https://github.com/cli/cli/issues/11493) reports the workflow permission error during
  GraphQL auto-merge registration.
- [open-contracting/kestrel#8](https://github.com/open-contracting/kestrel/pull/8) reports a workflow-file update
  succeeding after `actions: write` was added.
- [Community discussion #108402](https://github.com/orgs/community/discussions/108402) discusses GitHub App
  Workflows permission restrictions in update-branch and fork scenarios.

These reports do not override the first-hand `docker-graalvm-maven#60` result.
In that run, `actions: write`, native auto-merge, branch protection, and passing CI still did not prevent the
concurrent workflow-file merge from being disabled.

## Why the current design is intentionally explicit

The current workflow no longer tries to infer branch protection or hide two authorization models behind a routing
flag.

It has one merge policy and two explicit credential choices:

1. The caller's validation job must succeed.
1. The merge is pinned to the validated Dependabot head.
1. Direct REST performs the selected squash or rebase merge.
1. The built-in token is the simple default.
1. The GitHub App token is the opt-in permission-complete path for concurrent workflow-file updates.
1. Without the App, the known concurrent workflow-file failure remains visible and recoverable with a Dependabot
   rebase.

This design accepts that target-branch freshness is not pinned.
It removes the branch-protection and native-auto-merge configuration that did not solve the actual blocker, while
preserving a credential-free path for repositories that prefer minimal setup.
