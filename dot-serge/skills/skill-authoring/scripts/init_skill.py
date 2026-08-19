#!/usr/bin/env python3
"""Scaffold or validate a serge house skill.

Usage:
  python3 init_skill.py NAME [--dir ~/.serge/skills]   create skeleton
  python3 init_skill.py --validate-only PATH           validate existing skill

Validation checks the house rules: kebab-case name matching the directory,
frontmatter with non-empty name/description/whenToUse, and a non-trivial body.
Exit code 0 = valid.
"""
import os
import re
import sys

KEBAB = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

TEMPLATE = """---
name: {name}
description: <what this skill does — one dense sentence>
whenToUse: <when to fire — name the concrete user phrases and situations, be a little pushy; models under-trigger. Also name what it must NOT fire for.>
---

# {title} — <one-line promise>

<Imperative instructions. Tables over prose walls. Deterministic steps go in
scripts/, long context in references/, output templates in assets/. Keep this
file under ~500 lines; push detail down with clear pointers.>
"""


def parse_frontmatter(text):
    if not text.startswith("---"):
        return None, "SKILL.md must start with `---` frontmatter"
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None, "unterminated frontmatter block"
    fm = {}
    key = None
    for line in parts[1].splitlines():
        if not line.strip():
            continue
        m = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", line)
        if m:
            key = m.group(1)
            fm[key] = m.group(2).strip()
        elif key and line.startswith((" ", "\t")):
            fm[key] += " " + line.strip()
    return (fm, parts[2]), None


def validate(skill_dir):
    errors = []
    name = os.path.basename(os.path.normpath(skill_dir))
    md = os.path.join(skill_dir, "SKILL.md")
    if not KEBAB.match(name):
        errors.append(f"directory name {name!r} is not kebab-case")
    if not os.path.isfile(md):
        return [f"missing {md}"]
    with open(md, encoding="utf-8") as f:
        text = f.read()
    parsed, err = parse_frontmatter(text)
    if err:
        return errors + [err]
    fm, body = parsed
    for field in ("name", "description", "whenToUse"):
        val = fm.get(field, "")
        if not val or val.startswith("<"):
            errors.append(f"frontmatter `{field}` missing or still a placeholder")
    if fm.get("name") and fm["name"] != name:
        errors.append(f"frontmatter name {fm['name']!r} != directory name {name!r}")
    if len(body.strip()) < 200:
        errors.append(f"body is only {len(body.strip())} chars — not a usable skill")
    if len(fm.get("description", "")) + len(fm.get("whenToUse", "")) > 1500:
        errors.append("frontmatter over ~1500 chars — it loads EVERY session, tighten it")
    return errors


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__.strip())
    if args[0] == "--validate-only":
        if len(args) < 2:
            sys.exit("--validate-only needs a skill directory path")
        errs = validate(os.path.expanduser(args[1]))
        if errs:
            print("INVALID:")
            for e in errs:
                print(f"  - {e}")
            sys.exit(1)
        print("valid")
        return
    name = args[0]
    if not KEBAB.match(name):
        sys.exit(f"ERROR: {name!r} is not kebab-case (lowercase, digits, hyphens)")
    base = os.path.expanduser("~/.serge/skills")
    if "--dir" in args:
        base = os.path.expanduser(args[args.index("--dir") + 1])
    skill_dir = os.path.join(base, name)
    if os.path.exists(os.path.join(skill_dir, "SKILL.md")):
        sys.exit(f"ERROR: {skill_dir}/SKILL.md already exists — edit it instead")
    os.makedirs(skill_dir, exist_ok=True)
    title = name.replace("-", " ").capitalize()
    with open(os.path.join(skill_dir, "SKILL.md"), "w", encoding="utf-8") as f:
        f.write(TEMPLATE.format(name=name, title=title))
    print(f"created {skill_dir}/SKILL.md")
    print("next: fill the frontmatter placeholders, then run "
          f"`python3 {sys.argv[0]} --validate-only {skill_dir}`")


if __name__ == "__main__":
    main()
