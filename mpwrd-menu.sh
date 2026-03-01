#!/usr/bin/env bash

set -u

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_REGISTRY_DEFAULT="$SCRIPT_DIR/mesh-apps.conf"
readonly APP_REGISTRY_EXAMPLE="$SCRIPT_DIR/mesh-apps.conf.example"
readonly APP_REGISTRY="${APP_REGISTRY:-$APP_REGISTRY_DEFAULT}"
readonly MESHTASTIC_PACKAGE="meshtasticd"
readonly MESHTASTIC_DEBIAN_SERIES="Debian_13"
readonly AVAILABLE_CONFIG_DIR="/etc/meshtasticd/available.d"
readonly ACTIVE_CONFIG_DIR="/etc/meshtasticd/config.d"

MENU_RESULT=-1
READ_KEY=""
APP_LABELS=()
APP_MANAGERS=()
APP_PACKAGES=()

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
  local program="$1"
  shift || true

  if ! command_exists "$program"; then
    message_box "Command not found: $program"
    return 1
  fi

  run_and_pause "Launching $program..." "$program" "$@"
}

run_terminal_program_no_pause() {
  local program="$1"
  shift || true

  if ! command_exists "$program"; then
    message_box "Command not found: $program"
    return 1
  fi

  show_cursor
  clear_screen
  "$program" "$@"
  hide_cursor
}

apt_install_package() {
  local package="$1"
  as_root apt-get update && as_root apt-get install -y "$package"
}

apt_upgrade_package() {
  local package="$1"
  as_root apt-get update && as_root apt-get install --only-upgrade -y "$package"
}

apt_remove_package() {
  local package="$1"
  as_root apt-get remove -y "$package"
}

install_board_config_file() {
  local source_file="$1"
  local target_file="$2"
  as_root mkdir -p "$ACTIVE_CONFIG_DIR" && as_root install -m 0644 "$source_file" "$target_file"
}

load_app_registry() {
  local source_file="$APP_REGISTRY"
  local label manager package

  if [[ ! -f "$source_file" && -f "$APP_REGISTRY_EXAMPLE" ]]; then
    source_file="$APP_REGISTRY_EXAMPLE"
  fi

  APP_LABELS=()
  APP_MANAGERS=()
  APP_PACKAGES=()

  [[ -f "$source_file" ]] || return 0

  while IFS='|' read -r label manager package; do
    label="$(trim "${label:-}")"
    manager="$(trim "${manager:-}")"
    package="$(trim "${package:-}")"

    if [[ -z "$label" || "${label:0:1}" == "#" ]]; then
      continue
    fi

    if [[ -z "$manager" || -z "$package" ]]; then
      continue
    fi

    APP_LABELS+=("$label")
    APP_MANAGERS+=("$manager")
    APP_PACKAGES+=("$package")
  done < "$source_file"
}

current_repo_channel() {
  local found=()
  local channel

  for channel in beta alpha daily; do
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
  current="$(current_repo_channel)"
  [[ "$current" == beta || "$current" == alpha || "$current" == daily ]]
}

switch_repo_channel() {
  local channel="$1"
  local repo_http="http://download.opensuse.org/repositories/network:/Meshtastic:/${channel}/${MESHTASTIC_DEBIAN_SERIES}/"
  local repo_https="https://download.opensuse.org/repositories/network:/Meshtastic:/${channel}/${MESHTASTIC_DEBIAN_SERIES}/"
  local list_file="/etc/apt/sources.list.d/network:Meshtastic:${channel}.list"
  local key_file="/etc/apt/trusted.gpg.d/network_Meshtastic_${channel}.gpg"
  local temp_list temp_key existing rc=0
  local os_name=""

  if [[ -r /etc/os-release ]]; then
    os_name="$(. /etc/os-release 2>/dev/null; printf '%s' "${NAME:-}")"
  fi

  if [[ "$os_name" == Raspbian* ]]; then
    message_box 'Raspberry Pi OS detected. Use the Raspbian Meshtastic repositories instead.'
    return 1
  fi

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

  for existing in beta alpha daily; do
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

  run_and_pause 'Installing meshtasticd...' apt_install_package "$MESHTASTIC_PACKAGE"
}

upgrade_meshtasticd() {
  if ! repo_is_ready; then
    message_box 'Select beta, alpha, or daily first so meshtasticd upgrades from the correct repository.'
    return 1
  fi

  run_and_pause 'Upgrading meshtasticd...' apt_upgrade_package "$MESHTASTIC_PACKAGE"
}

uninstall_meshtasticd() {
  run_and_pause 'Uninstalling meshtasticd...' apt_remove_package "$MESHTASTIC_PACKAGE"
}

manage_service() {
  local unit="$1"
  local action="$2"
  run_and_pause "systemctl ${action} ${unit}" as_root systemctl "$action" "$unit"
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

list_regular_files() {
  local dir="$1"
  local result_name="$2"
  local -n result_ref="$result_name"

  result_ref=()
  [[ -d "$dir" ]] || return 0

  mapfile -t result_ref < <(find "$dir" -maxdepth 1 -mindepth 1 -type f -printf '%f\n' 2>/dev/null | sort)
}

apply_board_config() {
  local filename="$1"
  local source_path="$AVAILABLE_CONFIG_DIR/$filename"
  local target_path="$ACTIVE_CONFIG_DIR/$filename"

  if [[ ! -f "$source_path" ]]; then
    message_box "Config not found: $source_path"
    return 1
  fi

  run_and_pause "Applying board config: $filename" install_board_config_file "$source_path" "$target_path"
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

  case "$manager" in
    apt)
      case "$action" in
        install)
          run_and_pause "Installing ${label}..." apt_install_package "$package"
          ;;
        upgrade)
          run_and_pause "Upgrading ${label}..." apt_upgrade_package "$package"
          ;;
        uninstall)
          run_and_pause "Uninstalling ${label}..." apt_remove_package "$package"
          ;;
      esac
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

      case "$action" in
        install)
          run_and_pause "Installing ${label}..." pipx install "$package"
          ;;
        upgrade)
          run_and_pause "Upgrading ${label}..." pipx upgrade "$package"
          ;;
        uninstall)
          run_and_pause "Uninstalling ${label}..." pipx uninstall "$package"
          ;;
      esac
      ;;
    *)
      message_box "Unsupported app manager: $manager"
      return 1
      ;;
  esac
}

