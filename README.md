# Clock Ticker

Clock Ticker is a lightweight Bash status generator for a Linux desktop panel.
It refreshes once per second, combines a clock with system-health indicators,
and atomically publishes one line of Pango markup to:

```text
$XDG_RUNTIME_DIR/clock-ticker/ticker.txt
```

By default, this is `/run/user/$(id -u)/clock-ticker/ticker.txt`. When
`XDG_RUNTIME_DIR` is set, that directory is used instead. The ticker verifies
that its internal runtime directory is backed by `tmpfs`. Keeping `ticker.txt`
at the default location is strongly recommended: `/run/user/$(id -u)` is
normally memory-backed and persists for the user's login session, so the
once-per-second publication does not generate unnecessary SSD writes.

A panel widget or another consumer can watch and display that file. The output
looks approximately like this (the exact fields appear only when relevant):

```text
Wed 12 Aug 2026 W33 10:14:41 ⠹ up 2.5d | D:120G·42% | M:18.2G S:11% | BAT:73% 3:21
```

The Braille spinner advances once per second. Status values use Pango `<span>`
markup for color and warning symbols.

## TL;DR: minimal setup

Clock Ticker runs as a systemd user service, collects a small set of status
fields, and writes one Pango-formatted line for a consumer display (consumer can be 
any UI widget able to display text file).
A configuration file is not required, but selecting only the broadly useful core
modules gives a quieter first installation without Fedora, Syncthing, Claude,
Codex, or personal integrations.

From the cloned repository, create a minimal configuration and install:

```bash
mkdir -p "$HOME/.config/clock-ticker"
printf '%s\n' 'enabled_modules=clock,battery,filesystem,memory,swap,system' >"$HOME/.config/clock-ticker/config"
just install
```

Configure the panel widget to read this file as Pango markup:

```text
/run/user/$(id -u)/clock-ticker/ticker.txt
```

