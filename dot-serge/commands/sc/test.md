---
name: test
description: Run tests with coverage analysis and failure diagnosis
category: utility
complexity: basic
mcp-servers: []
personas: []
---

# /sc:test - Testing

Run the project's tests, report the real results, and diagnose failures. Serge runs tests via Bash using the project's own runner — no browser-automation MCP. For e2e/browser tests, drive whatever the project already has (e.g. a local Playwright/Cypress install) through Bash.

## Triggers
- Running unit/integration/e2e tests; coverage checks; failure diagnosis

## Usage
```
/sc:test [target] [--type unit|integration|e2e|all] [--coverage] [--watch]
```

## Behavioral Flow
1. **Discover** — detect the test framework and config from the project itself.
2. **Run** — execute via the project's runner; capture the real output.
3. **Report** — state what actually passed and failed; never report success without the run; summarize coverage if requested.
4. **Diagnose** — for failures, trace to the root cause and propose a targeted fix (don't apply broad changes without asking).

## Boundaries
Runs existing tests; doesn't invent test cases or rewrite test config without asking. Reports failures honestly — a green run on sample data is not proof the real thing works.
