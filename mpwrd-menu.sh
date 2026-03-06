#!/bin/bash

set -u

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_REGISTRY="${APP_REGISTRY:-$SCRIPT_DIR/mesh-apps.conf}"
readonly SERVICE_REGISTRY="${SERVICE_REGISTRY:-$SCRIPT_DIR/mesh-services.conf}"
readonly MESHTASTIC_PACKAGE="meshtasticd"
readonly MESHTASTIC_DEBIAN_SERIES="Debian_13"
readonly REPO_CHANNELS=("beta" "alpha" "daily")
readonly PIPX_GLOBAL_HOME="/opt/pipx"
readonly PIPX_GLOBAL_BIN_DIR="/usr/local/bin"
readonly PIPX_GLOBAL_MAN_DIR="/usr/local/share/man"
readonly PIPX_TMP_THRESHOLD_KB=65536
readonly AVAILABLE_CONFIG_DIR="/etc/meshtasticd/available.d"
readonly ACTIVE_CONFIG_DIR="/etc/meshtasticd/config.d"

MENU_RESULT=-1
READ_KEY=""
APP_LABELS=()
APP_MANAGERS=()
APP_PACKAGES=()
APP_ACTION_LABELS=("Install" "Upgrade" "Uninstall" "Back")
APP_ACTION_KEYS=("install" "upgrade" "uninstall" "back")
SERVICE_LABELS=()
SERVICE_UNITS=()
SERVICE_ACTION_LABELS=("Status" "Start" "Stop" "Restart" "Enable" "Disable" "Back")
SERVICE_ACTION_KEYS=("status" "start" "stop" "restart" "enable" "disable" "back")

cleanup() {
  printf '\033[0m\033[?25h'
}

trap cleanup EXIT INT TERM

hide_cursor() {
  printf '\033[?25l'
}

show_cursor() {
  printf '\033[?25h'
}

clear_screen() {
  printf '\033[2J\033[H'
}

pause_prompt() {
  printf '\nPress Enter to continue...'
  read -r _
}

message_box() {
  show_cursor
  clear_screen
  printf '%s\n' "$1"
  pause_prompt
  hide_cursor
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

read_key() {
  local key extra
  IFS= read -rsn1 key || {
    READ_KEY="quit"
    return 1
  }

  if [[ "$key" == $'\e' ]]; then
    IFS= read -rsn2 -t 0.01 extra || true
    key+="$extra"
  fi

  case "$key" in
    $'\e[A'|k|K)
      READ_KEY="up"
      ;;
    $'\e[B'|j|J)
      READ_KEY="down"
      ;;
    ""|$'\n'|$'\r')
      READ_KEY="enter"
      ;;
    q|Q|$'\e')
      READ_KEY="quit"
      ;;
    *)
      READ_KEY="other"
      ;;
  esac
}

render_menu() {
  local title="$1"
  local prompt="$2"
  local selected="$3"
  local options_name="$4"
  local -n options_ref="$options_name"
  local i

  clear_screen
  printf 'mPWRD-menu\n'
  printf '============\n\n'
  printf '%s\n' "$title"
  printf '%s\n\n' "$prompt"

  for i in "${!options_ref[@]}"; do
    if (( i == selected )); then
      printf ' > %s\n' "${options_ref[$i]}"
    else
      printf '   %s\n' "${options_ref[$i]}"
    fi
  done

  printf '\nArrows or j/k to move, Enter to select, q to go back.\n'
}