On GNOME, one possible consumer is the
[Shell Clock GNOME extension](https://github.com/blackdaemon/shell-clock). In
its preferences, set **Shell command to execute or text file to display** to
the absolute path of `ticker.txt` and use a one-second refresh interval. Shell
Clock then places the generated line in the GNOME top panel and renders Clock
Ticker's supported color markup.

If the consumer cannot render Pango markup, set `ticker_format=plain` in the
[configuration file](#configuration), or start a foreground instance with
`clock_ticker run plain`. The published `ticker.txt` then contains the same
status text with markup tags removed.

Then verify the installation with:

```bash
clock_ticker test
```

That is enough for a working clock and live system status. 

Module update jobs, custom output directories, personal modules, and additional 
integrations are optional. 
Modules with update capability receive only an initial cache update;
schedule them with cron or a systemd user timer if their data must stay
current. See [Scheduling module updates](#scheduling-module-updates) for the
module list command and a sample crontab, and [Configuration](#configuration)
to change modules or paths.

## Requirements

- Linux with `/proc` and `/sys`
- Bash 5 or newer (`EPOCHREALTIME`, `EPOCHSECONDS`, arrays, and namerefs are used)
- [`just`](https://just.systems/) for the documented installation and task
  wrappers
- Python 3.11 or newer and [`uv`](https://docs.astral.sh/uv/) for the
  Python-backed update modules
- A systemd-style `XDG_RUNTIME_DIR` backed by `tmpfs`
- systemd user services for the `install`, `restart`, `status`, and `uninstall`
  commands
- GNU coreutils, including the external `df` command, plus `cat`, `cmp`,
  `dirname`, `mkdir`, `mktemp`, `mv`, `readlink`, `sort`, `tee`, `touch`, and
  `wc`
- Other common Linux tools: `awk`, `findmnt`, `flock`, `getconf`, `gsettings`,
  `jq`, `ps`, and `sed`
- `dnf5`, or DNF4 with `dnf-plugins-core`, for the optional Fedora update
  module
- `syncthing` for the optional Syncthing status module

Ticker output uses Pango markup by default. If the consumer only supports plain
text, set [`ticker_format=plain`](#configuration) to strip markup tags before
publishing `ticker.txt`.

## Installation

Clone the repository somewhere permanent, then run:

```bash
just install [TARGET_DIRECTORY]
```

[`just install`](https://just.systems/) creates the personal-module directory
and, when absent, creates the ignored `personal_modules` symbolic link in the
repository pointing to it. It then runs [`uv sync`](https://docs.astral.sh/uv/)
and delegates to
`./clock_ticker.sh install`. No system mount or `/etc/fstab` entry is needed;
runtime files live below the user's existing memory-backed runtime directory.
After installation, the command prints the effective location of `ticker.txt`,
whether its directory came from a command-line override, the
[configuration file](#configuration), or the default, and whether that choice
was persisted. The configuration-file location is included in the summary.

[`uv sync`](https://docs.astral.sh/uv/) creates or updates `.venv`, installs the
dependencies declared in `pyproject.toml`, and uses `uv.lock` when one is
present. 

The update modules always invoke `.venv/bin/python` by its absolute repository
path, including when run by cron or the systemd user service. Activating the
virtual environment is therefore unnecessary. Run
[`uv sync`](https://docs.astral.sh/uv/) again whenever the
repository moves or its Python dependencies change.

Installation:

1. Verifies that `~/.local/bin` is on `PATH`.
2. Creates `~/.local/bin/clock_ticker` as a symbolic link to the repository
   script.
3. Writes `~/.config/systemd/user/clock-ticker.service`.
4. Enables and starts the user service.

`~/.local/bin` is the conventional location for user-installed executables on
Linux. If it is missing from `PATH`, the installer stops and prints the line to
add to your shell startup file.

The systemd unit runs the script at its absolute repository path. Do not move
the repository after installation without running `install` again from the new
location.

The service belongs to `graphical-session.target`, restarts after failures, and
writes errors to the user journal:

```bash
journalctl --user -u clock-ticker.service
```

## Commands

The [`justfile`](https://just.systems/) provides short wrappers around the main
script:

```text
just help
just test
just install
just restart
just stop
just update MODULE
```

All recipes delegate directly to the matching `./clock_ticker.sh` command,
except [`just install`](https://just.systems/), which first runs
[`uv sync`](https://docs.astral.sh/uv/) to prepare the Python virtual
environment. Its optional target directory is forwarded to the underlying
install command and saved as persistent [configuration](#configuration).

The underlying commands are:

```text
clock_ticker help
clock_ticker run [TARGET_DIRECTORY] [pango|plain]
clock_ticker install [TARGET_DIRECTORY]
clock_ticker uninstall
clock_ticker status
clock_ticker restart
clock_ticker stop
clock_ticker test
clock_ticker update MODULE [ARGUMENTS]
```

- `help` prints command help and discovers modules that provide an update
  function.
- `run` starts the foreground ticker loop. Normally systemd runs this command.
  It verifies that its internal runtime directory is backed by `tmpfs`. An
  optional target directory overrides where `ticker.txt` is published and may
  reside on any writable filesystem; module caches remain in the standard
  memory-backed runtime directory. Output defaults to `pango`; select `plain`
  to strip Pango tags before publishing.
- `install` installs, enables, and starts the user service.
  When a target directory is provided, it is saved in the
  [configuration file](#configuration) and used by the installed service.
  Without one, existing [configuration](#configuration) is preserved.
- `uninstall` stops and disables the service, removes its unit, and removes the
  command symlink only if it still points to this script. Cached ticker data is
  left intact.
- `status` displays the user service status.
- `restart` restarts the service after code or configuration changes.
- `stop` stops the user service without disabling it.
- `test` checks Bash syntax, runs ShellCheck, compile-checks Python modules, and
  prints the currently published ticker both with and without Pango tags.
- `update MODULE` runs a module's slower cache-refresh operation. These updates
  are suitable for a systemd timer or cron job. Updates of different modules
  may run concurrently, while an overlapping update of the same module is
  skipped.

Examples:

```bash
clock_ticker run plain
clock_ticker run /run/user/$(id -u)/my-clock-ticker plain
clock_ticker run /run/user/$(id -u)/my-clock-ticker
clock_ticker install /run/user/$(id -u)/my-clock-ticker
clock_ticker update filesystem
clock_ticker update fedora_status
clock_ticker update fedora_status --help
```

## Configuration

The configuration file is optional; Clock Ticker runs without it. When the file
does not exist, these defaults apply:

- `ticker_directory` is `$XDG_RUNTIME_DIR/clock-ticker`, or
  `/run/user/$(id -u)/clock-ticker` when `XDG_RUNTIME_DIR` is unset.
- `ticker_format` is `pango`.
- `enabled_modules` is unrestricted, so
  [every module discovered](#modules) in the public and personal module
  directories is enabled.

The file is `$XDG_CONFIG_HOME/clock-ticker/config`, falling back to
`~/.config/clock-ticker/config` when `XDG_CONFIG_HOME` is unset. It is a
data-only file with this format:

```text
ticker_directory=$XDG_RUNTIME_DIR/my-clock-ticker
ticker_format=plain
enabled_modules=clock,battery,filesystem,memory,swap,system
```

The `ticker_directory` value supports a leading `~` or `~/`, plus `$NAME` and
`${NAME}` references to set environment variables. Expansion is data-only:
shell commands and other Bash expressions are not evaluated. The expanded
directory must be an absolute path on a writable filesystem. A command-line
directory passed to `clock_ticker run` takes precedence over the configured
value.

Keeping the default is the best approach for most installations. The ticker is
rewritten once per second, while `/run/user/$(id -u)/clock-ticker` is normally
memory-backed, persists for the login session, and avoids continual writes to
persistent storage. Use a custom disk-backed directory only when another
consumer specifically requires it. With no override, `$XDG_RUNTIME_DIR` is
used when set; otherwise the default is `/run/user/$(id -u)/clock-ticker`.

`enabled_modules` is optional and accepts a comma-separated list of module
names without the `.sh` suffix. When omitted, all discovered modules are
enabled for backward compatibility. When present, only listed modules are
loaded, rendered, and included in automatic initial cache updates. An empty
value disables every optional module. Manual `clock_ticker update MODULE`
commands remain available for both enabled and disabled modules.

## Scheduling module updates

Clock Ticker performs one automatic initial update for enabled updatable modules, 
but it does not install recurring update jobs. Use cron or systemd user timers for
modules whose cached information should remain current.

Each module update has its own runtime lock. If a schedule starts another update
of the same module before the previous one finishes, the overlapping invocation
reports that it was skipped and exits successfully. Updates of different modules
remain independent and may run at the same time.

Run `clock_ticker help` to list all modules with update capability under
`Available update modules`. Every enabled module in that list must be scheduled
externally if its cached status should remain current; the automatic initial
update only seeds its cache once. Disabled update-capable modules are also
listed so they can still be updated manually with `clock_ticker update MODULE`.

This sample is based on the maintainer's schedule, reduced to modules shipped
with the public project:

```cron
SHELL=/bin/bash

# Frequently changing local state.
* * * * * /bin/bash -lc 'clock_ticker update filesystem' >/dev/null 2>&1
* * * * * /bin/bash -lc 'clock_ticker update syncthing' >/dev/null 2>&1

# Usage allowance changes less frequently.
0 * * * * /bin/bash -lc 'clock_ticker update codex_usage' >/dev/null 2>&1

# Repository metadata is comparatively expensive to refresh.
0 8,20 * * * /bin/bash -lc 'clock_ticker update fedora_status' >/dev/null 2>&1
```

Install the example with `crontab -e` and keep only jobs for modules relevant
to the machine. `/bin/bash -lc` starts a login shell so the installed
`clock_ticker` command can use the user's normal login `PATH`. Redirect or log
output according to local monitoring needs; removing the redirections lets
cron mail command output when a mail transport is configured.

Creating a crontab does not necessarily start the system cron daemon. On
Fedora, install `cronie` if needed and enable its system service:

```bash
sudo dnf install cronie
sudo systemctl enable --now crond.service
systemctl status crond.service
```

Debian and Ubuntu normally use `cron.service` instead of `crond.service`.
Package and service names vary on other distributions; verify that the local
cron daemon is active after installing the crontab.

## Displayed information

The main loop assembles fields in this order:

1. A red solid dot (`●`) when GNOME's
   `org.gnome.desktop.notifications show-banners` setting is `false`.
2. Local weekday, date, ISO week number, and current time.
3. A ten-frame Braille spinner and compact uptime read directly from
   `/proc/uptime`, such as `up 2.5d` after the first day.
4. Root filesystem space and read-only filesystem warnings.
5. Available memory, swap utilization, memory pressure, swap I/O, and QEMU VM
   memory.
6. CPU temperature when it reaches the display threshold.
7. Battery status while discharging.
8. Optional cache files, Fedora update/reboot status.
9. Syncthing device connectivity and paused-device count.

Empty fields are omitted automatically. Fields are separated with ` | ` except
for the swap-I/O detail, which uses a middle dot.

## Modules

Default modules are stored in the repository's `modules/` directory. Personal
modules can be stored in
`$XDG_CONFIG_HOME/clock-ticker/modules/`, falling back to
`~/.config/clock-ticker/modules/`. Both locations are discovered; a personal
module takes precedence when it has the same filename as a repository module.
Only modules allowed by `enabled_modules` are sourced when the ticker starts.

Some modules read live system information, while others need periodic updates.
Run `clock_ticker help` to find update-capable modules and see
[Scheduling module updates](#scheduling-module-updates) for recurring jobs.

### `dnd.sh`

Shows a red dot (`●`) when GNOME Do Not Disturb is enabled. It stays hidden when
notification banners are enabled.

### `clock.sh`

Shows the local date, time, activity spinner, and uptime. The time changes color
for daylight, twilight, and night and includes a sun or moon icon. It uses the
first GNOME Weather location, with Prague as a fallback.

### `battery.sh`

Shows charge percentage and estimated remaining time while the battery is
discharging. It stays hidden while charging or full and changes color when the
battery becomes low or critical.

### `filesystem.sh`

Shows free space and usage for the root filesystem and warns when `/` or
`/home` becomes read-only (Linux may remount a filesystem read-only after disk
or filesystem errors to prevent further damage). 

**Schedule `clock_ticker update filesystem` to keep the space value current.**

### `memory.sh`

Shows available memory, swap usage, memory pressure, and QEMU virtual-machine
memory (If QEMU is running). High swap use is reported but only becomes a
warning when available RAM is low or current memory pressure is detected.
During warnings it also identifies the process using the most memory.
The default thresholds are tuned for the maintainer's 32 GiB workstation and
may need adjustment on significantly different systems. Edit the threshold
variables near the top of `modules/memory.sh` when needed.

### `swap.sh`

Shows recent swap input and output activity. Normal activity is highlighted;
very heavy swapping is shown as critical.

### `system.sh`

Shows CPU temperature only when it becomes unusually high, with separate
warning and critical colors. At the critical threshold it also identifies the
process reporting the highest CPU utilization. When available, its systemd
service or scope is included to distinguish interpreted processes such as
`mdatp/python3`. Python processes without a useful service identity show the
module or script being run. Packaged scripts include their RPM package name;
unpackaged scripts below `/opt` or `/var/opt` include an application
directory.

### `fedora_status.sh`

Shows the number of available Fedora package updates and whether a reboot is
recommended. It prefers `dnf5` and falls back to DNF4's `dnf`; DNF4 requires
`dnf-plugins-core` for the reboot check.

**Schedule `clock_ticker update fedora_status` infrequently because refreshing
repository metadata can take time.**

### `claude_usage.sh`

Shows the remaining Claude usage allowance and reset time for both the
five-hour session and weekly (all models) usage windows, plus the local reset
time of the session window. It requires a Claude CLI signed in with a
subscription. The remaining usage-credit allowance (monthly limit minus credits
used) is shown at the end when usage credits are enabled, or `∞` when they have
no limit. For example: `CL:5h 31% rst 15m (03:39)·7d 89% rst 4d3h·Cr:37.5`.
Optionally, an activity icon is added after `CL:` to indicate an ongoing burst
of Claude work, detected from session logs under `~/.claude/projects`. Clock
Ticker refreshes the cache in the background every 30 seconds while Claude is
active and every 10 minutes while it is idle; a failed refresh waits for the
same interval before trying again.

The data comes from the `usage_report` message of
`claude -p /usage --output-format stream-json --verbose`, which is a local
command that uses no tokens. This output is not a documented interface, so a CLI
update may change it; the module then reports an error on stderr and keeps the
previous cache.

### `codex_usage.sh`

Shows the remaining Codex usage allowance and reset time for both the short
(normally five-hour) and weekly usage windows. It requires an authenticated
Codex CLI. Purchased-credit balance is shown at the end when available. For
example: `CX:5h 31% rst 15m·7d 89% rst 7d·Cr:2489.1`.
Optionally, an activity icon is added after `CX:` to indicate an ongoing burst
of Codex work. Clock Ticker refreshes the cache in the background every 30
seconds while Codex is active and every 10 minutes while it is idle.

### `syncthing.sh`

Shows device connectivity, synchronization progress and speed, paused devices,
recent activity, and folder errors. Remote progress covers connected devices;
disconnected devices still affect the connectivity count. It reads the existing
local Syncthing configuration and shows `ST:offline` when the service is
unreachable.

**Schedule `clock_ticker update syncthing` regularly to discover new activity; 
1 minute schedule is enough.**

*NOTE: After an update detects pending remote synchronization, Clock Ticker
automatically refreshes Syncthing status in the background every 4 seconds until 
the devices catch up. 
This can be changed with `SYNCTHING_MONITOR_INTERVAL`. 
External scheduling is still required to detect new work after the background
updater has stopped.*

## Writing a module

Create `modules/NAME.sh` and define one or all of these interfaces:

```bash
some_status() {
  # Function called from the ticker loop and returning the module info
  printf '<span foreground="#3cb371">OK</span>'
}

update__NAME() {
  # Optional update function
  # Perform slower work and atomically update a cache file.
}

help__NAME() {
  # Optional help function for module update
  printf 'Usage: clock_ticker update NAME\n'
}
```

Loading a module does not automatically call its status function. Add the
appropriate `append_ticker` call in `ticker_loop` for new live output. 

A module with `update__NAME` is automatically listed by `clock_ticker help` 
and can be invoked with `clock_ticker update NAME` (for instance from crontab).

Keep live status functions fast, emit nothing when there is nothing useful to
show, write diagnostics to standard error, and treat emitted markup as trusted.

### Rendering runtime files

`render_text` function treats its input as literal text, even when that text
matches an existing path. Prefix an argument with `render_file ` to read it
as a file:

```bash
render_text "" "render_file $RAM_DISK/.example_status"
```

File line endings are replaced with spaces, and either input form can be
optionally truncated. Module status functions intentionally return trusted
Pango markup. Consequently, external runtime files must contain markup-safe
text: escape `&`, `<`, and `>` before writing them unless they are intentional
Pango markup.

### Publishing behavior

Each iteration waits for the next whole-second boundary, renders the ticker,
and writes it to a uniquely named temporary file inside the Clock Ticker
runtime directory. If the content changed, `mv` atomically replaces
`ticker.txt`; otherwise the temporary file is removed. This avoids partial
reads and concurrent temporary-file collisions while preventing unnecessary
destination updates.

## Development checks

Run all development checks with:

```bash
just test
```

This delegates to `clock_ticker test`, which runs the static checks and Bash
regression tests, then prints the ticker currently published in
`$XDG_RUNTIME_DIR/clock-ticker/ticker.txt`. For Pango output it also prints a
plain-text preview with the tags removed. If the service has not produced the
file yet, the static checks still succeed and the command reports that no
ticker output is available. It checks Bash syntax with:

```bash
bash -n clock_ticker.sh lib/*.sh modules/*.sh tests/*.sh
```

Compile-check the Python modules with the managed environment:

```bash
uv run python -m compileall -q modules
```

Run ShellCheck with:

```bash
shellcheck -S error -x clock_ticker.sh lib/*.sh modules/*.sh tests/*.sh
```

After modifying the running script or a module, reload it with:

```bash
clock_ticker restart
```

## License

MIT. See the copyright headers in the scripts.
