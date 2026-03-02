# User Documentation — Developer & Claude Instructions

This directory contains a generic, pluggable user documentation pattern. Drop it into any project and customize the placeholders to get:

1. **In-app help** — A build script (`scripts/build_help_docs.js`) converts markdown to HTML at build time and bundles it into the frontend as a JSON manifest. Supports RBAC-based visibility filtering.
2. **External documentation platform** — A publish script (`scripts/publish_docs.py`) pushes markdown to a configurable backend (ClickUp, Confluence, etc.). Strips YAML frontmatter before uploading; HTML comment markers are invisible in rendered output.

---

## Customization Checklist

Before using this pattern in a new project, complete these steps:

- [ ] **Define your categories** — Edit `scripts/help-docs.config.json` to list your category directories, titles, and sort order
- [ ] **Define your RBAC tiers** — Replace the generic tiers (`all`, `member`, `admin`) with your project's roles. Update the visibility tier table below and the section marker regex in the build script if adding new tiers
- [ ] **Set your app URL** — Replace `{APP_URL}` references with your local dev URL (e.g., `http://localhost:3000`)
- [ ] **Set your docs directory** — Ensure `docsDir` in `help-docs.config.json` points to where your markdown lives
- [ ] **Configure the publisher** — Set `PUBLISH_TARGET` env var and the publisher-specific env vars (see `scripts/publishers/`)
- [ ] **Configure the workflow** — Copy `.github/workflows/publish-user-docs.yml` into your project and set the required secrets/vars
- [ ] **Configure credentials** — Document test credentials for each RBAC role in your project's `.env` or equivalent
- [ ] **Install JS dependencies** — The build script requires `gray-matter` and `marked` (`npm install gray-matter marked`)
- [ ] **Install Playwright MCP** — Required for Claude to navigate and screenshot the app (`claude mcp add playwright npx @playwright/mcp@latest`)

---

## Directory Structure

- **Subdirectories** map to categories in the in-app help sidebar and to docs on the external platform
- **`.md` files** in subdirectories become pages within that category/doc
- **`README.md` files** are excluded from both publishing targets
- **`images/`** subdirectories hold screenshots per category

### Registered Categories

Subdirectory names must match a registered category in `scripts/help-docs.config.json`. Define your project's categories there:

| Directory | Display Title | Order |
|-----------|--------------|-------|
| `{CATEGORY_SLUG}` | {Category Title} | {N} |

**Example:**

| Directory | Display Title | Order |
|-----------|--------------|-------|
| `getting-started` | Getting Started | 1 |
| `accounts` | Accounts | 2 |
| `settings` | Settings | 3 |

**To add a new category:** Add an entry to the `categories` object in `scripts/help-docs.config.json`, then create the matching subdirectory in your docs folder.

Unregistered directories are skipped by the build script with a warning. They still publish to the external platform normally.

## YAML Frontmatter — MANDATORY

Every `.md` file **must** have YAML frontmatter with three fields:

```yaml
---
title: "Page Title Here"
visibility: member
order: 2
---
```

| Field | Required | Values | Purpose |
|-------|----------|--------|---------|
| `title` | Yes | Any string | Page title in the help sidebar and content header |
| `visibility` | Yes | `all`, `member`, `admin` | Minimum RBAC tier required to see this page |
| `order` | Yes | Integer | Sort order within its category (lower = first) |

### Visibility Tiers

Define your project-specific roles here. The generic tiers are:

| Tier | Who sees it |
|------|-------------|
| `all` | Every authenticated user |
| `member` | Users with member-level permissions |
| `admin` | Users with admin-level permissions |

Replace these with your actual RBAC roles. Superusers / system owners typically see everything regardless of tier.

**Choosing the right tier:** Set visibility to the *lowest* tier that should see the page. If a page is mostly for members but has an admin-only section, set the page to `member` and use section markers (below) for the admin content.

### What happens without frontmatter

The build script falls back to `visibility: "all"`, `order: 99`, and derives the title from the filename. **Do not rely on this** — always provide explicit frontmatter so visibility is intentional.

## Section Visibility Markers

For pages where most content targets one tier but specific sections target a higher tier, use HTML comment markers to wrap the restricted sections:

