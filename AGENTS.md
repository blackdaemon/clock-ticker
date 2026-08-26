# AGENTS.md

## Project overview

Clock Ticker is a Bash-first Linux desktop-panel status generator. The main
process renders Pango markup once per second and atomically publishes it under
`$XDG_RUNTIME_DIR/clock-ticker`. Shell modules in `modules/` provide live status
functions and optional slower cache-update functions. A small number of update
modules delegate work to Python managed by `uv`.

Read `README.md` and the files involved in a change before editing. Preserve
unrelated user changes; the working tree may intentionally be dirty.

## Architecture and module contracts

- `clock_ticker.sh` discovers repository modules in `modules/*.sh` and personal
  modules in the configured `clock-ticker/modules/` directory. Personal files
  override same-named repository files, and `enabled_modules` controls which
  modules are sourced and automatically initialized.
- `lib/runtime.sh` owns configuration, runtime paths, directory preparation,
  and atomic ticker publication. `lib/service.sh` owns installation, service
  lifecycle commands, and project checks.
- A live `*_status` function runs in the one-second loop. Keep it fast,
  non-blocking, and silent when there is nothing useful to display.
- `update__NAME` is the optional slow path for `modules/NAME.sh`. It is
  auto-discovered by the CLI and should atomically replace its cache using a
  temporary file in the same filesystem followed by `mv`.
- `help__NAME` is optional and documents the corresponding update command.
- Loading a module must not perform expensive work or mutate external state.
- Status output is trusted Pango markup. Escape untrusted or external text
  before inserting it, including `&`, `<`, and `>`; `jq`'s `@html` is suitable
  for JSON strings.
- Send diagnostics to stderr. Reserve stdout for the documented function or
  command output.
- Cache readers must tolerate a missing cache. Reject malformed data rather
  than rendering misleading status.
- Do not put secrets in cache files, command arguments, logs, or ticker output.

## Configuration drift contract

`modules/configuration_drift.sh` integrates with the adjacent
`fedora-workstation` repository, overridable with
`CONFIGURATION_DRIFT_REPOSITORY`.

Treat its producer contract as strict:

- exit `0`: JSON has `status: "converged"`, `drift: false`, no sections, and no
  error;
- exit `1`: JSON has `status: "drift"`, `drift: true`, and one or more named
  sections containing non-empty string differences;
- exit `2` (and unexpected exits): JSON has `status: "error"`, `drift: null`,
  no sections, and a non-empty error string.

Detected drift is an expected successful update, not an operational failure.
Keep exit status and JSON status validation coupled. Always replace the cache
with a timestamped valid report, including a synthetic error report when the
producer violates the contract. Converged state renders nothing; drift and
errors render attention states. Preserve atomic cache replacement and HTML
escaping of section names and errors.

Do not run the real drift update during routine validation: it refreshes state
in another repository. Use controlled temporary fixtures or mocked commands
unless the user explicitly requests the integration run.

## Style

- Bash targets Bash 5 or newer. Match the repository's two-space indentation
  and quote expansions unless intentional splitting or pattern matching is
  required.
- Prefer `[[ ... ]]`, `local` variables, arrays, `printf`, and explicit
  `return 1` propagation used by neighboring code.
- Keep functions focused and document public module functions with arguments,
  output, side effects, and return semantics when the behavior is not obvious.
- Do not enable shell options such as `set -e` inside sourced modules; they
  would alter the parent ticker process.
- Python targets 3.11 or newer. Keep dependencies in `pyproject.toml`, update
  `uv.lock` when dependencies change, and invoke Python through the managed
  environment.
- Update `README.md` when commands, module behavior, dependencies, thresholds,
  cache formats, or displayed fields change.

## Validation

Run checks proportional to the change:

```bash
bash -n clock_ticker.sh lib/*.sh modules/*.sh
shellcheck -S error -x clock_ticker.sh lib/*.sh modules/*.sh
uv run python -m compileall -q modules
```

If a tool is unavailable, report that clearly rather than claiming the check
passed. For cache modules, also exercise missing, valid, malformed, and failure
states with temporary data where practical. Avoid `install`, `uninstall`,
`restart`, or commands that write system/user-service state unless the user
explicitly asks for them.