service_menu() {
  local service_label="$1"
  local unit="$2"
  local options=("Status" "Start" "Stop" "Restart" "Enable" "Disable" "Back")
  local prompt

  while true; do
    prompt="$(service_status_prompt "$unit")"
    menu_choose "$service_label" "$prompt" options || return 0
    case "$MENU_RESULT" in
      0)
        run_and_pause "systemctl status ${unit}" systemctl status --no-pager --full "$unit"
        ;;
      1)
        manage_service "$unit" start
        ;;
      2)
        manage_service "$unit" stop
        ;;
      3)
        manage_service "$unit" restart
        ;;
      4)
        manage_service "$unit" enable
        ;;
      5)
        manage_service "$unit" disable
        ;;
      6)
        return 0
        ;;
    esac
  done
}

related_services_menu() {
  local options=("meshtasticd" "avahi" "wifisync" "Back")

  while true; do
    menu_choose 'Meshtastic Related Services' 'Manage systemd units for Meshtastic support services.' options || return 0
    case "$MENU_RESULT" in
      0)
        service_menu 'meshtasticd' 'meshtasticd.service'
        ;;
      1)
        service_menu 'avahi' 'avahi-daemon.service'
        ;;
      2)
        service_menu 'wifisync' 'wifisync.service'
        ;;
      3)
        return 0
        ;;
    esac
  done
}

repo_menu() {
  local options=("Switch to beta" "Switch to alpha" "Switch to daily" "Install meshtasticd" "Upgrade meshtasticd" "Uninstall meshtasticd" "Back")
  local prompt

  while true; do
    prompt="Current repo: $(current_repo_channel)"
    menu_choose 'meshtasticd Repository' "$prompt" options || return 0
    case "$MENU_RESULT" in
      0)
        switch_repo_channel beta
        ;;
      1)
        switch_repo_channel alpha
        ;;
      2)
        switch_repo_channel daily
        ;;
      3)
        install_meshtasticd
        ;;
      4)
        upgrade_meshtasticd
        ;;
      5)
        uninstall_meshtasticd
        ;;
      6)
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
  local options=("Install" "Upgrade" "Uninstall" "Back")
  local prompt="Manager: ${manager} | Package: ${package}"

  while true; do
    menu_choose "$label" "$prompt" options || return 0
    case "$MENU_RESULT" in
      0)
        manage_app_action "$label" "$manager" "$package" install
        ;;
      1)
        manage_app_action "$label" "$manager" "$package" upgrade
        ;;
      2)
        manage_app_action "$label" "$manager" "$package" uninstall
        ;;
      3)
        return 0
        ;;
    esac
  done
}

mesh_apps_menu() {
  local options=()
  local i

  load_app_registry
  if (( ${#APP_LABELS[@]} == 0 )); then
    message_box "No mesh apps are configured. Add entries to $APP_REGISTRY or $APP_REGISTRY_EXAMPLE."
    return 0
  fi

  while true; do
    options=()
    for i in "${APP_LABELS[@]}"; do
      options+=("$i")
    done
    options+=("Back")

    menu_choose 'Mesh Apps Manager' 'Install, upgrade, or remove configured Meshtastic companion apps.' options || return 0
    if (( MENU_RESULT == ${#APP_LABELS[@]} )); then
      return 0
    fi

    app_action_menu "$MENU_RESULT"
  done
}

select_available_board_config() {
  local configs=()

  list_regular_files "$AVAILABLE_CONFIG_DIR" configs
  if (( ${#configs[@]} == 0 )); then
    message_box "No configs found in $AVAILABLE_CONFIG_DIR"
    return 0
  fi

  configs+=("Back")
  while true; do
    menu_choose 'Apply Board Config' "$AVAILABLE_CONFIG_DIR" configs || return 0
    if (( MENU_RESULT == ${#configs[@]} - 1 )); then
      return 0
    fi

    apply_board_config "${configs[$MENU_RESULT]}"
    return 0
  done
}

select_active_board_config() {
  local configs=()

  list_regular_files "$ACTIVE_CONFIG_DIR" configs
  if (( ${#configs[@]} == 0 )); then
    message_box "No active configs found in $ACTIVE_CONFIG_DIR"
    return 0
  fi

  configs+=("Back")
  while true; do
    menu_choose 'Remove Board Config' "$ACTIVE_CONFIG_DIR" configs || return 0
    if (( MENU_RESULT == ${#configs[@]} - 1 )); then
      return 0
    fi

    remove_board_config "${configs[$MENU_RESULT]}"
    return 0
  done
}

board_config_menu() {
  local options=("Apply available config" "Remove active config" "Back")

  while true; do
    menu_choose 'Board Config' 'Copy configs from available.d into config.d or remove active configs.' options || return 0
    case "$MENU_RESULT" in
      0)
        select_available_board_config
        ;;
      1)
        select_active_board_config
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
        run_terminal_program contact
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
        run_terminal_program_no_pause nmtui
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