menu_choose() {
  local title="$1"
  local prompt="$2"
  local options_name="$3"
  local -n options_ref="$options_name"
  local selected=0

  if (( ${#options_ref[@]} == 0 )); then
    MENU_RESULT=-1
    return 1
  fi

  while true; do
    render_menu "$title" "$prompt" "$selected" "$options_name"
    read_key || return 1

    case "$READ_KEY" in
      up)
        (( selected = (selected - 1 + ${#options_ref[@]}) % ${#options_ref[@]} ))
        ;;
      down)
        (( selected = (selected + 1) % ${#options_ref[@]} ))
        ;;
      enter)
        MENU_RESULT="$selected"
        return 0
        ;;
      quit)
        MENU_RESULT=-1
        return 1
        ;;
    esac
  done
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if (( EUID == 0 )); then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    printf 'sudo is required for this action.\n' >&2
    return 127
  fi
}

download_stdout() {
  local url="$1"

  if command_exists curl; then
    curl -fsSL "$url"
  elif command_exists wget; then
    wget -qO- "$url"
  else
    return 127
  fi
}

run_and_pause() {
  local title="$1"
  shift
  local rc

  show_cursor
  clear_screen
  printf '%s\n\n' "$title"
  "$@"
  rc=$?
  printf '\n'
  if (( rc == 0 )); then
    printf 'Completed successfully.\n'
  else
    printf 'Command exited with status %d.\n' "$rc"
  fi
  pause_prompt
  hide_cursor
  return "$rc"
}

run_terminal_program() {
  local mode="$1"
  local program="$2"
  shift 2 || true
  local run_as_root=0

  if ! command_exists "$program"; then
    message_box "Command not found: $program"
    return 1
  fi

  if [[ "$mode" == root-* ]]; then
    run_as_root=1
  fi

  if [[ "$mode" == *pause ]]; then
    if (( run_as_root )); then
      run_and_pause "Launching $program..." as_root "$program" "$@"
    else
      run_and_pause "Launching $program..." "$program" "$@"
    fi
    return $?
  fi

  show_cursor
  clear_screen
  if (( run_as_root )); then
    as_root "$program" "$@"
  else
    "$program" "$@"
  fi
  hide_cursor
}

apt_package_action() {
  local action="$1"
  local package="$2"

  case "$action" in
    install)
      as_root apt-get update && as_root apt-get install -y "$package"
      ;;
    upgrade)
      as_root apt-get update && as_root apt-get install --only-upgrade -y "$package"
      ;;
    uninstall)
      as_root apt-get remove -y "$package"
      ;;
  esac
}

install_board_config_file() {
  local source_file="$1"
  local target_file="$2"
  as_root mkdir -p "$ACTIVE_CONFIG_DIR" && as_root install -m 0644 "$source_file" "$target_file"
}

reset_array() {
  local -n array_ref="$1"
  array_ref=()
}

append_array() {
  local -n array_ref="$1"
  array_ref+=("$2")
}

load_delimited_records() {
  local source_file="$1"
  shift
  local field_names=("$@")
  local field_count="${#field_names[@]}"
  local line valid i
  local fields=()
  local field_name

  for field_name in "${field_names[@]}"; do
    reset_array "$field_name"
  done

  [[ -f "$source_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    IFS='|' read -r -a fields <<< "$line"

    for (( i = 0; i < field_count; i++ )); do
      fields[$i]="$(trim "${fields[$i]:-}")"
    done

    if [[ -z "${fields[0]:-}" || "${fields[0]:0:1}" == "#" ]]; then
      continue
    fi

    valid=1
    for (( i = 0; i < field_count; i++ )); do
      if [[ -z "${fields[$i]:-}" ]]; then
        valid=0
        break
      fi
    done

    (( valid )) || continue

    for (( i = 0; i < field_count; i++ )); do
      append_array "${field_names[$i]}" "${fields[$i]}"
    done
  done < "$source_file"
}

load_app_registry() {
  load_delimited_records "$APP_REGISTRY" \
    APP_LABELS APP_MANAGERS APP_PACKAGES
}

load_service_registry() {
  load_delimited_records "$SERVICE_REGISTRY" \
    SERVICE_LABELS SERVICE_UNITS
}

current_repo_channel() {
  local found=()
  local channel

  for channel in "${REPO_CHANNELS[@]}"; do
    if [[ -f "/etc/apt/sources.list.d/network:Meshtastic:${channel}.list" ]]; then
      found+=("$channel")
    fi
  done

  case "${#found[@]}" in
    0)
      printf 'none'
      ;;
    1)
      printf '%s' "${found[0]}"
      ;;
    *)
      printf 'mixed (%s)' "${found[*]}"
      ;;
  esac
}

repo_is_ready() {
  local current
  local channel

  current="$(current_repo_channel)"
  for channel in "${REPO_CHANNELS[@]}"; do
    [[ "$current" == "$channel" ]] && return 0
  done

  return 1
}

switch_repo_channel() {
  local channel="$1"
  local repo_http="http://download.opensuse.org/repositories/network:/Meshtastic:/${channel}/${MESHTASTIC_DEBIAN_SERIES}/"
  local repo_https="https://download.opensuse.org/repositories/network:/Meshtastic:/${channel}/${MESHTASTIC_DEBIAN_SERIES}/"
  local list_file="/etc/apt/sources.list.d/network:Meshtastic:${channel}.list"
  local key_file="/etc/apt/trusted.gpg.d/network_Meshtastic_${channel}.gpg"
  local temp_list temp_key existing rc=0

  if ! command_exists gpg; then
    message_box 'gpg is required to install the Meshtastic repository key.'
    return 1
  fi

  if ! command_exists curl && ! command_exists wget; then
    message_box 'curl or wget is required to download the Meshtastic repository key.'
    return 1
  fi

  temp_list="$(mktemp)"
  temp_key="$(mktemp)"

  printf 'deb %s /\n' "$repo_http" > "$temp_list"
  if ! download_stdout "${repo_https}Release.key" | gpg --dearmor > "$temp_key"; then
    rm -f "$temp_list" "$temp_key"
    message_box "Failed to download or convert the Meshtastic ${channel} repository key."
    return 1
  fi

  show_cursor
  clear_screen
  printf 'Switching meshtasticd repository to %s...\n\n' "$channel"

  for existing in "${REPO_CHANNELS[@]}"; do
    as_root rm -f "/etc/apt/sources.list.d/network:Meshtastic:${existing}.list"
    as_root rm -f "/etc/apt/trusted.gpg.d/network_Meshtastic_${existing}.gpg"
  done

  if ! as_root install -m 0644 "$temp_list" "$list_file"; then
    rc=$?
  elif ! as_root install -m 0644 "$temp_key" "$key_file"; then
    rc=$?
  elif ! as_root apt-get update; then
    rc=$?
  fi

  rm -f "$temp_list" "$temp_key"
  if (( rc != 0 )); then
    as_root rm -f "$list_file" "$key_file"
  fi

  printf '\n'
  if (( rc == 0 )); then
    printf 'meshtasticd repository is now set to %s.\n' "$channel"
  else
    printf 'Repository switch failed with status %d.\n' "$rc"
  fi
  pause_prompt
  hide_cursor
  return "$rc"
}

install_meshtasticd() {
  if ! repo_is_ready; then
    message_box 'Select beta, alpha, or daily first so meshtasticd installs from the correct repository.'
    return 1
  fi

  run_and_pause 'Installing meshtasticd...' apt_package_action install "$MESHTASTIC_PACKAGE"
}

upgrade_meshtasticd() {
  if ! repo_is_ready; then
    message_box 'Select beta, alpha, or daily first so meshtasticd upgrades from the correct repository.'
    return 1
  fi

  run_and_pause 'Upgrading meshtasticd...' apt_package_action upgrade "$MESHTASTIC_PACKAGE"
}

uninstall_meshtasticd() {
  run_and_pause 'Uninstalling meshtasticd...' apt_package_action uninstall "$MESHTASTIC_PACKAGE"
}

service_status_prompt() {
  local unit="$1"
  local active enabled

  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"

  if [[ -z "$active" ]]; then
    active='unknown'
  fi

  if [[ -z "$enabled" ]]; then
    enabled='unknown'
  fi

  printf 'Unit: %s | Active: %s | Enabled: %s' "$unit" "$active" "$enabled"
}

manage_service() {
  local unit="$1"
  local action="$2"
  run_and_pause "systemctl ${action} ${unit}" as_root systemctl "$action" "$unit"
}

run_service_action() {
  local unit="$1"
  local action="$2"

  case "$action" in
    status)
      run_and_pause "systemctl status ${unit}" systemctl status --no-pager --full "$unit"
      ;;
    start|stop|restart|enable|disable)
      manage_service "$unit" "$action"
      ;;
  esac
}