```markdown
## Features Everyone Can Use

Content visible to all users of this page...

<!-- help:admin -->
## Admin-Only Features

This section only renders for admin-tier users, even though
the page itself is visible to members.
<!-- /help:admin -->

## More General Content

Back to content visible to all page viewers...
```

### Marker Rules

- Opening: `<!-- help:{tier} -->` — Supported tiers: `member`, `admin` (customize in the build script regex)
- Closing: `<!-- /help:{tier} -->` — Must match the opening tier
- Markers must be on their own line (not inline with other content)
- Sections can contain any markdown: headings, images, lists, code blocks
- Nesting markers is **not supported** — keep it flat
- Unmarked content inherits the page's `visibility` tier from frontmatter
- HTML comments are invisible in most external platform renderers

### When to use section markers vs. separate pages

- If a section is substantial (multiple headings, screenshots, detailed steps), make it a **separate page** with higher `visibility`
- If a section is a short note or paragraph within a broader topic, use **section markers**

## Images

Place screenshots in an `images/` subdirectory within the category folder. Reference with relative paths:

```markdown
![Screenshot](./images/dashboard.png)
```

The build script rewrites these to `{HELP_ROUTE_PREFIX}-images/{category}/filename.png` for the in-app viewer. Images are uploaded to the external platform automatically during publishing.

## Inter-Document Links

Link to other docs using relative markdown paths:

```markdown
See [Getting Started](./getting-started.md) for details.
See [Admin Settings](../settings/admin-settings.md) for the admin view.
```

The build script rewrites `.md` links to in-app routes (e.g., `/help/settings/admin-settings`). The external platform uses its own internal linking.

## Companion Scripts

| Script | Purpose |
|--------|---------|
| `scripts/publish_docs.py` | Push markdown to external platform (ClickUp, Confluence, etc.) |
| `scripts/build_help_docs.js` | Convert markdown to JSON manifest for in-app `/help` |
| `scripts/help-docs.config.json` | Configuration for the build script (categories, paths, prefix) |
| `scripts/publishers/` | Pluggable publisher adapters |
| `.github/workflows/publish-user-docs.yml` | CI workflow to auto-publish on push to main |

### Publishing

Run the publish workflow manually from GitHub Actions ("Publish User Documentation" → "Run workflow"), or push changes to `docs/user_documentation/**` on main to trigger automatically.

CLI usage:

```bash
# List available publisher backends
python scripts/publish_docs.py --list-targets

# Dry-run (validate config without publishing)
python scripts/publish_docs.py --dry-run

# Publish with defaults (reads PUBLISH_TARGET env var)
python scripts/publish_docs.py

# Publish to a specific target
python scripts/publish_docs.py --target clickup --docs-dir ./docs/user_documentation
```

---

## How Claude Must Create User Documentation

**This section defines the mandatory process Claude must follow when creating or updating user documentation.** No shortcuts. No guessing. The documentation must reflect the real user experience.

### Why This Process Exists

User documentation written by reading source code alone is inaccurate and misleading. Code shows what _should_ happen; the actual UI shows what _does_ happen. Labels, button text, navigation paths, layout, and behavior can differ from what code suggests. Claude **must** use the Playwright MCP tool to navigate the actual running application as a real user would, taking screenshots and verifying every step before writing documentation.

### Prerequisites

Before starting any documentation task, Claude must:

1. **Verify the Playwright MCP tool is available.** The entire documentation process depends on Playwright MCP for browser automation. Claude must check whether Playwright MCP tools (e.g., `mcp__playwright__browser_navigate`, `mcp__playwright__browser_snapshot`) are available in the current session.

   **If Playwright MCP tools are NOT available**, Claude must stop and help the user install it before proceeding. Walk the user through the appropriate setup:

   **Claude Code (CLI):**
   ```bash
   claude mcp add playwright npx @playwright/mcp@latest
   ```

   **VS Code (Claude extension / Copilot):**
   ```bash
   code --add-mcp '{"name":"playwright","command":"npx","args":["@playwright/mcp@latest"]}'
   ```

   Or add manually to VS Code's MCP settings (JSON):
   ```json
   {
     "mcpServers": {
       "playwright": {
         "command": "npx",
         "args": ["@playwright/mcp@latest"]
       }
     }
   }
   ```

   **Other MCP clients (Cursor, Windsurf, Claude Desktop, etc.):** Add this to the client's MCP server configuration:
   ```json
   {
     "mcpServers": {
       "playwright": {
         "command": "npx",
         "args": ["@playwright/mcp@latest"]
       }
     }
   }
   ```

   **Requirements:** Node.js 18 or newer must be installed. After adding the MCP server, the user may need to restart their editor or CLI session for the tools to become available.

   **Useful Playwright MCP options** (append to the `args` array):
   - `--headless` — Run the browser in headless mode (headed/visible by default)
   - `--browser <type>` — Choose browser: `chrome`, `firefox`, `webkit`, or `msedge`
   - `--viewport-size <WxH>` — Set viewport dimensions, e.g., `1280x720`

   **Do not proceed with documentation until Playwright MCP tools are confirmed working.** Try calling `mcp__playwright__browser_navigate` with a test URL to verify.

