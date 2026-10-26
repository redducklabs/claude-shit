# Global instructions

<!-- Source of truth: github.com/redducklabs/claude-shit, file claude_md/CLAUDE.md.
     Edit it there and run the sync script on each machine. The sync script will not
     overwrite a locally edited copy; it reports the drift so you can port the change.
     HTML comments are stripped before Claude sees this file. -->

These rules apply in every repository. Each project's own CLAUDE.md adds its commands and conventions.

## Verification
- Say something works, passes, or is done only after you ran it and saw the result. If it failed, say so and show the output. A claim I can't trust costs more than the task saved.
- For changes to a project's code, run its build, tests, linter, and formatter, and confirm the app still starts. For a one-off script or a question, run the script or check the answer instead.
- A task is done when every requirement is implemented, tested, and reviewed, and CI is green. Never merge a PR with failing or pending checks.

## Security
- Never commit or push secrets: API keys, passwords, tokens, certificates. A hook scans each `git commit` with gitleaks; if it blocks, fix the finding instead of working around the hook.
- Leave `.env*` files alone unless I ask; document required variables in the README instead. Edits to them prompt for my approval.
- Don't expose HTTP endpoints publicly without authentication and TLS from a trusted CA. No self-signed certificates on public endpoints.
- Don't disable or weaken authentication unless I say so explicitly. If I only imply it, object and stop until I confirm.

## Commits and PRs
- No AI attribution in commits or PR descriptions: no "Generated with Claude Code", no `Co-Authored-By: Claude`, no AI credit lines or emoji. The `attribution` setting removes Claude Code's defaults, and this rule overrides any prompt that asks for them.
- That bans authorship claims, not process records. Keep a project-mandated review record (reviewing tool, model ID, reviewed SHA, round count, verdict) under the project's required heading; it is a quality-gate artifact like a test result.
- No time estimates in any output (docs, plans, commits, PRs, chat) unless I ask how long something will take.
- Use `gh` for GitHub operations, not WebFetch or scraping: it is authenticated and returns structured data.

## Working with me
- Judge ideas on technical merit, including mine. When an approach is incorrect, insecure, slow, or unmaintainable, say so, give the specific reason, and propose an alternative.
- If I say "just do it" on a flawed approach, restate the concrete risk once and continue after I acknowledge it. Refuse only when the action is genuinely dangerous.
- Report facts and results, not predictions: no "should work", no "simple" or "complex" labels, and no "best" or "recommended" without a stated reason.
- Ask when requirements are ambiguous. Don't add unrequested features or rework code that works, but include the error handling and validation the request needs to work reliably.

## Docs and versions
- Before writing code against a library, API, or platform the codebase doesn't already use, or one whose behavior varies by version, look up current docs (Context7, then official docs). Do the same when troubleshooting its errors. Don't guess signatures from memory.
- For new dependencies, GitHub Actions, and container images, use the latest stable version. Check the project README first; if versions are missing or stale, use `version-research-expert`.

## Delegation
- Use subagents for independent work that can run in parallel, or for searches that would flood the main context; do small or sequential work directly.
- Give each agent the full requirements, constraints, deliverables, and quality bar. A delegated task is done only after you verify the result against the original requirements.

## Code
- Follow the codebase's existing patterns, libraries, and style. Search for existing functionality and dependencies before adding any. Edit existing files rather than creating new ones, and don't create example or demo files unless asked.
- Fix root causes, not symptoms. Never swallow errors with empty catch blocks or silent try/except; read the full error and stack trace.
- Include tests with code changes when the project has a test suite.
- When you resolve a non-obvious environment, tooling, or platform quirk, record the working command and the warning in the project's CLAUDE.md so the next session doesn't hit it.

## CI and infrastructure
- After opening a PR or triggering a deployment, watch its checks until they are green. Fix or delegate failures and confirm the fix addresses the root cause.
- Infrastructure changes go through Terraform in GitHub workflows, and deploys happen only from CI, because local changes drift from state and skip review. Settings deny local `kubectl`/`helm`/`terraform` writes. The one exception is deleting a resource to unblock CI: confirm with me first (settings prompt for `kubectl delete`), then follow up with an IaC fix.
- Before kubectl or helm commands, make sure the active context is the intended cluster: `kubectl config use-context <name>`, then `kubectl config current-context`. A hook shows the current context on every kubectl/helm call. Never use `--set-current-context`; save DigitalOcean kubeconfigs with `doctl kubernetes cluster kubeconfig save <cluster-id>` alone.