list_relative_files() {
  local dir="$1"
  local result_name="$2"
  local -n result_ref="$result_name"

  result_ref=()
  [[ -d "$dir" ]] || return 0

  mapfile -t result_ref < <(find "$dir" -mindepth 1 -type f -printf '%P\n' 2>/dev/null | sort)
}

apply_board_config() {
  local relative_path="$1"
  local source_path="$AVAILABLE_CONFIG_DIR/$relative_path"
  local target_path="$ACTIVE_CONFIG_DIR/$(basename "$relative_path")"

  if [[ ! -f "$source_path" ]]; then
    message_box "Config not found: $source_path"
    return 1
  fi

  run_and_pause "Applying board config: $relative_path" install_board_config_file "$source_path" "$target_path"
}

remove_board_config() {
  local filename="$1"
  local target_path="$ACTIVE_CONFIG_DIR/$filename"

  if [[ ! -f "$target_path" ]]; then
    message_box "Active config not found: $target_path"
    return 1
  fi

  run_and_pause "Removing board config: $filename" as_root rm -f "$target_path"
}

manage_app_action() {
  local label="$1"
  local manager="$2"
  local package="$3"
  local action="$4"
  local verb=""
  local resolved_manager=""

  case "$action" in
    install)
      verb="Installing"
      ;;
    upgrade)
      verb="Upgrading"
      ;;
    uninstall)
      verb="Uninstalling"
      ;;
  esac

  resolved_manager="$manager"
  if [[ "$manager" == "pipx" ]]; then
    resolved_manager="$(resolve_pipx_manager "$package")"
  fi

  case "$resolved_manager" in
    apt)
      run_and_pause "${verb} ${label}..." apt_package_action "$action" "$package"
      ;;
    pipx)
      if (( EUID == 0 )); then
        message_box 'Run pipx actions as a regular user, not root.'
        return 1
      fi

      if ! command_exists pipx; then
        message_box 'pipx is not installed.'
        return 1
      fi

      run_and_pause "${verb} ${label}..." run_pipx_action "$action" "$package" user
      ;;
    pipx-global)
      if ! command_exists pipx; then
        message_box 'pipx is not installed.'
        return 1
      fi

      run_and_pause "${verb} ${label}..." run_pipx_global_action "$action" "$package"
      ;;
    *)
      message_box "Unsupported app manager: $resolved_manager"
      return 1
      ;;
  esac
}