2. **Ensure the local environment is running.** Verify the application is accessible at `{APP_URL}`.

3. **Locate credentials.** Test credentials for each RBAC tier must be available. Check the project's `.env` file, `e2e/.env`, or equivalent for login credentials.

   Define your project's credential mapping here:

   | RBAC Role | Credential Source |
   |-----------|-------------------|
   | Member | `{describe where member credentials live}` |
   | Admin | `{describe where admin credentials live}` |

   Variable names in env files may not match RBAC role names exactly. Always cross-reference with the project's RBAC documentation for the authoritative role names.

   **If credentials are missing**, stop immediately and ask the user to provide credentials before proceeding. Do not attempt to create documentation without the ability to log in as the appropriate role.

4. **Determine which role(s) are relevant.** Read the task description to understand the feature area. Cross-reference with the project's RBAC/permissions documentation to identify which roles can access the feature. Log in as each relevant role during documentation.

### Step-by-Step Process

#### Phase 1: Codebase Investigation

Before touching the browser, understand the feature from the code side:

1. **Read the task description** to understand the scope and target audience.
2. **Find the relevant frontend components.** Use Glob and Grep to locate the components, pages, and routes for the feature area.
3. **Find the relevant backend views and URLs.** Check routing and API endpoint files to understand what data is available.
4. **Check RBAC.** Read the project's RBAC/permissions docs to know which roles can see/use the feature. This determines which credentials to use in Playwright.
5. **Check existing documentation.** Look at what already exists in the docs directory to avoid duplication and maintain consistency.

#### Phase 2: Live Application Navigation with Playwright

This is the critical phase. Claude must use the Playwright MCP tool to interact with the running application exactly as a user would.

1. **Navigate to the login page.**
   ```
   Use mcp__playwright__browser_navigate to go to {APP_URL}
   ```

2. **Log in with the appropriate role.** Use `mcp__playwright__browser_snapshot` to see the login form, then fill in credentials using `mcp__playwright__browser_fill_form` or `mcp__playwright__browser_type` and `mcp__playwright__browser_click`.

3. **Navigate to the feature area.** Use the sidebar, menus, or direct navigation as a real user would. Use `mcp__playwright__browser_snapshot` at each step to understand the current page state.

4. **Take screenshots at every significant step.** Use `mcp__playwright__browser_take_screenshot` with descriptive filenames saved directly to the documentation's `images/` subdirectory. For example:
   ```
   filename: "docs/user_documentation/sessions/images/session-list-page.png"
   ```

5. **Interact with the feature.** Click buttons, fill forms, open modals, expand dropdowns — do everything a user would do. Take screenshots of:
   - The initial page/view
   - Any forms or input areas (empty and filled)
   - Dropdown menus and their options
   - Confirmation dialogs or modals
   - Success/error messages
   - Any sub-tabs or secondary views

6. **Test with multiple roles if applicable.** Log out (or open a new browser context) and log in as a different role to document what that role sees differently. Note differences explicitly in the documentation.

7. **Verify navigation paths.** Document the exact clicks a user needs to make to reach each feature. Use snapshots to confirm sidebar labels, menu text, and button names match what you write in the documentation.

#### Phase 3: Writing the Documentation

With codebase knowledge AND real UI experience, write the markdown files:

1. **Use the correct directory structure.** Place files in a registered category subdirectory (see "Registered Categories" above). If the feature area doesn't have a category yet, add one to `scripts/help-docs.config.json` first.

