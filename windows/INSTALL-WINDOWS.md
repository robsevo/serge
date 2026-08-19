# Serge on Windows

Two ways to run Serge on Windows. **WSL2 is the recommended path** — it gives
100% parity with the Linux install, including systemd services, timers and the
autonomous loops. Native Windows (Git Bash) is a supported best-effort: the
interactive agent and its hooks work, the background automation is reduced.

---

## Option A — WSL2 (recommended, full parity)

Everything in the main README applies verbatim inside WSL.

1. **Install WSL2 + Ubuntu** (admin PowerShell):
   ```powershell
   wsl --install -d Ubuntu
   ```
2. **Enable systemd** inside the distro (needed for the router service and
   timers) — in the WSL terminal:
   ```bash
   sudo tee /etc/wsl.conf >/dev/null <<'EOF'
   [boot]
   systemd=true
   EOF
   ```
   Then from PowerShell: `wsl --shutdown`, and reopen Ubuntu.
3. **Copy this folder into WSL** (e.g. `/home/<you>/serge-portable` — keep it
   on the Linux filesystem, not `/mnt/c`, for speed) and follow the main
   README from "Install": `./install.sh`, fill the keys, enable the units.
4. **Timers only tick while WSL is running.** If you want the nightly loops,
   keep a WSL terminal open, or register a logon task that keeps the VM alive:
   ```powershell
   schtasks /Create /TN "WSL keepalive" /SC ONLOGON /TR "wsl.exe -d Ubuntu --exec sleep infinity"
   ```

That's it — router on `localhost:4000` inside WSL, `serge` in any WSL shell.

---

## Option B — Native Windows (Git Bash, best-effort)

**How this works:** the engine itself is cross-platform Node, and it executes
hooks **through Git Bash** on Windows (not cmd.exe) — so Serge's bash-based
brain (memory loaders, verify→review→gate pipeline, statusline) runs. Git Bash
ships the GNU tools the scripts use (`timeout`, `stat -c`, `sha256sum`).

**What you get:** the full interactive agent — hive routing, hooks, statusline,
`--council`, memory. The launcher auto-starts the router itself when systemd
is absent (spawns LiteLLM directly, logs to `~/.serge/monitor/router.log`).

**What you don't get natively:** the systemd automation — always-on router
supervision, the 5-min budget watchdog, nightly eval-gate / err-triage /
backlog loops (`flock` isn't in Git Bash). `register-serge-tasks.ps1` (below)
restores the two most useful pieces via Task Scheduler. For the loops, use WSL2.

### Steps

1. Install [Node.js 22+](https://nodejs.org), [Git for Windows](https://gitforwindows.org)
   (includes Git Bash), and [uv](https://docs.astral.sh/uv/), then in **Git Bash**:
   ```bash
   uv tool install 'litellm[proxy]'
   ```
2. Still in **Git Bash**, from this folder:
   ```bash
   ./install.sh
   ```
   (Detects Git Bash: installs `~/.serge`, rewrites paths to your Windows
   home, creates a `serge` launcher shim in `~/.local/bin` — no services.)
3. Fill in your keys:
   ```bash
   nano ~/.serge/router.env ~/.serge/serge.env
   ```
4. Run `serge` from Git Bash. First run auto-spawns the router (LiteLLM
   cold-boot ~30 s); check `curl -s localhost:4000/v1/models` if in doubt.
5. **Optional** — router at logon + budget watchdog every 5 min via Task
   Scheduler (regular PowerShell):
   ```powershell
   .\windows\register-serge-tasks.ps1
   ```
   Remove later with:
   ```powershell
   schtasks /Delete /TN "Serge router" /F; schtasks /Delete /TN "Serge budget watchdog" /F
   ```

### Native caveats

- Always launch `serge` from **Git Bash** (or Windows Terminal profile running
  Git Bash) — not cmd/PowerShell.
- If a hook errors with `command not found`, your Git Bash is missing a tool —
  update Git for Windows (older builds lacked `timeout`).
- The eval gate and loops are Linux/WSL-only; the PreToolUse constitution
  ratchet still runs (it's plain bash) but skips if its tools are missing.
