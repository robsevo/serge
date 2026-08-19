---
name: remember
description: Save a durable fact to Serge's persistent memory (~/.serge/memory/)
---

# Remember this

Persist the fact below into Serge's memory at `~/.serge/memory/`, following the rules in the constitution's `## memory` section:

1. First read `~/.serge/memory/MEMORY.md` and check whether an existing fact file already covers this. If so, UPDATE that file instead of creating a duplicate.
2. Otherwise create a new `~/.serge/memory/<short-kebab-slug>.md` with frontmatter (`name`, `description`, `type: user|feedback|project|reference`, `source`) and the fact in the body. Attach a real `source` — a URL, a file path, or `user, <today's date>` — so it can be verified later.
3. Add or edit the one-line entry in `MEMORY.md` under `## Facts`: `- [Title](slug.md) — one-line hook`.
4. Keep it small: one fact per file, no duplication, and if the store is near ~100 facts, prune the stalest/lowest-value entry. Do not save secrets or anything reconstructable from the repo.

Confirm in one line what you saved (title + file) and stop.

Fact to remember:
$ARGUMENTS
