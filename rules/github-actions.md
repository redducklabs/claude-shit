---
paths:
  - ".github/workflows/**"
  - ".github/actions/**"
---

# GitHub Actions

- Don't change a workflow's `runs-on` unless I ask, and don't assume a runner needs changing.
- Self-hosted `runs-on: redducklabs-runners` is used only in private repositories. Public repositories use GitHub-hosted runners, and some private repositories do too. Why: in a public repository, pull requests from forks could run code on our self-hosted runners.