resolve_pipx_manager() {
  local package="$1"
  local command_path=""
  local resolved_path=""

  command_path="$(command -v "$package" 2>/dev/null || true)"
  if [[ -z "$command_path" ]]; then
    printf 'pipx'
    return 0
  fi

  resolved_path="$(readlink -f "$command_path" 2>/dev/null || printf '%s' "$command_path")"
  if [[ "$command_path" == /usr/local/bin/* || "$resolved_path" == /opt/pipx/venvs/* ]]; then
    printf 'pipx-global'
    return 0
  fi

  printf 'pipx'
}

run_pipx_global_action() {
  local action="$1"
  local package="$2"

  run_pipx_action "$action" "$package" root
}

tmp_free_kb() {
  local path="$1"
  df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

run_pipx_action() {
  local action="$1"
  local package="$2"
  local scope="${3:-user}"
  local free_kb=""
  local temp_dir=""
  local rc=0

  free_kb="$(tmp_free_kb /tmp)"
  if [[ -n "$free_kb" && "$free_kb" =~ ^[0-9]+$ && "$free_kb" -lt "$PIPX_TMP_THRESHOLD_KB" ]]; then
    temp_dir="$(mktemp -d /var/tmp/mpwrd-menu-pipx.XXXXXX)"
  fi

  if [[ "$scope" == "root" ]]; then
    if [[ -n "$temp_dir" ]]; then
      as_root env \
        TMPDIR="$temp_dir" \
        PIPX_HOME="$PIPX_GLOBAL_HOME" \
        PIPX_BIN_DIR="$PIPX_GLOBAL_BIN_DIR" \
        PIPX_MAN_DIR="$PIPX_GLOBAL_MAN_DIR" \
        pipx "$action" "$package"
      rc=$?
    else
      as_root env \
        PIPX_HOME="$PIPX_GLOBAL_HOME" \
        PIPX_BIN_DIR="$PIPX_GLOBAL_BIN_DIR" \
        PIPX_MAN_DIR="$PIPX_GLOBAL_MAN_DIR" \
        pipx "$action" "$package"
      rc=$?
    fi
  else
    if [[ -n "$temp_dir" ]]; then
      env TMPDIR="$temp_dir" pipx "$action" "$package"
      rc=$?
    else
      pipx "$action" "$package"
      rc=$?
    fi
  fi

  if [[ -n "$temp_dir" ]]; then
    rm -rf "$temp_dir"
  fi

  return "$rc"
}

indexed_list_menu() {
  local title="$1"
  local prompt="$2"
  local labels_name="$3"
  local handler="$4"
  local -n labels_ref="$labels_name"
  local options=()
  local label

  while true; do
    options=()
    for label in "${labels_ref[@]}"; do
      options+=("$label")
    done
    options+=("Back")

    menu_choose "$title" "$prompt" options || return 0
    if (( MENU_RESULT == ${#labels_ref[@]} )); then
      return 0
    fi

    "$handler" "$MENU_RESULT"
  done
}

service_menu() {
  local index="$1"
  local service_label="${SERVICE_LABELS[$index]}"
  local unit="${SERVICE_UNITS[$index]}"
  local prompt
  local action

  while true; do
    prompt="$(service_status_prompt "$unit")"
    menu_choose "$service_label" "$prompt" SERVICE_ACTION_LABELS || return 0
    action="${SERVICE_ACTION_KEYS[$MENU_RESULT]}"
    if [[ "$action" == "back" ]]; then
      return 0
    fi

    run_service_action "$unit" "$action"
  done
}

related_services_menu() {
  load_service_registry
  if (( ${#SERVICE_LABELS[@]} == 0 )); then
    message_box "No services are configured. Add entries to $SERVICE_REGISTRY."
    return 0
  fi

  indexed_list_menu 'Meshtastic Related Services' \
    'Manage systemd units for Meshtastic support services.' \
    SERVICE_LABELS service_menu
}

repo_menu() {
  local options=()
  local prompt
  local channel
  local channel_count="${#REPO_CHANNELS[@]}"

  while true; do
    options=()
    for channel in "${REPO_CHANNELS[@]}"; do
      options+=("Switch to $channel")
    done
    options+=("Install meshtasticd" "Upgrade meshtasticd" "Uninstall meshtasticd" "Back")

    prompt="Current repo: $(current_repo_channel)"
    menu_choose 'meshtasticd Repository' "$prompt" options || return 0
    if (( MENU_RESULT < channel_count )); then
      switch_repo_channel "${REPO_CHANNELS[$MENU_RESULT]}"
      continue
    fi

    case $(( MENU_RESULT - channel_count )) in
      0)
        install_meshtasticd
        ;;
      1)
        upgrade_meshtasticd
        ;;
      2)
        uninstall_meshtasticd
        ;;
      3)
        return 0
        ;;
    esac
  done
}

app_action_menu() {
  local index="$1"
  local label="${APP_LABELS[$index]}"
  local manager="${APP_MANAGERS[$index]}"
  local package="${APP_PACKAGES[$index]}"
  local prompt="Manager: ${manager} | Package: ${package}"
  local action

  while true; do
    menu_choose "$label" "$prompt" APP_ACTION_LABELS || return 0
    action="${APP_ACTION_KEYS[$MENU_RESULT]}"
    if [[ "$action" == "back" ]]; then
      return 0
    fi

    manage_app_action "$label" "$manager" "$package" "$action"
  done
}

mesh_apps_menu() {
  load_app_registry
  if (( ${#APP_LABELS[@]} == 0 )); then
    message_box "No mesh apps are configured. Add entries to $APP_REGISTRY."
    return 0
  fi

  indexed_list_menu 'Mesh Apps Manager' \
    'Install, upgrade, or remove configured Meshtastic companion apps.' \
    APP_LABELS app_action_menu
}

board_config_file_menu() {
  local title="$1"
  local directory="$2"
  local empty_message="$3"
  local handler="$4"
  local configs=()

  list_relative_files "$directory" configs
  if (( ${#configs[@]} == 0 )); then
    message_box "$empty_message"
    return 0
  fi

  configs+=("Back")
  while true; do
    menu_choose "$title" "$directory" configs || return 0
    if (( MENU_RESULT == ${#configs[@]} - 1 )); then
      return 0
    fi

    "$handler" "${configs[$MENU_RESULT]}"
    return 0
  done
}

board_config_menu() {
  local options=("Apply available config" "Remove active config" "Back")

  while true; do
    menu_choose 'Board Config' 'Copy configs from available.d into config.d or remove active configs.' options || return 0
    case "$MENU_RESULT" in
      0)
        board_config_file_menu 'Apply Board Config' "$AVAILABLE_CONFIG_DIR" \
          "No configs found in $AVAILABLE_CONFIG_DIR" apply_board_config
        ;;
      1)
        board_config_file_menu 'Remove Board Config' "$ACTIVE_CONFIG_DIR" \
          "No active configs found in $ACTIVE_CONFIG_DIR" remove_board_config
        ;;
      2)
        return 0
        ;;
    esac
  done
}

main_menu() {
  local options=(
    "Contact"
    "Meshtastic Related Services"
    "meshtasticd Repository"
    "Mesh Apps Manager"
    "Network Quick Start"
    "Board Config"
    "Exit"
  )

  while true; do
    menu_choose 'Main Menu' 'Lightweight TUI for mPWRD-OS.' options || return 0
    case "$MENU_RESULT" in
      0)
        run_terminal_program pause contact
        ;;
      1)
        related_services_menu
        ;;
      2)
        repo_menu
        ;;
      3)
        mesh_apps_menu
        ;;
      4)
        run_terminal_program root-no-pause nmtui
        ;;
      5)
        board_config_menu
        ;;
      6)
        return 0
        ;;
    esac
  done
}

hide_cursor
main_menu
clear_screen