2. **Writing standards:**
   - Write for non-technical users
   - Use plain, simple language — no jargon, no technical terms
   - Provide step-by-step instructions with numbered lists
   - Bold all UI element names exactly as they appear on screen (button text, menu items, tab names)
   - Include screenshots at logical points — after describing a set of steps, show what the user should see
   - Reference screenshots with relative paths: `![Description](./images/filename.png)`
   - Include tips and best practices where helpful
   - Cover common troubleshooting scenarios
   - For role-specific sections within a shared page, use `<!-- help:admin -->` / `<!-- /help:admin -->` markers instead of vague prose like "Administrators will also see..."

3. **File naming conventions:**
   - Use lowercase with hyphens: `submitting-hours.md`, `managing-users.md`
   - Names become page slugs in the URL (e.g., `/help/sessions/submitting-hours`)
   - Keep file names concise but clear

4. **Screenshot naming conventions:**
   - Descriptive, lowercase, hyphenated: `session-list-page.png`, `add-user-modal.png`
   - Always save to the `images/` subdirectory within the feature's documentation folder

5. **Content structure for each `.md` file:**
   ```markdown
   ---
   title: "Page Title"
   visibility: member
   order: 1
   ---

   # Page Title

   Brief description of what this page/feature does and who uses it.

   ## Getting There

   1. Step-by-step navigation instructions to reach this feature.
   2. Bold the exact text of each UI element clicked.

   ## [Main Feature Sections]

   Describe each section of the feature with steps and screenshots.

   <!-- help:admin -->
   ## Admin-Only Section (if applicable)

   Content that only admins should see on this page.
   <!-- /help:admin -->

   ## Tips

   - Helpful tips for using the feature effectively.

   ## Troubleshooting

   - Common issues and how to resolve them.
   ```

6. **Choosing `visibility` and `order`:**
   - Set `visibility` to the lowest tier that should see the entire page. Use section markers for higher-tier content within the page.
   - Set `order` relative to sibling pages in the same category. Check existing pages in the directory to pick the right number. Gaps are fine (1, 2, 5 is OK).

### What NOT to Do

- **Never create a `.md` file without YAML frontmatter.** Every file needs `title`, `visibility`, and `order`.
- **Never omit `visibility`** or default to `all` without thinking about who should see the page. Check RBAC docs.
- **Never put a file in an unregistered directory** without first adding the category to `scripts/help-docs.config.json`.
- **Never nest section visibility markers.** `<!-- help:admin -->` inside `<!-- help:member -->` is not supported.
- **Never write documentation from code alone.** Always verify with Playwright.
- **Never guess at UI labels or navigation paths.** Use snapshots to confirm exact text.
- **Never use technical language.** No "API endpoints", "components", "serializers", "database models". Write as if explaining to someone who only knows how to use a web browser.
- **Never skip screenshots.** Every major view and interaction needs a screenshot.
- **Never document features you haven't navigated to in the browser.** If you can't reach it via the UI, don't document it.
- **Never assume navigation paths.** The sidebar, menus, and page layouts may differ from what the code suggests. Always verify with Playwright.

### Example Workflow

Suppose the task is "Documentation: User Management":

1. **Investigate code:** Find user-management components in the frontend, check routes, check RBAC permissions.
2. **Check roles:** Member can view their own profile. Admin can manage all users.
3. **Open Playwright:** Navigate to `{APP_URL}`, log in as Member.
4. **Navigate:** Click through the sidebar to find where user settings live. Take a snapshot. Take a screenshot.
5. **Explore:** Open a profile, view details, try editing settings. Screenshot each step.
6. **Switch roles:** Log in as Admin, note any additional features or views. Screenshot differences.
7. **Write docs:** Verify the category is registered. Create files like `viewing-profile.md` with frontmatter:
   ```yaml
   ---
   title: "Viewing Your Profile"
   visibility: all
   order: 1
   ---
   ```
   For admin-only features within a shared page, wrap with `<!-- help:admin -->` markers. For fully admin-only pages, set `visibility: admin`.

### Credential Requirements Summary

Check the project's environment files for test credentials. Each RBAC role must have login credentials available.

**If credentials are missing or incomplete**, Claude must:

1. Stop the documentation task.
2. Inform the user that credentials are required for all relevant access levels.
3. Wait for the user to provide or update the credentials before proceeding.

Do not attempt to create user documentation without being able to log in and navigate the application.
