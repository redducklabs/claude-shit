# MCP Server Setup Guide

This guide covers installing and configuring MCP (Model Context Protocol) servers for Claude Code. It includes three commonly used servers — Playwright (browser automation), Context7 (documentation lookup), and PostgreSQL (database access) — and explains all three configuration methods.

---

## Configuration Methods

There are three ways to configure MCP servers, each with a different scope:

| Method | Scope | Location | Use When |
|--------|-------|----------|----------|
| **CLI** (`claude mcp add`) | Varies (default: local) | Writes to `~/.claude.json` | Quick one-off setup, interactive use |
| **Project** (`.mcp.json`) | All team members on this project | `<project-root>/.mcp.json` | Team collaboration, version-controlled |
| **User** (`~/.claude.json`) | You, across all projects | `C:\Users\<username>\.claude.json` | Personal tools shared across projects |

**Precedence** when the same server name exists at multiple scopes: local > project > user.

### Method 1: CLI (`claude mcp add`)

The fastest way to add a server. Options must come **before** the server name.

```bash
# Stdio server (local process)
claude mcp add <name> -- <command> [args...]

# Stdio with explicit scope
claude mcp add --scope user <name> -- npx -y @some/package

# HTTP server (remote)
claude mcp add --transport http <name> <url>

# HTTP with auth header
claude mcp add --transport http <name> <url> --header "Authorization: Bearer <token>"

# Manage servers
claude mcp list                     # List all configured servers
claude mcp get <name>               # Show details for one server
claude mcp remove <name>            # Remove a server
claude mcp reset-project-choices    # Reset .mcp.json approval choices
```

**Scope flag:**
- `--scope user` — Available in all your projects (`~/.claude.json`)
- `--scope project` — Only this project (`.mcp.json`)
- Default (no flag) — Local to you + this project (`~/.claude.json` under project path)

### Method 2: Project-Level `.mcp.json`

Create a `.mcp.json` file in your project root. This file is meant to be committed to version control so the whole team shares the same MCP servers.

```json
{
  "mcpServers": {
    "server-name": {
      "command": "npx",
      "args": ["-y", "@some/package"],
      "env": {
        "SOME_VAR": "${SOME_VAR}"
      }
    },
    "remote-server": {
      "type": "http",
      "url": "https://mcp.example.com/api",
      "headers": {
        "Authorization": "Bearer ${API_TOKEN}"
      }
    }
  }
}
```

**Notes:**
- Team members are prompted to approve `.mcp.json` servers on first use
- Environment variables use `${VAR}` syntax and expand at runtime
- Default fallbacks supported: `${VAR:-default_value}`

### Method 3: User-Level `~/.claude.json`

Edit `C:\Users\<username>\.claude.json` directly. Servers here are available across all your projects.

```json
{
  "mcpServers": {
    "server-name": {
      "command": "npx",
      "args": ["-y", "@some/package", "arg1"],
      "env": {}
    }
  }
}
```

The file may already contain other Claude Code settings. Just add or merge into the `mcpServers` object.

**Auto-approval setting** (also in `~/.claude.json`):
```json
{
  "enableAllProjectMcpServers": true
}
```

This skips the approval prompt for all `.mcp.json` servers across all projects.

---

## Server: Playwright MCP

Browser automation via accessibility tree (not pixels). Used for navigating web apps, taking screenshots, filling forms, and clicking elements.

**Package:** `@playwright/mcp@latest`
**Requires:** Node.js 18+

### Install

**CLI:**
```bash
claude mcp add playwright npx @playwright/mcp@latest
```

**CLI (user-scoped, available in all projects):**
```bash
claude mcp add --scope user playwright npx @playwright/mcp@latest
```

**.mcp.json:**
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

**~/.claude.json:**
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

### Options

Append these to the `args` array (or after the command in CLI):

| Flag | Description |
|------|-------------|
| `--headless` | Run browser without visible window |
| `--browser <type>` | `chrome`, `firefox`, `webkit`, or `msedge` |
| `--viewport-size <WxH>` | Viewport dimensions, e.g., `1280x720` |
| `--user-data-dir <path>` | Path to browser profile directory |
| `--isolated` | Keep profile in memory (no disk persistence) |
| `--storage-state <path>` | Load cookies/local storage from a JSON file |

**Example with options:**
```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest", "--headless", "--viewport-size", "1280x720"]
    }
  }
}
```

### Tools Provided

`browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_fill_form`, `browser_take_screenshot`, `browser_press_key`, `browser_select_option`, `browser_hover`, `browser_tabs`, `browser_evaluate`, `browser_wait_for`, `browser_console_messages`, `browser_network_requests`, `browser_close`, and more.

---

## Server: Context7

Up-to-date documentation and code examples for any library or framework. Resolves library names to IDs, then queries current docs.

**Package:** `@upstash/context7-mcp`
**Requires:** Node.js 18+
**Optional:** Free API key from context7.com/dashboard for higher rate limits

### Install

**CLI (no API key):**
```bash
claude mcp add context7 npx -y @upstash/context7-mcp
```

**CLI (with API key, user-scoped):**
```bash
claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp --api-key YOUR_API_KEY
```

**.mcp.json:**
```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

**.mcp.json (with API key):**
```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp", "--api-key", "YOUR_API_KEY"]
    }
  }
}
```

**~/.claude.json:**
```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

### Tools Provided

- `resolve-library-id` — Resolve a library name (e.g., "react") to a Context7 library ID
- `query-docs` — Query documentation for a specific library by ID

---

## Server: PostgreSQL

Read-only database access with schema inspection. Lets Claude query your database and understand its structure.

**Package:** `@modelcontextprotocol/server-postgres`
**Requires:** Node.js 18+, a running PostgreSQL instance

### Connection String Format

```
postgresql://<user>:<password>@<host>:<port>/<database>
```

### Install

**CLI:**
```bash
claude mcp add postgres npx -y @modelcontextprotocol/server-postgres "postgresql://user:password@localhost:5432/mydb"
```

On Windows, `npx` may need to be wrapped with `cmd /c`:

**CLI (Windows):**
```bash
claude mcp add postgres -- cmd /c npx -y @modelcontextprotocol/server-postgres "postgresql://user:password@localhost:5432/mydb"
```

**.mcp.json:**
```json
{
  "mcpServers": {
    "postgres": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-postgres",
        "postgresql://user:password@localhost:5432/mydb"
      ]
    }
  }
}
```

**.mcp.json (Windows — requires `cmd /c` wrapper):**
```json
{
  "mcpServers": {
    "postgres": {
      "command": "cmd",
      "args": [
        "/c",
        "npx",
        "-y",
        "@modelcontextprotocol/server-postgres",
        "postgresql://user:password@localhost:5432/mydb"
      ]
    }
  }
}
```

**~/.claude.json:**
```json
{
  "mcpServers": {
    "postgres": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-postgres",
        "postgresql://user:password@localhost:5432/mydb"
      ]
    }
  }
}
```

### Security Notes

- The connection string contains credentials — do **not** commit it to version control if it points to a real database
- Use environment variable expansion in `.mcp.json` to keep secrets out of the file:
  ```json
  {
    "mcpServers": {
      "postgres": {
        "command": "npx",
        "args": [
          "-y",
          "@modelcontextprotocol/server-postgres",
          "${DATABASE_URL}"
        ]
      }
    }
  }
  ```
- The server provides **read-only** access by default

### Tools Provided

- `query` — Execute a read-only SQL query against the connected database
- `list_tables` — List all tables in the database
- `describe_table` — Get the schema (columns, types, constraints) for a specific table

---

## Combined Example: All Three Servers

### `.mcp.json` (project-level, version-controlled)

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest"]
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    },
    "postgres": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-postgres",
        "${DATABASE_URL}"
      ]
    }
  }
}
```

### `~/.claude.json` (user-level, all projects)

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest"]
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

### CLI (one-liners)

```bash
claude mcp add --scope user playwright npx @playwright/mcp@latest
claude mcp add --scope user context7 npx -y @upstash/context7-mcp
claude mcp add postgres npx -y @modelcontextprotocol/server-postgres "postgresql://user:pass@localhost:5432/mydb"
```

---

## Troubleshooting

**Server not loading after `claude mcp add`:**
Restart your Claude Code session (close and reopen the CLI or editor).

**`npx` failing on Windows:**
Wrap with `cmd /c`: change `"command": "npx"` to `"command": "cmd"` and prepend `"/c", "npx"` to `args`.

**`.mcp.json` servers prompting for approval every time:**
Add `"enableAllProjectMcpServers": true` to `~/.claude.json`, or approve once and it's remembered.

**Playwright browser not installed:**
Call `mcp__playwright__browser_install` or run `npx playwright install chromium`.

**Context7 rate limited:**
Get a free API key from context7.com/dashboard and add `--api-key YOUR_KEY` to the args.

**PostgreSQL connection refused:**
Verify the database is running and the connection string is correct. Check host, port, username, and password.
