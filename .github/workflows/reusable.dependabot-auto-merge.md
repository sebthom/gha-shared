<!-- Documents the design history, rejected alternatives, and operational failures of the adjacent workflow. -->

# Dependabot auto-merge design history

This document explains why
[`reusable.dependabot-auto-merge.yml`](reusable.dependabot-auto-merge.yml)
uses GitHub native auto-merge and why several apparently simpler alternatives were removed.
It is a record of experiments and observed failures, not the usage guide.
See the [repository README](../../README.md#reusable-workflow-dependabot-auto-merge) for current setup instructions.

GitHub has changed Actions concurrency and merge APIs over time.
The linked GitHub documentation is the source of truth if platform behavior changes after this document was written.

## Goals and constraints

The workflow should:

- merge only eligible Dependabot pull requests;
- reject registration if the selected pull request head changes between the decision and registration;
- never bypass required build and test checks;
- handle several Dependabot pull requests without losing queued work;
- merge updates to `.github/workflows/**` without special handling where possible;
- avoid a GitHub App, private key, and repository-specific credentials where possible; and
- fail with the pull request still open when repository configuration is incomplete.

The difficult part was not recognizing Dependabot or selecting semantic-version updates.
It was choosing when and how to request a merge while GitHub was simultaneously evaluating required checks,
other pull requests, branch protection, token permissions, and workflow-file restrictions.

## Current design

The current design registers native auto-merge before at least one required validation job starts:

```yaml
jobs:
  dependabot-auto-merge:
    permissions:
      actions: write
      contents: write
      pull-requests: write
    uses: sebthom/gha-shared/.github/workflows/reusable.dependabot-auto-merge.yml@v1

  build:
    needs: dependabot-auto-merge
    if: ${{ !cancelled() }}
    # ...required build and test steps...
```

Dependabot-triggered `pull_request` runs receive a read-only `github.token` by default,
but GitHub honors explicit workflow and job permissions for those runs.
A called reusable workflow can only maintain or reduce the permissions granted by its caller,
so the calling job must grant all three scopes shown above.
GitHub's documented Dependabot example grants `contents: write` and `pull-requests: write`.
The additional `actions: write` permission is an empirical compatibility workaround:
GitHub's backend has rejected `enablePullRequestAutoMerge` for workflow-file updates without the separate
**Workflows** permission, while public reports show the same mutation succeeding after `actions: write` was added.
GitHub does not document `actions: write` as a substitute for **Workflows**, so this behavior is not a stable
permission contract.
See [GitHub CLI issue #11493](https://github.com/cli/cli/issues/11493) and the successful workflow-file update in
[open-contracting/kestrel#8](https://github.com/open-contracting/kestrel/pull/8).
This lets the workflow use the built-in token without a PAT or custom GitHub App.
See [GitHub's Dependabot permissions change](https://github.blog/changelog/2021-10-06-github-actions-workflows-triggered-by-dependabot-prs-will-respect-permissions-key-in-workflows/)
and [the reusable-workflow permission rules](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#supported-keywords-for-jobs-that-call-a-reusable-workflow).

[`dependabot/fetch-metadata`](https://github.com/dependabot/fetch-metadata#outputs)
reports `update-type` as the highest SemVer change in the pull request.
A grouped pull request containing a major update is therefore eligible only when `merge-major-updates` is enabled,
even if the group also contains minor or patch updates.

The reusable workflow calls the enable-only GraphQL mutation and pins the registration to the current PR head:

```bash
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
  --raw-field mergeMethod="$graphql_merge_method" \
  --raw-field expectedHeadOid="$PR_HEAD_SHA"
```

At least one required validation job depends on registration.
This dependency guarantees that validation cannot finish before registration is attempted;
it does not rely on the scheduling order or relative duration of independent workflows.
A required branch condition is therefore still unsatisfied when GitHub evaluates auto-merge.
After registration, GitHub waits for all branch requirements and coordinates the final merge.
The dependent validation job uses `!cancelled()` so a registration error remains visible but does not suppress CI.

Calling registration and validation from independently triggered workflows does not provide this ordering guarantee.
Registration can then run after a fast build and be rejected if the pull request has already become immediately
mergeable.
For deterministic behavior, put both jobs in the same workflow and make validation depend on registration.

### Advantages

- GitHub owns waiting, final merge timing, and coordination between concurrent PRs.
- The workflow has no immediate REST fallback; a registration failure leaves the PR open.
- `expectedHeadOid` rejects registration if Dependabot updates the PR head first.
- No direct REST merge or custom merge queue is required.
- No PAT, GitHub App installation, client ID, or private key is required.
- Missing branch protection or auto-merge configuration fails closed.

### Costs and limitations

- The repository must enable auto-merge and the selected merge method.
- The target branch must have at least one required validation check.
- At least one required validation job starts only after the short registration job has completed or failed.
- Registration is attempted once per workflow run.
  If GitHub rejects it, rerun the workflow or update the PR as described in
  [the recovery section](#9-retry-rerun-rebase-or-recreate).
- Strict up-to-date branch rules can require another Dependabot rebase and CI run after another PR merges.
- Merge queues are not supported because GitHub documents that the built-in `GITHUB_TOKEN` cannot add a
  Dependabot PR to a merge queue.
- A repository that intentionally has no branch requirements cannot use this workflow as a direct-merge substitute.
- GitHub does not document the `actions: write` workaround for workflow-file updates.
  If the backend rejects registration despite that permission, the workflow fails closed and a token with the
  separate **Workflows** permission is still required.

Relevant GitHub documentation:

- [Automating Dependabot with GitHub Actions](https://docs.github.com/en/code-security/tutorials/secure-your-dependencies/automate-dependabot-with-actions)
- [Automatically merging a pull request](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/automatically-merging-a-pull-request)
- [`enablePullRequestAutoMerge` GraphQL mutation](https://docs.github.com/en/graphql/reference/pulls#enablepullrequestautomerge)
- [Required status checks](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks)

## Approaches evaluated

The first matrix compares merge mechanisms.
The second matrix covers scheduling and recovery measures that can support a mechanism but cannot replace one.
"Conditional" means the approach works only under the limitation stated in the cell.

### Merge-mechanism comparison

| Approach | Required configuration | Protected branch with required checks | Branch without required checks | PR changes `.github/workflows/**` | Concurrent PRs | Decision
| -------- | ---------------------- | ------------------------------------- | ------------------------------ | -------------------------------- | -------------- | --------
| **Current: Ordered GraphQL registration before validation** | Enable repository auto-merge and the selected merge method. Make at least one required validation job depend on registration and use `if: ${{ !cancelled() }}`. Grant the caller `actions: write`, `contents: write`, and `pull-requests: write`. | **Works.** GitHub waits for validation after registration. | **Fails closed.** The enable-only mutation is rejected because there is no unmet branch requirement. | **Conditional.** The backend can reject GraphQL registration with the workflow-file permission error. Public examples succeeded after granting `actions: write`, but GitHub does not document that behavior. | **Conditional.** GitHub coordinates final merges, but strict up-to-date checks can require Dependabot to update a remaining PR and CI to run again. | **Selected.** One fail-closed contract with deterministic registration-before-validation ordering.
| **1.** `gh pr merge --auto` after validation | Enable repository auto-merge and the selected merge method. Grant the caller write permissions. | **Conditional.** With no unmet requirement, the CLI may proceed with the merge instead of only registering intent. | **Conditional.** It may merge immediately or auto-merge registration may be unavailable. | **Conditional.** An immediate merge can cross the workflow-file permission boundary. | **Conditional.** Immediate merge attempts can expose base-branch races. | Rejected because it does not provide a registration-only contract.
| **2.** Caller-selected auto-merge or immediate merge | Configure a per-caller mode flag. The auto route needs native auto-merge and required checks; the direct route needs write permissions. | **Works** when the caller selects native auto-merge. | **Works** when the caller selects direct merge. | **Conditional.** The direct route can fail with the workflow-file permission error. | **Conditional.** The direct route retains concurrent-merge races. | Rejected because callers had to understand and preserve two different safety contracts.
| **3.** Direct REST merge with `GITHUB_TOKEN` | Allow the selected merge method. Grant the caller `contents: write` and `pull-requests: write`. Native auto-merge is not required. | **Works after validation** if branch policy permits the token to merge. | **Works after validation.** | **Fails in the observed case.** The built-in token lacked the GitHub App **Workflows** permission. | **Conditional.** The expected head protects the PR head, but simultaneous merges can change the base branch. | Rejected because the workflow owns the final merge and hits the workflow-file trust boundary.
| **4.** Direct REST merge with a custom GitHub App token | Install an App and provide its client ID and private key as Dependabot-accessible configuration. Grant App contents, pull-request, and workflow permissions. | **Works after validation** when App and branch policy permit it. | **Works after validation.** | **Conditional.** The App can request the missing permission, but GitHub reports restrictions in some scenarios. | **Conditional.** The App does not remove base-branch races between direct merge attempts. | Rejected because of credential management, a larger trust boundary, and remaining platform edge cases.
| **5.** Protected-branch routing between GraphQL and REST | Configure both native auto-merge and direct-merge permissions. The workflow must inspect the target branch and maintain both implementations. | **Works** through GraphQL when registration is still possible. | **Works** through REST. | **Conditional.** GraphQL registration and the direct REST merge can both hit workflow-file permission checks. | **Conditional.** The REST route retains direct-merge races. | Rejected because one workflow exposed two timing, permission, and failure models.
| **6.** GraphQL registration after validation with registration itself required | Enable native auto-merge. Configure the exact generated registration check as required in addition to validation. | **Conditional.** It works only while the correctly named registration check is pending. | **Not applicable.** The workaround creates a required branch condition. | **Conditional.** Registration can hit the same workflow-file permission check as the current GraphQL design. | **Works after registration.** | Rejected because skipped or renamed reusable-workflow checks can leave PRs permanently waiting.

### Coordination and recovery comparison

| Measure | Required configuration | What it helps | What it does not solve | Decision
| ------- | ---------------------- | ------------- | ---------------------- | --------
| **Independent workflow registration** | Trigger GraphQL registration separately from validation, using the same repository settings and caller permissions as the current design. | Can register native auto-merge when at least one required validation condition is still pending. | Independent scheduling cannot guarantee registration runs first. Strict up-to-date checks can still require Dependabot to update a remaining PR and CI to run again. | Not recommended when deterministic registration-before-validation ordering is required.
| **7a.** Repository-wide concurrency group with the default single pending slot | Add one repository-wide `concurrency.group` and set `cancel-in-progress: false`. | Serializes the running merge job. | A newer queued run replaces the older pending run. It does not fix API permissions or merge semantics. | Rejected because Dependabot bursts can lose intermediate jobs.
| **7b.** Per-PR concurrency group | Include the PR number in `concurrency.group`. | Prevents one PR from replacing another PR's pending job. | Different PRs still merge concurrently, so it does not serialize direct merge attempts. | Unnecessary for native registration; useful only for deduplicating runs of the same PR.
| **7c.** Repository-wide `queue: max` | Add `concurrency.queue: max`; configure actionlint while version 1.7.12 lacks support. | Serializes jobs and retains up to 100 pending runs. | It does not fix workflow-file permissions or unsafe direct-merge behavior, and it delays independent PRs. | Rejected because GitHub already coordinates native final merges.
| **8.** `open-pull-requests-limit: 1` | Add the limit to every relevant update entry in each consumer's `dependabot.yml`. | Reduces overlap within one Dependabot update configuration. | It delays discovery and does not prevent concurrency across configurations or ecosystems. | Rejected as an operational throttle rather than a merge solution.
| **9.** Workflow rerun, retry, `@dependabot rebase`, or `@dependabot recreate` | Manually rerun the workflow or issue the applicable Dependabot command on the PR. | Recovers from some transient states, stale heads, merge conflicts, or broken generated updates. | It does not grant missing permissions or repair incorrect repository auto-merge and branch settings. | Retained only as manual recovery, not as merge coordination.

### 1. `gh pr merge --auto` after validation

The first implementation waited for the build and delegated auto-merge through GitHub CLI:

```yaml
dependabot-pr-auto-merge:
  needs: build
```

```bash
gh pr merge --auto --rebase "$PR_URL"
```

Later versions added a merge-method input and protected the tested head:

```bash
gh pr merge \
  --auto \
  --match-head-commit "$PR_HEAD_SHA" \
  --squash \
  "$PR_URL"
```

Advantages:

- Very little custom code.
- Uses the GitHub-supported CLI path.
- `--match-head-commit` prevents a later Dependabot push from being merged under an earlier CI result.

Disadvantages:

- When the merge job starts after all required checks, the PR may already be immediately mergeable.
  `gh pr merge --auto` can then perform or initiate the merge rather than merely register future intent.
- Native auto-merge is available only when repository settings allow it and an unmet branch requirement exists.
- It did not provide an explicit fail-closed distinction between registration and immediate merging.

The current workflow uses the GraphQL enable-only mutation to make that distinction explicit.
See the [`gh pr merge` manual](https://cli.github.com/manual/gh_pr_merge).

### 2. Caller-selected auto-merge or immediate merge

To support both protected and unprotected repositories, the reusable build workflows exposed a
`dependabot-use-auto-merge` input:

```bash
merge_args=(
  "$merge_method_flag"
  --match-head-commit "$PR_HEAD_SHA"
)
if [[ "$DEPENDABOT_USE_AUTO_MERGE" == "true" ]]; then
  merge_args+=(--auto)
fi
gh pr merge "${merge_args[@]}" "$PR_URL"
```

Advantages:

- Worked with repositories that intentionally had no protected branch.
- Let each caller choose whether GitHub should wait for branch requirements.
- Kept the PR-head safety check in both modes.

Disadvantages:

- Every consumer had to understand subtle repository policy and configure the correct boolean.
- `false` meant an immediate merge after CI, while `true` depended on native auto-merge being available.
- Configuration drift could change safety behavior without changing the shared workflow.
- The immediate path retained the concurrent-merge and workflow-file permission problems described below.

This input was removed when protected branches and native auto-merge became the explicit contract.

### 3. Direct REST merge after validation

The most explicit immediate-merge implementation called the REST endpoint and supplied the tested PR head:

```bash
gh api \
  --method PUT \
  "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/merge" \
  --field sha="$PR_HEAD_SHA" \
  --field merge_method="$MERGE_METHOD" \
  --jq '.message'
```

Advantages:

- Works without repository auto-merge or required status checks.
- The `sha` field prevents merging a PR head that differs from the one CI validated.
- The response clearly reports whether the merge completed.
- Squash and rebase behavior map directly to the REST API.

Disadvantages:

- The workflow, rather than GitHub native auto-merge, owns the final merge attempt.
- The `sha` field protects the PR head, not the target branch.
  Another PR can update the target branch after validation.
- Concurrent PRs can reach the endpoint together and expose base-branch or permission edge cases.
- Merging a PR that changes `.github/workflows/**` can fail because `GITHUB_TOKEN` is a GitHub App installation
  token without the separate GitHub App **Workflows** permission.

Typical observed failure:

```text
gh: refusing to allow a GitHub App to create or update workflow
`.github/workflows/build.yml` without `workflows` permission (HTTP 403)
```

Adding this workflow permission did not solve that failure:

```yaml
permissions:
  actions: write
```

`actions: write` controls the Actions API, such as cancelling a workflow run.
It is not the GitHub App **Workflows** repository permission used to create or update files under
`.github/workflows/**`.
That experiment used the direct REST merge endpoint, which immediately performs the workflow-file update.
It therefore does not contradict the later reports that `actions: write` can allow the GraphQL
`enablePullRequestAutoMerge` mutation to register native auto-merge.
The latter behavior remains undocumented and may be a backend compatibility rule rather than a supported
permission mapping.
See GitHub's [workflow permission reference](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions),
[GitHub App permission guidance](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app),
GitHub CLI [issue #11493](https://github.com/cli/cli/issues/11493), and
[Community discussion #108402](https://github.com/orgs/community/discussions/108402).

The REST endpoint itself remains valid and supports an expected `sha`.
See [Merge a pull request](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request).
It was removed here because native auto-merge avoids making this direct workflow-file update through the job token.
That avoids the failing REST path but does not guarantee that GraphQL registration will bypass GitHub's
workflow-file authorization check.

### 4. Optional GitHub App token

The workflow was prepared to mint a short-lived installation token with the additional permission:

```yaml
- uses: actions/create-github-app-token@<pinned-commit>
  with:
    client-id: ${{ inputs.github-app-client-id }}
    private-key: ${{ secrets.GITHUB_APP_PRIVATE_KEY }}
    permission-contents: write
    permission-pull-requests: write
    permission-workflows: write
```

Advantages:

- Can request permissions that are not available through the workflow `GITHUB_TOKEN` permission list.
- Produces a short-lived installation token scoped to the current repository.
- Could make the direct REST route work for workflow-file updates in configurations where the built-in token could not.

Disadvantages:

- Every repository needs an App installation and access to the App client ID.
- Dependabot-triggered workflows require the private key as a Dependabot secret, not only as an Actions secret.
- Key rotation and App permission changes become operational responsibilities.
- The App expands the trust boundary of a workflow intended only to register a merge.
- GitHub has reported workflow-file restrictions even for Apps configured with the Workflows permission in some
  fork/update-branch scenarios; see [Community discussion #108402](https://github.com/orgs/community/discussions/108402).

The prototype failed early on partial configuration:

```text
GitHub App Client ID and private key must be configured together.
```

This was intentional, but it added another failure mode to every caller.
The native-only design removed the need for App credentials instead of making them mandatory.

### 5. Protected-branch routing

Another version selected GraphQL or REST from the target branch's reported protection state:

```bash
encoded_base_ref=$(jq -rn --arg value "$PR_BASE_REF" '$value | @uri')
branch_is_protected=$(gh api \
  "repos/$GITHUB_REPOSITORY/branches/$encoded_base_ref" \
  --jq '.protected')

case "$branch_is_protected" in
  true)  enable_native_auto_merge ;;
  false) merge_directly_with_rest ;;
esac
```

Advantages:

- Made protected and unprotected behavior explicit.
- Used native auto-merge where branch protection existed.
- Preserved direct merging for repositories without protection.

Disadvantages:

- Maintained two merge implementations with different timing, permissions, and failure behavior.
- A protected flag does not by itself prove that a required check is still pending when registration occurs.
- The unprotected route still needed the direct-merge and optional-App machinery.
- Callers could not reason about one stable contract from the workflow name alone.

Typical GraphQL failures seen while developing this route were:

```text
gh: Auto merge is not allowed for this repository
```

```text
gh: Pull request Pull request is in unstable status
```

The first message means the repository or PR is not eligible for native auto-merge.
The second was observed when registration ran after validation, but GitHub's message does not identify which
mergeability condition produced the unstable state.
The current ordering avoids claiming a more specific root cause than the API reported: it registers while a known
required validation check is pending.

### 6. Registration after validation with the registration check required

One design kept `needs: build` and made the auto-merge registration check itself required.
While that job was running, its own required check was pending, allowing the enable-only mutation to register
auto-merge after validation had already passed.

Advantages:

- Validation definitely completed before registration was attempted.
- The mutation still delegated the final merge to GitHub.
- A registration failure left the PR open.

Disadvantages:

- The registration job became part of the branch policy solely to create its own unmet condition.
- Reusable workflow check names differ depending on whether the outer caller or inner job is skipped.
  Human-authored PRs could remain blocked on a nested check that was never reported.
- Repository configuration had to select the correct generated nested check name.
- The self-referential required check was difficult to explain and easy to configure incorrectly.

The typical UI symptom is:

```text
Expected - Waiting for status to be reported
```

GitHub users report the reusable-workflow check-name problem in
[Community discussion #72708](https://github.com/orgs/community/discussions/72708).
The current design reverses the dependency: required validation waits briefly for registration instead of making
registration depend on validation.

### 7. Concurrency groups

Concurrency was explored because direct merge attempts from several Dependabot PRs appeared to race.

#### One repository-wide group

```yaml
concurrency:
  group: dependabot-pr-auto-merge-${{ github.repository }}
  cancel-in-progress: false
```

Advantage:

- Ensures only one merge job runs at a time.

Disadvantage:

- With the default `queue: single`, only one run may be pending.
  A newly queued run replaces the older pending run even when `cancel-in-progress` is `false`.
  A burst of Dependabot PRs can therefore leave only the running and newest jobs alive.

#### One group per PR

```yaml
concurrency:
  group: dependabot-pr-auto-merge-${{ github.repository }}-${{ github.event.pull_request.number }}
  cancel-in-progress: false
```

Advantage:

- Prevents a new run for one PR from cancelling a pending run for another PR.

Disadvantage:

- Different PRs run concurrently, so it does not serialize the direct merge operations that motivated the group.

#### Repository-wide queue

GitHub later added an explicit multi-entry queue:

```yaml
concurrency:
  group: dependabot-pr-auto-merge-${{ github.repository }}
  queue: max
  cancel-in-progress: false
```

Advantages:

- Serializes jobs while retaining up to 100 pending runs.
- Avoids the default replacement of an older pending run.

Disadvantages:

- actionlint 1.7.12 does not yet recognize `queue`, producing this false positive:

  ```text
  unexpected key "queue" for "concurrency" section
  ```

- It delays independent PRs and adds a repository-wide bottleneck.
- It is unnecessary when each job only registers native auto-merge and GitHub coordinates final merges.

`queue: max` is valid GitHub syntax; the linter lag is tracked by
[actionlint issue #657](https://github.com/rhysd/actionlint/issues/657).
See [GitHub's concurrency documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
for the current queue semantics.

### 8. Limiting Dependabot to one open PR

This repository-level workaround was considered:

```yaml
# .github/dependabot.yml
updates:
- package-ecosystem: github-actions
  directory: /
  schedule:
    interval: weekly
  open-pull-requests-limit: 1
```

Advantages:

- Reduces concurrent Dependabot PRs for that update configuration.
- Requires no merge-job synchronization.

Disadvantages:

- Serializes update discovery instead of fixing merge coordination.
- Delays later dependency updates until the open PR is closed or merged and Dependabot runs again.
- Must be repeated in every consumer repository and for each relevant update configuration.
- Does not prevent concurrency across multiple Dependabot update configurations or ecosystems.

It was rejected as an operational throttle rather than a merge solution.

### 9. Retry, rerun, rebase, or recreate

Retries and Dependabot commands such as `@dependabot rebase` or `@dependabot recreate` are useful for stale heads,
merge conflicts, or a broken generated update.
They do not add the GitHub App Workflows permission and cannot reliably fix a permission-based REST merge failure.

Likewise, manually rerunning a Dependabot-triggered workflow does not grant the rerunning user's permissions to the
job; GitHub reruns it with the original Dependabot-triggered privileges.
See [Dependabot on GitHub Actions](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-on-actions).

These commands remain valid recovery tools, but they are not part of the merge design.

## Observed error catalogue

The following messages were observed during this project's experiments or reported by the linked external sources.
Historical run logs may eventually expire or require authentication.

| Message | Context | Current interpretation
| ------- | ------- | ----------------------
| `Auto merge is not allowed for this repository` | GraphQL registration | Repository auto-merge is disabled or the repository/PR is otherwise ineligible. The workflow leaves the PR open.
| `Pull request Pull request is in unstable status` | GraphQL registration after validation | GitHub rejected the PR's current mergeability state. The message did not expose the precise unmet condition.
| `refusing to allow a GitHub App to create or update workflow ... without workflows permission (HTTP 403)` | Direct REST merge of a workflow-file update | The merge crossed GitHub's workflow-file trust boundary. `actions: write` did not supply the missing GitHub App **Workflows** permission on this path.
| `refusing to allow a GitHub App to create or update workflow ... without workflows permission (enablePullRequestAutoMerge)` | GraphQL registration of a workflow-file update | GitHub applied the workflow-file authorization check while registering native auto-merge. `actions: write` has resolved this in public examples, but GitHub does not document that mapping; failure leaves the PR open.
| `Expected - Waiting for status to be reported` | Required nested reusable-workflow check | The configured required check name was not emitted, commonly because the reusable caller was skipped under a different check name.
| `unexpected key "queue" for "concurrency" section` | actionlint 1.7.12 | Linter lag for GitHub's supported `concurrency.queue` property.
| `PR is not from Dependabot, nothing to do` | `dependabot/fetch-metadata` | The action rejected the event as non-Dependabot. This occurred on an apparently Dependabot-authored PR; the root cause was not established and should not be attributed to concurrency without more evidence.

Examples observed during this project's experiments:

- [`dependabot/fetch-metadata` rejected an apparently Dependabot-authored PR](https://github.com/sebthom/previewer-eclipse-plugin/actions/runs/32604818843/job/97108527657?pr=54)
- [A direct merge failed with the workflow permission error](https://github.com/vegardit/docker-meshcentral/actions/runs/32672738846/job/97276179390?pr=38)
- [A native auto-merge registration failed with unstable status](https://github.com/vegardit/docker-meshcentral/actions/runs/32745934131/job/97492000833?pr=38)
- [One concurrent direct-merge run failed](https://github.com/vegardit/docker-gitea-ext/actions/runs/32664564131/job/97256040030?pr=34)
  while [another PR in the same repository merged](https://github.com/vegardit/docker-gitea-ext/actions/runs/32664562755?pr=35)
- [A Dependabot rebase command used as manual recovery](https://github.com/futures4j/futures4j/pull/60#issuecomment-5316933465)

External reports used to evaluate workflow-file registration:

- [GraphQL registration produced the workflow permission error](https://github.com/cli/cli/issues/11493).
- [A workflow-file update auto-merged after `actions: write` was added](https://github.com/open-contracting/kestrel/pull/8).

## Why the current design is intentionally narrower

The experiments attempted to support protected and unprotected branches, immediate and delayed merges, two APIs,
optional App authentication, and custom serialization in one reusable workflow.
Each additional route made the caller contract and failure behavior harder to verify.

The current workflow has one policy:

1. Register native auto-merge for an eligible Dependabot PR while required validation is pending.
1. Pin registration to the current PR head.
1. Let required checks gate the final merge.
1. Let GitHub coordinate concurrent final merges.
1. Fail without directly merging when that policy cannot be registered.

This narrower contract requires branch protection, but it removes the permission-sensitive direct merge and the
custom concurrency mechanisms that produced most of the observed complexity.
