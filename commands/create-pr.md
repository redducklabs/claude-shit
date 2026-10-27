---
description: Create PR with auto-generated description and optional monitoring
argument-hint: [pushed|all] (default: pushed)
allowed-tools: Bash(git add:*), Bash(gh:*)
---

Create a pull request for the current branch with an automatically generated description.

**Argument:**
- `pushed` (default): Use only pushed commits for PR
- `all`: Include all commits (push unpushed commits first)

**Workflow:**

1. **Determine scope based on argument:**
   - If $1 is empty or "pushed": Use only pushed commits (DO NOT MAKE ANY NEW COMMITS)
   - If $1 is "all": Push any unpushed commits first with `git push`
   - For "pushed" mode: Check for unpushed commits with `git log @{u}..HEAD`
     - If unpushed commits exist, warn user and suggest using `/create-pr all`

2. **Analyze commits for PR description:**
   - Get current branch: `git branch --show-current`
   - Get commit history: `git log origin/main..HEAD --oneline`
   - Get detailed diff summary: `git diff origin/main...HEAD --stat`
   - Review commit messages to understand what was done
   - Extract any ticket/issue references (formats: #123, PROJ-456, issue #789, etc.)

3. **Create the PR:**
   - Generate a concise title summarizing the main changes
   - Create description with:
     - Brief summary of changes (2-4 sentences)
     - Ticket links section (if tickets found - format as markdown links)
     - Test plan or key changes
   - **NEVER include Claude attribution** (no "Generated with Claude Code", no "Co-Authored-By: Claude")
   - **NEVER include time estimates** (no implementation timelines, no "X weeks", no duration estimates)
   - Use `gh pr create` with heredoc for the description

4. **After PR creation:**
   - Display the PR URL
   - Use AskUserQuestion to ask: "Would you like me to monitor the PR checks and help fix any issues that arise?"
   - If yes: Monitor checks with `gh pr checks` and proactively fix failures
   - If no: Task complete

**Requirements:**
- MUST use `gh` CLI for GitHub operations (never Fetch/WebFetch)
- NEVER add Claude attribution to PR description (no "Generated with Claude Code", no "Co-Authored-By: Claude")
- NEVER add time estimates to PR description (no timelines, no duration estimates)
- Extract ticket references from commit messages automatically
- Follow project's PR conventions if CLAUDE.md specifies any
- If `pushed` use ONLY PUSHED COMMITS do not make any new commits
- If monitoring is requested, continue until ALL checks are green
