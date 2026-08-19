---
name: system-integrity
description: Detects and prevents unauthorized modifications to core system and repository configuration files.
whenToUse: When verifying repository integrity, handling tampered core files, or securing configuration against accidental or malicious edits.
---

## Core Assets
Protect files that define repository identity and build behavior. Common targets include:
- `.git/config`
- `.git/description`
- `.gitignore`
- Dependency manifests (`package.json`, `Cargo.toml`, `go.mod`)
- Build scripts (`Makefile`, `CMakeLists.txt`)

## Detection
Check for unexpected modifications using Git.

**List modified tracked files:**
```bash
git status --porcelain
```

**Inspect specific sensitive files:**
```bash
git diff HEAD -- .git/description
```

**Verify file permissions:**
```bash
ls -l .git/config
```

## Remediation
Restore files to their trusted state immediately upon detection of tampering.

**Restore a specific file:**
```bash
git restore .git/description
# Or for older git versions:
git checkout HEAD -- .git/description
```

**Reset all core configuration changes:**
```bash
git checkout HEAD -- .git/config .git/description
```

## Hardening
Prevent future unauthorized writes by adjusting file system permissions.

**Make files
