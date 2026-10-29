# AGENTS.md — JZM (just-zapret-manager) Engineering Guidelines

This document defines core architectural boundaries and safety invariants for anyone (human or LLM) contributing to `just-zapret-manager`.
The primary objective: guarantee that this tool can never brick an OpenWrt router, lock the user out of the LAN, or leave the system in a broken, half-applied state.

Development and all checks run in Linux / WSL2. Keep the working checkout on
the Linux filesystem (`~/src/just-zapret-manager`), not under `/mnt/c/`. Use native Linux
ucode, UCI, just and ShellCheck. `just test` runs static analysis, unit/integration
checks and emulator tooling selftests. `just test-e2e` builds the bundle and runs
the prepared OpenWrt emulator; `just emulator-setup` prepares its ignored assets.
Run `sh tools/test-matrix.sh` for the local ucode matrix.

---

## 1. Blast Radius & Access Whitelist

JZM manages the `zapret` package and designated integration hooks. It must never interfere with core network routing or local management.

### 1.1. Writable Paths (Strict Whitelist):
Writes are permitted strictly within:
- `/opt/zapret/` — Zapret installation, hostlists, fake payloads, and `custom.d` hooks.
- `/etc/zapret-manager/` — JZM state (`state.json`), catalog caches, and runtime flags.
- `/tmp/` — Temporary runtime files, lock sockets, build buffers, and test logs (RAM/tmpfs only).
- Explicit target files:
  - `/etc/config/zapret` (main UCI configuration).
  - `/usr/bin/jzm` (the installed executable).
  - `/usr/bin/jzm.previous` (the previous executable for rollback).
  - `/etc/zapret-manager/backups/` (managed backup files).
  - Lines tagged `# zapret-manager:zapret` in `/etc/crontabs/root`.
  - Specific firewall targets: named rules matching `firewall.jzm_*` and `@defaults[0].flow_offloading` / `@defaults[0].flow_offloading_hw` in `/etc/config/firewall`.

### 1.2. Forbidden Targets (Strict Read-Only):
Modifying the following paths is prohibited:
- `/etc/config/network` (interfaces, gateways, LAN, WAN, `br-lan` bridge).
- `/etc/config/dhcp` (DHCP pools, dnsmasq options, local domain mappings).
- `/etc/hosts` (system hosts file).
- SSH configuration (`/etc/config/dropbear`), system credentials, and Wi-Fi configurations.
- Management access via port 22 (SSH) and ports 80/443 (LuCI/uhttpd) on `br-lan` must remain functional regardless of service errors or network failures.

### 1.3. Firewall Modification Standards:
- Do not patch system firewall files or templates (such as `/usr/share/firewall4/templates/ruleset.uc`) using `sed`, `awk`, or raw text replacement.
- Apply firewall changes exclusively through standard OpenWrt primitives:
  1. Via UCI: configure named rules matching `firewall.jzm_*`.
  2. Via drop-in nftables hooks: place self-contained `.nft` files inside `/usr/share/nftables.d/`.
- **Reload vs. Restart Policy:**
  - Standard rule additions/removals (`firewall.jzm_*`) must use graceful reload (`/etc/init.d/firewall reload` or `fw4 reload`).
  - A full firewall restart (`/etc/init.d/firewall restart`) is permitted **only** when toggling `@defaults[0].flow_offloading` or `@defaults[0].flow_offloading_hw`, as recreating kernel flowtable hooks requires a full service cycle.

---

## 2. Resource Constraints: Flash & RAM

Target devices frequently run on 16–128 MB SPI-NOR/SPI-NAND flash with 64–128 MB of RAM.

### 2.1. Flash Storage Protection (/overlay and rootfs):
- Never write logs, benchmark dumps, or transient data to non-volatile storage. Keep all temporary files inside `/tmp/`.
- **Pre-flight storage check:** verify available capacity prior to pulling packages or binary payloads. Support both overlayfs and direct root mounts:
  ```sh
  target_dir="/overlay"
  [ -d "$target_dir" ] || target_dir="/"
  df -k "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}'
  ```
- Formula: require at least `(payload size * 2) + 5 MB`.
- Abort immediately if free space on the target partition drops below 5 MB. Filling flash to 100% breaks overlayfs and bricks the OS.
- Keep in mind that df -k reports in kilobytes; therefore, the 5 MB threshold must be checked as 5120 (KB), not 5.

### 2.2. RAM & OOM Protection:
- Avoid reading large lists (e.g., 50k+ domain entries) into a single string in ucode to execute `split('\n')`.
- Handle high-volume datasets via streaming or delegate deduplication and sorting to `/tmp/`-backed filesystem pipelines (`sort -u`).

---

## 3. Atomicity, Immutability & Idempotency

### 3.1. Strict Atomicity (All-or-Nothing / No Half-Applied States):
- Intermediate or partial configuration states are invalid.
- State changes must execute inside `transaction.sh`, preceded by snapshots of all managed files and the active service state.
- If an operation fails, encounters an uncaught exception, or receives an exit signal (`SIGINT`, `SIGHUP`, `SIGTERM`), it must roll back 100% of affected configuration files, firewall rules, and service states to the initial snapshot. Staged payloads (e.g., newly downloaded uncommitted `.bin` files) must be cleaned up on abort.
- **Package Manager Boundary:** Package management operations (`opkg install`, `apk add`) modify external system package databases and must be pre-validated and executed with pre-flight storage checks *before* entering configuration transactions. Configuration rollback does not attempt to roll back system package databases.

### 3.2. Immutability (Copy-on-Write):
- In-place modifications (`sed -i`, direct truncation, or streaming into live files via `>`) are forbidden.
- Follow Copy-on-Write for all updates:
  1. Read current state as read-only.
  2. Construct the target state in memory using pure functions.
  3. Write payload to a temporary file (`.tmp`) on the target filesystem.
  4. Verify non-zero file size and validate syntax.
  5. Atomically replace the destination using `mv -f`.

### 3.3. Idempotency:
- Rerunning any command with identical arguments must yield the exact same system state without accumulating side effects:
  - Deduplicate domain entries.
  - Keep `NFQWS_PORTS_TCP/UDP` lists unique (e.g., repeated runs must not expand `80,443` into `80,443,80,443`).
  - Do not create empty rule blocks or adjacent `--new` delimiters.

---

## 4. Quality Assurance & Testing Law (Non-Negotiable)

Code is strictly invalid until proven functional and safe. An automated test failure is not a warning; it is a blocker.

### 4.1. Shell Standards & Static Analysis:
- All shell components must strictly conform to POSIX `/bin/sh` (BusyBox `ash`) with `set -eu`.
- Bashisms, unquoted variable expansions in paths, and assumptions about optional utilities (e.g., standalone `stat`) are forbidden.
- **ShellCheck is Mandatory:** scripts must pass `shellcheck` with zero errors or warnings.
- All shell files must validate with `/bin/sh -n`.

### 4.2. Zero-Regression Test Suite:
- Every code modification must execute and pass the test suite:
  ```sh
  just test
  ```
- **100% Pass Rate:** all existing checks (including all unit checks in `unit.uc`) must succeed.
- Deleting, commenting out, or weakening test assertions to force a passing state is strictly prohibited.
- A build or commit that fails any test suite check is rejected by definition.
