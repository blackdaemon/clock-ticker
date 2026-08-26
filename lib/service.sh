#!/bin/bash

# Restart the Clock Ticker systemd user service. Arguments: none.
# Arguments: none
# Output: systemctl diagnostics on stdout.
# Returns: systemctl's success or failure status.
restart_service() {
  systemctl --user restart clock-ticker.service || return 1
}


# Stop the Clock Ticker systemd user service.
# Arguments: none.
# Output: systemctl diagnostics on stdout.
# Returns: systemctl's success or failure status.
stop_service() {
  systemctl --user stop clock-ticker.service || return 1
}


# Display the Clock Ticker systemd user service status.
# Arguments: none.
# Output: systemctl status on stdout.
# Returns: systemctl's success or failure status.
status_service() {
  systemctl --user --no-pager status clock-ticker.service
}


# Validate project scripts and Python modules, then preview published ticker
# output when available.
# Arguments: none
# Output: checks and ticker preview
# Returns: failure when a validation or readable ticker operation fails.
test_project() {
  bash -n "$SCRIPT_PATH" "$LIB_DIR"/*.sh "$MODULES_DIR"/*.sh || return 1
  shellcheck -S error -x "$SCRIPT_PATH" "$LIB_DIR"/*.sh "$MODULES_DIR"/*.sh || return 1
  "$PYTHON" -m compileall -q "$MODULES_DIR" || return 1

  if [[ ! -r "$TICKER_FILE" ]]; then
    printf '\nTicker output is not available yet: %s\n' "$TICKER_FILE"
    return 0
  fi

  printf '\nTicker output (%s):\n' "$TICKER_FORMAT"
  command cat -- "$TICKER_FILE" || return 1
  if [[ "$TICKER_FORMAT" == pango ]]; then
    printf '\n\nTicker output (plain text preview):\n'
    sed 's/<[^>]*>//g' "$TICKER_FILE" || return 1
  fi
  printf '\n'
}


# Print a yellow informational message.
# Arguments: message
# Output: stdout.
# Returns: the status from printf.
print_info() {
  printf '\033[33m%s\033[0m\n' "$1"
}


# Print a red error message.
# Arguments: message
# Output: stderr
# Returns: the status from printf.
print_error() {
  printf '\033[31m%s\033[0m\n' "$1" >&2
}


# Print a green success message.
# Arguments: message
# Output: stdout
# Returns: the status from printf.
print_success() {
  printf '\033[32m%s\033[0m\n' "$1"
}


# Install, enable, and start the Clock Ticker systemd user service.
# Arguments: optional absolute ticker directory, persisted to configuration when supplied.
# Output: progress and service status on stdout.
# Returns: failure on any installation step.
install_service() {
  local target_directory="${1:-}"
  local installed_ticker_directory="$TICKER_DIRECTORY"
  local installed_ticker_file
  local target_source
  local persistence_message
  local enabled_modules_value
  local service_dir="$HOME/.config/systemd/user"
  local service_file="$service_dir/clock-ticker.service"
  local temporary_config

  if [[ -n "$target_directory" ]]; then
    installed_ticker_directory="$target_directory"
    target_source="command-line override"
    [[ "$target_directory" == /* ]] || {
      print_error \
        "Ticker target directory must be an absolute path: $target_directory"
      return 2
    }
    print_info "Creating configuration directory at $CONFIG_DIR..."
    command mkdir -p -- "$CONFIG_DIR" || return 1
    if [[ "$ENABLED_MODULES_CONFIGURED" == true ]]; then
      enabled_modules_value="$(configured_enabled_modules_value)" || return 1
    fi
    print_info "Saving ticker target directory in $CONFIG_FILE..."
    temporary_config="$(mktemp --tmpdir="$CONFIG_DIR" 'config.tmp.XXXXXX')" || return 1
    if ! {
      printf 'ticker_directory=%s\n' "$target_directory"
      if [[ "$ENABLED_MODULES_CONFIGURED" == true ]]; then
        printf 'enabled_modules=%s\n' "$enabled_modules_value"
      fi
      if [[ "$TICKER_FORMAT_CONFIGURED" == true ]]; then
        printf 'ticker_format=%s\n' "$TICKER_FORMAT"
      fi
    } >"$temporary_config"; then
      rm -f -- "$temporary_config"
      return 1
    fi
    if ! mv -f -- "$temporary_config" "$CONFIG_FILE"; then
      rm -f -- "$temporary_config"
      return 1
    fi
    persistence_message="persisted in $CONFIG_FILE"
  elif [[ -e "$CONFIG_FILE" ]]; then
    target_source="configuration file"
    persistence_message="persisted in $CONFIG_FILE"
  else
    target_source="default"
    persistence_message="not persisted; configuration file would be $CONFIG_FILE"
  fi

  if [[ "$installed_ticker_directory" == / ]]; then
    installed_ticker_file="/ticker.txt"
  else
    installed_ticker_file="${installed_ticker_directory%/}/ticker.txt"
  fi

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      print_error "$BIN_DIR is not on PATH. Add this line to your shell startup file:"
      print_error '    export PATH="$HOME/.local/bin:$PATH"'
      return 1
      ;;
  esac

  print_info "Creating command directory at $BIN_DIR..."
  command mkdir -p "$BIN_DIR" || return 1
  print_info "Linking clock_ticker command at $BIN_DIR/clock_ticker..."
  ln -sfnv -- "$SCRIPT_PATH" "$BIN_DIR/clock_ticker" || return 1

  print_info "Creating systemd user service directory at $service_dir..."
  command mkdir -p "$service_dir" || return 1

  print_info "Writing systemd user service at $service_file..."
  command tee "$service_file" >/dev/null <<EOF || return 1
[Unit]
Description=Clock ticker
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/bash "$SCRIPT_PATH" run
StandardOutput=null
StandardError=journal
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF

  print_info 'Reloading systemd user configuration...'
  systemctl --user daemon-reload || return 1
  print_info 'Enabling clock-ticker.service...'
  systemctl --user enable clock-ticker.service || return 1
  print_info 'Restarting clock-ticker.service...'
  systemctl --user restart clock-ticker.service || return 1

  printf '\n'
  print_success 'Clock ticker installed and started.'
  print_success "Ticker output: $installed_ticker_file"
  print_success "Target directory source: $target_source"
  print_success "Target directory persistence: $persistence_message"
  printf '\nSystem service status:\n\n'
  systemctl --user --no-pager status clock-ticker.service || return 1
}


# Disable and remove this project's systemd user service and command symlink.
# Arguments: none.
# Output: progress and diagnostics. Leaves unrelated symlinks intact
# Returns :failure if a required removal or systemctl step fails.
uninstall_service() {
  local service_file="$HOME/.config/systemd/user/clock-ticker.service"
  local command_file="$BIN_DIR/clock_ticker"
  local link_target

  if [[ -f "$service_file" ]]; then
    systemctl --user disable --now clock-ticker.service || return 1
    rm -f -- "$service_file" || return 1
    systemctl --user daemon-reload || return 1
  fi

  if [[ -L "$command_file" ]]; then
    link_target="$(readlink -- "$command_file")" || return 1
    if [[ "$link_target" == "$SCRIPT_PATH" ]]; then
      rm -f -- "$command_file" || return 1
    else
      print_error "Not removing $command_file: it points to $link_target"
    fi
  elif [[ -e "$command_file" ]]; then
    print_error "Not removing $command_file: it is not a symbolic link."
  fi

  printf 'Clock ticker uninstalled.\n'
}
