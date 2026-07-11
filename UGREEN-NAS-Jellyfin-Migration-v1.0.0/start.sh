#!/usr/bin/env bash
# UGREEN NAS Jellyfin Migration
# v1.0.0 - first stable community release
#
# Copyright (c) 2026 Roman Glos / Railsimulatornet
# Author: Roman Glos
# License: MIT
#
# This script migrates the UGREEN App Center Jellyfin app to a standalone
# Docker Compose project on UGREEN NAS / UGOS Pro systems.

set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="1.0.0"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

# -----------------------------
# Defaults
# -----------------------------
LANGUAGE="${LANGUAGE:-de}"
INTERACTIVE="${INTERACTIVE:-true}"
ASSUME_YES="false"
MIGRATION_MODE="${MIGRATION_MODE:-SAFE_MIGRATION}"

DOCKER_PROJECT_PATH="${DOCKER_PROJECT_PATH:-auto}"
BACKUP_PATH="${BACKUP_PATH:-auto}"
MEDIA_MOUNT_MODE="${MEDIA_MOUNT_MODE:-rw}"
JELLYFIN_PORT_HTTP="${JELLYFIN_PORT_HTTP:-auto}"
JELLYFIN_IMAGE="${JELLYFIN_IMAGE:-jellyfin/jellyfin:latest}"
JELLYFIN_CONTAINER_NAME="${JELLYFIN_CONTAINER_NAME:-jellyfin-docker}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-jellyfin-docker}"
UGOS_PROJECT_NAME="${UGOS_PROJECT_NAME:-jellyfin-docker}"
COMPOSE_FILE_NAME="${COMPOSE_FILE_NAME:-docker-compose.yaml}"
LEGACY_TEST_PROJECT_CLEANUP="${LEGACY_TEST_PROJECT_CLEANUP:-ask}"  # ask | true | false

UGOS_DOCKER_DB="${UGOS_DOCKER_DB:-auto}"
REGISTER_UGOS_PROJECT="${REGISTER_UGOS_PROJECT:-ask}"  # ask | true | false
REFRESH_UGOS_DOCKER_APP="${REFRESH_UGOS_DOCKER_APP:-ask}"  # ask | true | false
UGOS_DOCKER_SERVICE="${UGOS_DOCKER_SERVICE:-docker_serv}"
UGOS_DB_STATUS="not executed"
UGOS_REFRESH_STATUS="not executed"

JELLYFIN_USER="${JELLYFIN_USER:-auto}"
JELLYFIN_UID="${JELLYFIN_UID:-auto}"
JELLYFIN_GID="${JELLYFIN_GID:-auto}"
JELLYFIN_GROUPS="${JELLYFIN_GROUPS:-auto}"

ENABLE_HARDWARE_ACCEL="${ENABLE_HARDWARE_ACCEL:-auto}"
STOP_UGREEN_APP="${STOP_UGREEN_APP:-true}"
REMOVE_UGREEN_APP="${REMOVE_UGREEN_APP:-false}"
I_UNDERSTAND_UGREEN_APP_REMOVAL="${I_UNDERSTAND_UGREEN_APP_REMOVAL:-false}"
CACHE_MIGRATE="${CACHE_MIGRATE:-false}"
TZ="${TZ:-Europe/Berlin}"

ROOT_METADATA_SCAN="${ROOT_METADATA_SCAN:-true}"
ROOT_METADATA_ACTION="${ROOT_METADATA_ACTION:-ask}"   # ask | skip | owner | owner-perms
ROOT_METADATA_REPORT_LIMIT="${ROOT_METADATA_REPORT_LIMIT:-5000}"
PROTECT_MEDIA_FILES="${PROTECT_MEDIA_FILES:-true}"

WORK_DIR=""
LOG_FILE=""
UGREEN_CONTAINER=""
UGREEN_IMAGE=""
UGREEN_CONFIG_SOURCE=""
UGREEN_CACHE_SOURCE=""
UGREEN_PLUGIN_SOURCE=""
UGREEN_HOST_PORT=""
UGREEN_CONTAINER_PORT="8096"
DOCKER_BASE_DIR=""
BACKUP_RUN_DIR=""
COMPOSE_CMD=()
NAS_MODEL="UGREEN"
ARCH=""
BACKUP_SUCCESS="false"
NEW_CONTAINER_STARTED="false"
UGOS_DB_BACKUP=""
POST_START_WARNING="false"
NAS_ACCESS_IP=""
UGREEN_OLD_RESTART_POLICY=""
OLD_APP_STATUS="unknown"

MEDIA_MOUNTS_FILE=""
DEVICES_FILE=""
ROOT_METADATA_REPORT=""
FAILED_ACCESS_FILE=""

# -----------------------------
# Small helpers
# -----------------------------
lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
is_true() { case "$(lower "${1:-}")" in true|1|yes|ja|j|y|on) return 0 ;; *) return 1 ;; esac; }
is_false() { case "$(lower "${1:-}")" in false|0|no|nein|n|off|"") return 0 ;; *) return 1 ;; esac; }
is_en() { [[ "$(lower "$LANGUAGE")" == en* ]]; }
tr_text() { local de="$1" en="$2"; if is_en; then printf '%s' "$en"; else printf '%s' "$de"; fi; }

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if [ -n "${LOG_FILE:-}" ]; then
    printf '[%s] %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
  else
    printf '[%s] %s\n' "$ts" "$*"
  fi
}

warn() { log "$(tr_text 'WARNUNG:' 'WARNING:') $*"; }
fail() { log "$(tr_text 'FEHLER:' 'ERROR:') $*"; exit 1; }

safe_mkdir_parent_check() {
  local path="$1" parent
  parent="$(dirname "$path")"
  [ -d "$parent" ] || return 1
  [ -w "$parent" ] || return 1
  return 0
}

is_safe_volume_path() {
  local p="$1"
  [[ "$p" =~ ^/volume[0-9]+/.+ ]] || return 1
  case "$p" in
    /|/volume[0-9]|/volume[0-9]/|/volume[0-9]/@appstore|/volume[0-9]/@appstore/*)
      return 1 ;;
  esac
  return 0
}

shell_escape_double_quotes() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

ask_yes_no() {
  local question="$1" default="${2:-no}" answer prompt initial
  default="$(lower "$default")"
  case "$default" in
    true|1|yes|y|ja|j) default="yes" ;;
    *) default="no" ;;
  esac

  if is_true "$ASSUME_YES" || is_false "$INTERACTIVE"; then
    [ "$default" = "yes" ] && return 0 || return 1
  fi

  if [ "$default" = "yes" ]; then
    prompt="$(tr_text '[J/n]' '[Y/n]')"
    initial="$(tr_text 'j' 'y')"
  else
    prompt="$(tr_text '[j/N]' '[y/N]')"
    initial="n"
  fi

  while :; do
    printf '%s %s ' "$question" "$prompt"
    if [ -t 0 ] && [ -t 1 ]; then
      # Show the default value directly in the input field. Pressing ENTER accepts it.
      if ! read -r -e -i "$initial" answer; then
        answer="$initial"
        echo
      fi
    else
      read -r answer || true
      [ -n "${answer:-}" ] || answer="$initial"
    fi
    answer="$(lower "${answer:-}")"
    if [ -z "$answer" ]; then
      answer="$initial"
    fi
    case "$answer" in
      j|ja|y|yes) return 0 ;;
      n|nein|no) return 1 ;;
    esac
  done
}

pause_enter() {
  is_true "$ASSUME_YES" && return 0
  is_false "$INTERACTIVE" && return 0
  printf '%s' "$(tr_text 'Weiter mit Enter ...' 'Press Enter to continue ...')"
  read -r _ || true
}

show_help() {
  cat <<EOF_HELP
UGREEN NAS Jellyfin Migration v${SCRIPT_VERSION}

Usage:
  sudo ./start.sh
  sudo ./start.sh --check-only
  sudo ./start.sh --backup-only
  sudo ./start.sh --safe-migration
  sudo ./start.sh --full-migration
  sudo ./start.sh --yes
  sudo ./start.sh --lang de|en
  sudo ./start.sh --env /path/to/.env

Modes:
  CHECK_ONLY      only checks, changes nothing
  BACKUP_ONLY     creates a backup only, old app keeps running
  SAFE_MIGRATION  backup + migrate + stop old UGREEN app + start new container
  FULL_MIGRATION  like SAFE_MIGRATION, then optionally removes old container

Notes:
  - No sudo -i is used inside this script.
  - Media folder ownership is never changed automatically.
  - The old UGREEN app is stopped in SAFE_MIGRATION so the new container can use the same port.
  - v0.1.3 uses a separate project/container name to avoid conflicts with the UGREEN app.
EOF_HELP
}

# -----------------------------
# Load .env early, parse args, language prompt
# -----------------------------
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) show_help; exit 0 ;;
      --check-only) MIGRATION_MODE="CHECK_ONLY" ;;
      --backup-only) MIGRATION_MODE="BACKUP_ONLY" ;;
      --safe-migration) MIGRATION_MODE="SAFE_MIGRATION" ;;
      --full-migration) MIGRATION_MODE="FULL_MIGRATION" ;;
      --yes|-y) ASSUME_YES="true"; INTERACTIVE="false" ;;
      --lang|--language)
        shift || fail "Missing value for --lang"
        LANGUAGE="$1"
        ;;
      --env)
        shift || fail "Missing value for --env"
        ENV_FILE="$1"
        if [ -f "$ENV_FILE" ]; then
          set -a
          # shellcheck disable=SC1090
          source "$ENV_FILE"
          set +a
        else
          fail "ENV file not found: $ENV_FILE"
        fi
        ;;
      *) fail "Unknown argument: $1" ;;
    esac
    shift
  done
}
parse_args "$@"

choose_language() {
  is_true "$ASSUME_YES" && return 0
  is_false "$INTERACTIVE" && return 0
  echo
  echo "UGREEN NAS Jellyfin Migration v${SCRIPT_VERSION}"
  echo
  echo "Bitte Sprache auswählen / Please choose your language:"
  echo "  [1] Deutsch"
  echo "  [2] English"
  printf "Auswahl / Selection [%s]: " "$(is_en && echo 2 || echo 1)"
  local sel
  read -r sel || true
  case "${sel:-}" in
    2|en|EN|English|english) LANGUAGE="en" ;;
    1|de|DE|Deutsch|deutsch|"") LANGUAGE="de" ;;
    *) LANGUAGE="de" ;;
  esac
}
choose_language

# -----------------------------
# Requirements and detection
# -----------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "$(tr_text 'Dieses Skript muss als root laufen. Bitte mit sudo ./start.sh starten.' 'This script must run as root. Please start it with sudo ./start.sh.')"
  fi
}

require_commands() {
  command -v docker >/dev/null 2>&1 || fail "Docker wurde nicht gefunden."
  command -v python3 >/dev/null 2>&1 || fail "python3 wurde nicht gefunden."
  command -v tar >/dev/null 2>&1 || fail "tar wurde nicht gefunden."
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    fail "docker compose / docker-compose wurde nicht gefunden."
  fi
}

setup_workdir() {
  WORK_DIR="/tmp/ugreen-jellyfin-migration.$$"
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  LOG_FILE="$WORK_DIR/migration.log"
  MEDIA_MOUNTS_FILE="$WORK_DIR/media-mounts.tsv"
  DEVICES_FILE="$WORK_DIR/devices.tsv"
  FAILED_ACCESS_FILE="$WORK_DIR/failed-access.tsv"
  ROOT_METADATA_REPORT="$WORK_DIR/root-owned-metadata-report.txt"
  touch "$LOG_FILE" "$MEDIA_MOUNTS_FILE" "$DEVICES_FILE" "$FAILED_ACCESS_FILE" "$ROOT_METADATA_REPORT"
}

cleanup() {
  # keep workdir if DEBUG_KEEP_WORKDIR=true
  if ! is_true "${DEBUG_KEEP_WORKDIR:-false}"; then
    rm -rf "$WORK_DIR" 2>/dev/null || true
  else
    echo "DEBUG_KEEP_WORKDIR=true -> $WORK_DIR"
  fi
}
trap cleanup EXIT

get_raw_model_string() {
  local cand="" pn="" pv="" bn="" dt="" dm=""
  if [ -r /sys/class/dmi/id/product_name ]; then
    pn="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    pv="$(cat /sys/class/dmi/id/product_version 2>/dev/null || true)"
    bn="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"
    cand="$pn $pv $bn"
  fi
  if [ -z "$cand" ] && [ -r /proc/device-tree/model ]; then
    dt="$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)"
    cand="$dt"
  fi
  if [ -z "$cand" ] || ! echo "$cand" | grep -qiE '(DH|DXP|DX|iDX|IDX)[0-9]{3,4}'; then
    dm="$(dmesg 2>/dev/null | grep -m1 -E 'Hardware name:|Machine model:' | sed -E 's/.*(Hardware name:|Machine model:)[[:space:]]*//')"
    [ -n "$dm" ] && cand="$dm"
  fi
  cand="$(echo "$cand" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  echo "$cand"
}

normalize_model() {
  python3 - "$1" <<'PYEOF'
import re, sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
r = raw.upper().replace("UGREEN", " ").replace("DEFAULT STRING", " ").replace("/", " ")
r = re.sub(r"\s+", " ", r).strip()
tokens = r.replace(" ", "")
known = ["DXP480TPLUS","DX4700","IDX6011PRO","IDX6011","DH4300PLUS","DH2300","DXP2800GT","DXP2800","DXP4800GT","DXP4800PRO","DXP4800PLUS","DXP4800","DXP6800ULTRA","DXP6800PRO","DXP6800PLUS","DXP8800ULTRA","DXP8800PRO","DXP8800PLUS"]
for k in known:
    if k in tokens:
        print(k); sys.exit(0)
m = re.search(r"(IDX[0-9]{4}PRO|IDX[0-9]{4}|DH[0-9]{4}PLUS|DH[0-9]{4}|DXP[0-9]{4}ULTRA|DXP[0-9]{4}GT|DXP[0-9]{4}T?PLUS|DXP[0-9]{4}PRO|DXP[0-9]{4}|DX[0-9]{4})", tokens)
print(m.group(1) if m else "UGREEN")
PYEOF
}

detect_system() {
  ARCH="$(uname -m 2>/dev/null || echo unknown)"
  NAS_MODEL="$(normalize_model "$(get_raw_model_string)")"
}

detect_access_ip() {
  # Best effort only: this is used for the final user-facing URL.
  # Prefer the address the system would use for outbound LAN/default traffic.
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -o -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}' | head -n1 || true)"
    if [ -z "$ip" ]; then
      ip="$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); if(a[1] !~ /^127\./){print a[1]; exit}}' | head -n1 || true)"
    fi
  fi
  if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | tr ' ' '
' | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $0 !~ /^127\./ {print; exit}' || true)"
  fi
  NAS_ACCESS_IP="$ip"
}

detect_ugreen_jellyfin_container() {
  local candidates count
  candidates="$(docker ps -a --format '{{.Names}}|{{.Image}}' | awk -F'|' 'tolower($2) ~ /ugreen\/jellyfin/ {print $0}')"
  count="$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" = "0" ]; then
    candidates="$(docker ps -a --format '{{.Names}}|{{.Image}}' | awk -F'|' 'tolower($0) ~ /jellyfin/ {print $0}')"
    count="$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')"
  fi
  [ "$count" != "0" ] || fail "$(tr_text 'Kein Jellyfin-Container gefunden.' 'No Jellyfin container found.')"

  if [ "$count" = "1" ]; then
    UGREEN_CONTAINER="$(printf '%s\n' "$candidates" | head -n1 | cut -d'|' -f1)"
  else
    if is_false "$INTERACTIVE"; then
      printf '%s\n' "$candidates" >&2
      fail "$(tr_text 'Mehrere Jellyfin-Container gefunden. Bitte manuell bereinigen oder interaktiv starten.' 'Multiple Jellyfin containers found. Please clean up manually or run interactively.')"
    fi
    echo
    echo "$(tr_text 'Mehrere Jellyfin-Container gefunden:' 'Multiple Jellyfin containers found:')"
    local i=1 line sel
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      echo "  [$i] $line"
      i=$((i+1))
    done <<EOF_CAND
$candidates
EOF_CAND
    printf '%s ' "$(tr_text 'Bitte Container auswählen:' 'Please select container:')"
    read -r sel || true
    UGREEN_CONTAINER="$(printf '%s\n' "$candidates" | sed -n "${sel:-1}p" | cut -d'|' -f1)"
  fi

  [ -n "$UGREEN_CONTAINER" ] || fail "Container-Auswahl fehlgeschlagen."
  UGREEN_IMAGE="$(docker inspect "$UGREEN_CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || true)"
  [ -n "$UGREEN_IMAGE" ] || UGREEN_IMAGE="ugreen/jellyfin:v1"
}

inspect_ugreen_container() {
  local inspect_json="$WORK_DIR/docker-inspect.json"
  docker inspect "$UGREEN_CONTAINER" > "$inspect_json" 2>"$WORK_DIR/docker-inspect.err" || fail "docker inspect fehlgeschlagen."

  python3 - "$inspect_json" "$MEDIA_MOUNTS_FILE" "$DEVICES_FILE" "$WORK_DIR/vars.env" <<'PYEOF'
import json, sys, os, re
inspect_path, media_out, dev_out, vars_out = sys.argv[1:5]
with open(inspect_path, 'r', encoding='utf-8') as f:
    data = json.load(f)[0]
mounts = data.get('Mounts') or []
hc = data.get('HostConfig') or {}
config_source = ''
cache_source = ''
plugin_source = ''
media = []
for m in mounts:
    src = m.get('Source') or ''
    dst = m.get('Destination') or ''
    rw = 'true' if m.get('RW', False) else 'false'
    if dst == '/config':
        config_source = src
    elif dst == '/cache':
        cache_source = src
    elif dst == '/config/plugins':
        plugin_source = src
    else:
        # Anything else is treated as a media/resource mount and preserved 1:1.
        if src and dst:
            media.append((src, dst, rw))

ports = hc.get('PortBindings') or {}
host_port = ''
container_port = '8096'
for key, bindings in ports.items():
    if key.startswith('8096/') and bindings:
        host_port = bindings[0].get('HostPort') or ''
        container_port = key.split('/')[0]
        break
if not host_port:
    for key, bindings in ports.items():
        if bindings:
            host_port = bindings[0].get('HostPort') or ''
            container_port = key.split('/')[0]
            break

devices = hc.get('Devices') or []
def media_sort_key(item):
    src, dst, rw = item
    # Keep Jellyfin's primary UGREEN media mount (/data) first, then sort
    # remaining mounts by their host path for stable and readable output.
    return (0 if dst == '/data' else 1, src.lower(), dst.lower())

media = sorted(media, key=media_sort_key)

with open(media_out, 'w', encoding='utf-8') as f:
    for src, dst, rw in media:
        f.write(f"{src}\t{dst}\t{rw}\n")
with open(dev_out, 'w', encoding='utf-8') as f:
    for d in devices:
        hp = d.get('PathOnHost') or ''
        cp = d.get('PathInContainer') or hp
        perm = d.get('CgroupPermissions') or 'rwm'
        if hp and cp:
            f.write(f"{hp}\t{cp}\t{perm}\n")

def q(s):
    return "'" + str(s).replace("'", "'\\''") + "'"
with open(vars_out, 'w', encoding='utf-8') as f:
    f.write(f"UGREEN_CONFIG_SOURCE={q(config_source)}\n")
    f.write(f"UGREEN_CACHE_SOURCE={q(cache_source)}\n")
    f.write(f"UGREEN_PLUGIN_SOURCE={q(plugin_source)}\n")
    f.write(f"UGREEN_HOST_PORT={q(host_port)}\n")
    f.write(f"UGREEN_CONTAINER_PORT={q(container_port)}\n")
PYEOF
  # shellcheck disable=SC1090
  source "$WORK_DIR/vars.env"

  [ -n "$UGREEN_CONFIG_SOURCE" ] && [ -d "$UGREEN_CONFIG_SOURCE" ] || fail "UGREEN /config Quelle wurde nicht gefunden: $UGREEN_CONFIG_SOURCE"
  [ -n "$UGREEN_CACHE_SOURCE" ] && [ -d "$UGREEN_CACHE_SOURCE" ] || warn "UGREEN /cache Quelle fehlt oder ist nicht lesbar: $UGREEN_CACHE_SOURCE"
  if [ -n "$UGREEN_PLUGIN_SOURCE" ] && [ ! -d "$UGREEN_PLUGIN_SOURCE" ]; then
    fail "UGREEN /config/plugins ist separat gemountet, aber die Quelle fehlt: $UGREEN_PLUGIN_SOURCE"
  fi
  [ -s "$MEDIA_MOUNTS_FILE" ] || fail "Keine Medien-/Ressourcen-Mounts im UGREEN-Jellyfin-Container gefunden."
}

detect_docker_base_dir() {
  local from_plugin base found sel i line
  from_plugin=""
  if [ -n "${UGREEN_PLUGIN_SOURCE:-}" ]; then
    from_plugin="$(printf '%s' "$UGREEN_PLUGIN_SOURCE" | sed -nE 's#^(/volume[0-9]+/docker)(/.*)?$#\1#p')"
  fi
  if [ -n "$from_plugin" ] && [ -d "$from_plugin" ]; then
    DOCKER_BASE_DIR="$from_plugin"
    return 0
  fi

  found="$(find /volume* -maxdepth 1 -type d -name docker 2>/dev/null | sort || true)"
  if [ -z "$found" ]; then
    fail "$(tr_text 'Kein /volumeX/docker Ordner gefunden.' 'No /volumeX/docker folder found.')"
  fi
  if [ "$(printf '%s\n' "$found" | sed '/^$/d' | wc -l | tr -d ' ')" = "1" ]; then
    DOCKER_BASE_DIR="$found"
    return 0
  fi
  if is_false "$INTERACTIVE"; then
    DOCKER_BASE_DIR="$(printf '%s\n' "$found" | head -n1)"
    return 0
  fi
  echo
  echo "$(tr_text 'Mehrere Docker-Ordner gefunden:' 'Multiple Docker folders found:')"
  i=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "  [$i] $line"
    i=$((i+1))
  done <<EOF_FOUND
$found
EOF_FOUND
  printf '%s ' "$(tr_text 'Bitte Docker-Basisordner auswählen:' 'Please select Docker base folder:')"
  read -r sel || true
  DOCKER_BASE_DIR="$(printf '%s\n' "$found" | sed -n "${sel:-1}p")"
  [ -n "$DOCKER_BASE_DIR" ] || fail "Docker-Basisordner konnte nicht bestimmt werden."
}


detect_ugos_docker_db() {
  if [ "${UGOS_DOCKER_DB:-auto}" != "auto" ] && [ -n "${UGOS_DOCKER_DB:-}" ]; then
    if [ ! -f "$UGOS_DOCKER_DB" ]; then
      warn "$(tr_text "UGOS-Docker-DB wurde fest gesetzt, aber nicht gefunden: $UGOS_DOCKER_DB" "UGOS Docker DB was set manually but was not found: $UGOS_DOCKER_DB")"
      UGOS_DOCKER_DB=""
    fi
    return 0
  fi

  local base_volume docker_root matches count
  UGOS_DOCKER_DB=""
  base_volume=""
  if [ -n "${DOCKER_BASE_DIR:-}" ]; then
    base_volume="${DOCKER_BASE_DIR%/docker}"
  fi
  if [ -n "$base_volume" ] && [ -f "${base_volume}/@appstore/com.ugreen.docker/db/docker_info_log.db" ]; then
    UGOS_DOCKER_DB="${base_volume}/@appstore/com.ugreen.docker/db/docker_info_log.db"
    return 0
  fi

  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  if [ -n "$docker_root" ] && [ "$(basename "$docker_root")" = "@docker" ]; then
    base_volume="$(dirname "$docker_root")"
    if [ -f "${base_volume}/@appstore/com.ugreen.docker/db/docker_info_log.db" ]; then
      UGOS_DOCKER_DB="${base_volume}/@appstore/com.ugreen.docker/db/docker_info_log.db"
      return 0
    fi
  fi

  matches="$(find /volume* -path '*/@appstore/com.ugreen.docker/db/docker_info_log.db' -type f 2>/dev/null || true)"
  count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" = "1" ]; then
    UGOS_DOCKER_DB="$(printf '%s\n' "$matches" | sed '/^$/d' | head -n1)"
  elif [ "$count" -gt 1 ]; then
    warn "$(tr_text 'Mehrere UGOS-Docker-Datenbanken gefunden. UGOS-Registrierung wird übersprungen, wenn UGOS_DOCKER_DB nicht fest gesetzt wird.' 'Multiple UGOS Docker databases found. UGOS registration will be skipped unless UGOS_DOCKER_DB is set manually.')"
  fi
}

mode_is_check_only() {
  case "$(lower "$MIGRATION_MODE")" in check_only|check-only) return 0 ;; *) return 1 ;; esac
}

mode_is_migration() {
  case "$(lower "$MIGRATION_MODE")" in safe_migration|safe-migration|full_migration|full-migration) return 0 ;; *) return 1 ;; esac
}

maybe_cleanup_legacy_test_migration() {
  mode_is_migration || return 0
  local legacy_container="jellyfin" legacy_path="${DOCKER_BASE_DIR}/jellyfin" legacy_exists="false" legacy_image="" legacy_project="" legacy_workdir="" ts moved_path

  if docker inspect "$legacy_container" >/dev/null 2>&1; then
    legacy_image="$(docker inspect "$legacy_container" --format '{{.Config.Image}}' 2>/dev/null || true)"
    legacy_project="$(docker inspect "$legacy_container" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
    legacy_workdir="$(docker inspect "$legacy_container" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)"
    if ! printf '%s' "$legacy_image" | grep -qi '^ugreen/jellyfin'; then
      legacy_exists="true"
    fi
  fi

  if [ "$legacy_exists" = "false" ] && [ -d "$legacy_path" ] && [ -n "$(find "$legacy_path" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]; then
    # Old v0.1.0-v0.1.2 test project path exists. It does not block the port by itself, but it is confusing.
    legacy_exists="path-only"
  fi

  [ "$legacy_exists" != "false" ] || return 0

  warn "$(tr_text 'Eine ältere Testmigration wurde erkannt (Container/Projekt jellyfin). Das kann Port 8899 blockieren oder in UGOS verwirren.' 'An older test migration was detected (container/project jellyfin). It can block port 8899 or be confusing in UGOS.')"
  if [ -n "$legacy_image" ]; then log "  legacy container: $legacy_container / $legacy_image / project=${legacy_project:-?} / workdir=${legacy_workdir:-?}"; fi
  if [ -d "$legacy_path" ]; then log "  legacy path: $legacy_path"; fi

  case "$(lower "$LEGACY_TEST_PROJECT_CLEANUP")" in
    true|1|yes|ja|j|y) ;;
    false|0|no|nein|n|off)
      warn "$(tr_text 'Alte Testmigration wird nicht bereinigt.' 'Old test migration will not be cleaned up.')"
      return 0
      ;;
    ask|*)
      if ! ask_yes_no "$(tr_text 'Alte Testmigration jetzt sicher stoppen und den alten Projektordner umbenennen?' 'Stop old test migration now and rename the old project folder safely?')" "yes"; then
        warn "$(tr_text 'Alte Testmigration bleibt bestehen.' 'Old test migration remains unchanged.')"
        return 0
      fi
      ;;
  esac

  if docker inspect "$legacy_container" >/dev/null 2>&1; then
    log "$(tr_text "Entferne alten Testcontainer: $legacy_container" "Removing old test container: $legacy_container")"
    docker rm -f "$legacy_container" >> "$LOG_FILE" 2>&1 || warn "$(tr_text 'Alter Testcontainer konnte nicht entfernt werden.' 'Old test container could not be removed.')"
  fi
  if [ -d "$legacy_path" ]; then
    ts="$(date '+%Y%m%d_%H%M%S')"
    moved_path="${legacy_path}.old-${ts}"
    log "$(tr_text "Benenne alten Test-Projektordner um: $legacy_path -> $moved_path" "Renaming old test project folder: $legacy_path -> $moved_path")"
    mv "$legacy_path" "$moved_path" >> "$LOG_FILE" 2>&1 || warn "$(tr_text 'Alter Test-Projektordner konnte nicht umbenannt werden.' 'Old test project folder could not be renamed.')"
  fi
}

maybe_cleanup_existing_target_migration() {
  mode_is_migration || return 0

  local exists="false" ts moved_path compose_file
  compose_file="${DOCKER_PROJECT_PATH}/${COMPOSE_FILE_NAME}"

  if docker inspect "$JELLYFIN_CONTAINER_NAME" >/dev/null 2>&1; then
    exists="true"
  fi
  if [ -d "$DOCKER_PROJECT_PATH" ] && [ -n "$(find "$DOCKER_PROJECT_PATH" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]; then
    exists="true"
  fi

  [ "$exists" = "true" ] || return 0

  warn "$(tr_text 'Eine bestehende JellyfinDocker-Testmigration wurde erkannt. Für einen erneuten Migrationstest muss sie gestoppt und der Projektordner umbenannt werden.' 'An existing JellyfinDocker test migration was detected. For another migration test it must be stopped and the project folder must be renamed.')"
  log "  target container: $JELLYFIN_CONTAINER_NAME"
  log "  target path: $DOCKER_PROJECT_PATH"

  case "$(lower "$EXISTING_TARGET_PROJECT_CLEANUP")" in
    true|1|yes|ja|j|y) ;;
    false|0|no|nein|n|off)
      fail "$(tr_text 'Bestehende Ziel-Testmigration bleibt bestehen. Migration kann nicht sicher fortgesetzt werden.' 'Existing target test migration remains. Migration cannot safely continue.')"
      ;;
    ask|*)
      if ! ask_yes_no "$(tr_text 'Bestehende JellyfinDocker-Testmigration jetzt stoppen und den Projektordner umbenennen?' 'Stop the existing JellyfinDocker test migration now and rename the project folder?')" "yes"; then
        fail "$(tr_text 'Bestehende Ziel-Testmigration bleibt bestehen. Migration kann nicht sicher fortgesetzt werden.' 'Existing target test migration remains. Migration cannot safely continue.')"
      fi
      ;;
  esac

  if [ -f "$compose_file" ]; then
    log "$(tr_text "Stoppe bestehendes Ziel-Compose-Projekt: $COMPOSE_PROJECT_NAME" "Stopping existing target Compose project: $COMPOSE_PROJECT_NAME")"
    (cd "$DOCKER_PROJECT_PATH" && "${COMPOSE_CMD[@]}" -p "$COMPOSE_PROJECT_NAME" -f "$compose_file" down) >> "$LOG_FILE" 2>&1 || true
  fi

  if docker inspect "$JELLYFIN_CONTAINER_NAME" >/dev/null 2>&1; then
    log "$(tr_text "Entferne bestehenden Zielcontainer: $JELLYFIN_CONTAINER_NAME" "Removing existing target container: $JELLYFIN_CONTAINER_NAME")"
    docker rm -f "$JELLYFIN_CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || warn "$(tr_text 'Bestehender Zielcontainer konnte nicht entfernt werden.' 'Existing target container could not be removed.')"
  fi

  if [ -d "$DOCKER_PROJECT_PATH" ]; then
    ts="$(date '+%Y%m%d_%H%M%S')"
    moved_path="${DOCKER_PROJECT_PATH}.old-${ts}"
    log "$(tr_text "Benenne bestehenden Ziel-Projektordner um: $DOCKER_PROJECT_PATH -> $moved_path" "Renaming existing target project folder: $DOCKER_PROJECT_PATH -> $moved_path")"
    mv "$DOCKER_PROJECT_PATH" "$moved_path" >> "$LOG_FILE" 2>&1 || fail "$(tr_text 'Bestehender Ziel-Projektordner konnte nicht umbenannt werden.' 'Existing target project folder could not be renamed.')"
  fi
}

resolve_auto_values() {
  [ "$DOCKER_PROJECT_PATH" = "auto" ] && DOCKER_PROJECT_PATH="${DOCKER_BASE_DIR}/JellyfinDocker"
  [ "$BACKUP_PATH" = "auto" ] && BACKUP_PATH="${DOCKER_BASE_DIR}/Jellyfin-Migration-Backup"
  [ "$JELLYFIN_PORT_HTTP" = "auto" ] && JELLYFIN_PORT_HTTP="${UGREEN_HOST_PORT:-8096}"
}

resolve_uid_gid() {
  local user="" uid="" gid="" groups="" media_owner_uid="" media_owner_gid="" media_owner_user=""

  if [ "$JELLYFIN_USER" != "auto" ] && [ -n "$JELLYFIN_USER" ]; then
    user="$JELLYFIN_USER"
  elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != "root" ]; then
    user="$SUDO_USER"
  fi

  # Wenn das Skript bereits in einer root-Shell gestartet wird, ist SUDO_USER meist leer oder root.
  # Dann versuchen wir zuerst, den passenden NAS-Benutzer aus dem ersten nicht-root Medienpfad-Besitzer abzuleiten.
  # So werden 1000:10, 1009:10 usw. weiterhin dynamisch erkannt und nicht hart angenommen.
  if [ -z "$user" ]; then
    media_owner_uid="$(awk -F'\t' '{print $1}' "$MEDIA_MOUNTS_FILE" | while IFS= read -r p; do stat -c '%u' "$p" 2>/dev/null; done | awk '$1 != 0 {print; exit}')"
    media_owner_gid="$(awk -F'\t' '{print $1}' "$MEDIA_MOUNTS_FILE" | while IFS= read -r p; do stat -c '%g' "$p" 2>/dev/null; done | awk '$1 != 0 {print; exit}')"
    if [ -n "$media_owner_uid" ]; then
      media_owner_user="$(getent passwd "$media_owner_uid" 2>/dev/null | cut -d: -f1 | head -n1 || true)"
      if [ -n "$media_owner_user" ] && id "$media_owner_user" >/dev/null 2>&1; then
        user="$media_owner_user"
        log "$(tr_text "Kein normaler sudo-Benutzer erkannt. Verwende Medienpfad-Besitzer: ${user} (${media_owner_uid}:${media_owner_gid:-?})." "No normal sudo user detected. Using media path owner: ${user} (${media_owner_uid}:${media_owner_gid:-?}).")"
      fi
    fi
  fi

  if { [ "$JELLYFIN_UID" = "auto" ] || [ "$JELLYFIN_GID" = "auto" ]; } && [ -z "$user" ] && [ -z "$media_owner_uid" ] && is_true "$INTERACTIVE" && is_false "$ASSUME_YES"; then
    echo
    echo "$(tr_text 'Kein normaler sudo-Benutzer und kein nicht-root Medienpfad-Besitzer erkannt.' 'No normal sudo user and no non-root media path owner detected.')"
    printf '%s ' "$(tr_text 'Bitte NAS-Benutzer für Jellyfin eingeben (z.B. rogl):' 'Please enter NAS user for Jellyfin (e.g. roman):')"
    read -r user || true
  fi

  if [ "$JELLYFIN_UID" = "auto" ]; then
    if [ -n "$user" ] && id "$user" >/dev/null 2>&1; then
      uid="$(id -u "$user")"
    else
      uid="$media_owner_uid"
    fi
    [ -n "$uid" ] || fail "$(tr_text 'JELLYFIN_UID konnte nicht automatisch ermittelt werden.' 'Could not auto-detect JELLYFIN_UID.')"
    JELLYFIN_UID="$uid"
  fi

  if [ "$JELLYFIN_GID" = "auto" ]; then
    if [ -n "$user" ] && id "$user" >/dev/null 2>&1; then
      gid="$(id -g "$user")"
    else
      gid="$media_owner_gid"
    fi
    [ -n "$gid" ] || fail "$(tr_text 'JELLYFIN_GID konnte nicht automatisch ermittelt werden.' 'Could not auto-detect JELLYFIN_GID.')"
    JELLYFIN_GID="$gid"
  fi

  if [ "$JELLYFIN_GROUPS" = "auto" ]; then
    if [ -n "$user" ] && id "$user" >/dev/null 2>&1; then
      groups="$(id -G "$user" | tr ' ' '\n' | awk 'NF && !seen[$1]++ {print}' | paste -sd, -)"
    else
      groups="$JELLYFIN_GID"
    fi
    JELLYFIN_GROUPS="$groups"
  fi

  if [ "$JELLYFIN_UID" = "0" ] || [ "$JELLYFIN_GID" = "0" ]; then
    warn "$(tr_text 'Jellyfin würde als root laufen. Das wird nicht empfohlen.' 'Jellyfin would run as root. This is not recommended.')"
    if ! ask_yes_no "$(tr_text 'Root wirklich erlauben?' 'Really allow root?')" "no"; then
      fail "Root als Jellyfin-User wurde abgelehnt."
    fi
  fi
}

validate_paths() {
  is_safe_volume_path "$DOCKER_PROJECT_PATH" || fail "Unsicherer DOCKER_PROJECT_PATH: $DOCKER_PROJECT_PATH"
  is_safe_volume_path "$BACKUP_PATH" || fail "Unsicherer BACKUP_PATH: $BACKUP_PATH"
  safe_mkdir_parent_check "$DOCKER_PROJECT_PATH" || fail "Projekt-Pfad Parent ist nicht beschreibbar: $(dirname "$DOCKER_PROJECT_PATH")"
  safe_mkdir_parent_check "$BACKUP_PATH" || fail "Backup-Pfad Parent ist nicht beschreibbar: $(dirname "$BACKUP_PATH")"

  local src dst rw bad=0
  while IFS=$'\t' read -r src dst rw; do
    [ -n "$src" ] || continue
    if [ ! -e "$src" ]; then
      warn "Medienpfad existiert nicht: $src -> $dst"
      bad=1
    fi
  done < "$MEDIA_MOUNTS_FILE"
  [ "$bad" = "0" ] || fail "Mindestens ein Medienpfad existiert nicht."

  if [ -d "$DOCKER_PROJECT_PATH" ] && [ -n "$(find "$DOCKER_PROJECT_PATH" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]; then
    if is_true "$INTERACTIVE" && is_false "$ASSUME_YES"; then
      local alt="${DOCKER_PROJECT_PATH}-migrated"
      warn "$(tr_text "Der Projektordner ist nicht leer: $DOCKER_PROJECT_PATH" "The project folder is not empty: $DOCKER_PROJECT_PATH")"
      if ask_yes_no "$(tr_text "Stattdessen $alt verwenden?" "Use $alt instead?")" "yes"; then
        DOCKER_PROJECT_PATH="$alt"
      else
        fail "Projektordner ist nicht leer."
      fi
    else
      fail "Projektordner ist nicht leer: $DOCKER_PROJECT_PATH"
    fi
  fi
}

validate_port() {
  [ -n "$JELLYFIN_PORT_HTTP" ] || fail "JELLYFIN_PORT_HTTP ist leer."
  if ! echo "$JELLYFIN_PORT_HTTP" | grep -Eq '^[0-9]+$'; then
    fail "Ungültiger JELLYFIN_PORT_HTTP: $JELLYFIN_PORT_HTTP"
  fi

  # If the port is used only by old UGREEN Jellyfin and STOP_UGREEN_APP=true, this is expected.
  local port_users
  port_users="$(docker ps --format '{{.Names}}|{{.Ports}}' | grep -E "(^|[:,])${JELLYFIN_PORT_HTTP}->|0\.0\.0\.0:${JELLYFIN_PORT_HTTP}->|:${JELLYFIN_PORT_HTTP}->" || true)"
  if [ -n "$port_users" ]; then
    if printf '%s\n' "$port_users" | grep -q "^${UGREEN_CONTAINER}|"; then
      if is_true "$STOP_UGREEN_APP"; then
        log "$(tr_text "Port $JELLYFIN_PORT_HTTP ist aktuell durch die alte UGREEN-App belegt. Bei einer Migration wird die alte App vor dem Start des neuen Containers gestoppt." "Port $JELLYFIN_PORT_HTTP is currently used by the old UGREEN app. During migration, the old app will be stopped before starting the new container.")"
      else
        fail "Port $JELLYFIN_PORT_HTTP ist durch die UGREEN-App belegt, aber STOP_UGREEN_APP=false."
      fi
    else
      printf '%s\n' "$port_users"
      fail "Port $JELLYFIN_PORT_HTTP ist durch einen anderen Container belegt."
    fi
  fi
}

# -----------------------------
# Access and metadata checks
# -----------------------------
build_group_add_args() {
  local args=() g
  IFS=',' read -ra _groups <<< "${JELLYFIN_GROUPS:-}"
  for g in "${_groups[@]}"; do
    [ -n "$g" ] || continue
    [ "$g" = "$JELLYFIN_GID" ] && continue
    args+=(--group-add "$g")
  done
  printf '%s\n' "${args[@]}"
}

test_container_access_one() {
  local source="$1" mode="$2" docker_mode uidgid group_args=() status=0
  docker_mode="$mode"
  [ "$docker_mode" = "rw" ] || docker_mode="ro"

  mapfile -t group_args < <(build_group_add_args)

  docker run --rm \
    --entrypoint /bin/sh \
    --user "${JELLYFIN_UID}:${JELLYFIN_GID}" \
    "${group_args[@]}" \
    -v "${source}:/media:${docker_mode}" \
    "$UGREEN_IMAGE" \
    -c '
      set -u
      echo "id=$(id)"
      test -r /media || { echo "READ_DIR_FAILED"; exit 10; }
      test -x /media || { echo "ENTER_DIR_FAILED"; exit 11; }
      if [ "'"$docker_mode"'" = "rw" ]; then
        test -w /media || { echo "WRITE_DIR_FAILED"; exit 12; }
        touch /media/.jellyfin_migration_access_test && rm -f /media/.jellyfin_migration_access_test || { echo "CREATE_FILE_FAILED"; exit 13; }
      fi
      f="$(find /media \( -name "movie.nfo" -o -name "folder.jpg" -o -name "poster.*" -o -name "fanart.*" \) 2>/dev/null | head -n 1 || true)"
      if [ -n "$f" ]; then
        test -r "$f" || { echo "READ_METADATA_FAILED:$f"; exit 14; }
        if [ "'"$docker_mode"'" = "rw" ]; then
          test -w "$f" || { echo "WRITE_METADATA_FAILED:$f"; exit 15; }
        fi
      fi
      echo "ACCESS_OK"
    ' >> "$WORK_DIR/container-access-test.log" 2>&1 || status=$?

  return "$status"
}

test_all_media_access() {
  local src dst rw status any_failed=0
  : > "$FAILED_ACCESS_FILE"
  log "$(tr_text 'Prüfe Medienzugriff im Testcontainer ...' 'Checking media access in a test container ...')"
  while IFS=$'\t' read -r src dst rw; do
    [ -n "$src" ] || continue
    log "  $src -> $dst ($MEDIA_MOUNT_MODE)"
    if test_container_access_one "$src" "$MEDIA_MOUNT_MODE"; then
      log "    OK"
    else
      status=$?
      warn "$(tr_text "Zugriffstest fehlgeschlagen für $src -> $dst (rc=$status)" "Access test failed for $src -> $dst (rc=$status)")"
      printf '%s\t%s\t%s\n' "$src" "$dst" "$status" >> "$FAILED_ACCESS_FILE"
      any_failed=1
    fi
  done < "$MEDIA_MOUNTS_FILE"

  if [ "$any_failed" = "1" ]; then
    case "$(lower "$MIGRATION_MODE")" in
      safe_migration|safe-migration|full_migration|full-migration)
        fail "$(tr_text 'Mindestens ein Medienpfad konnte mit der geplanten UID/GID nicht genutzt werden.' 'At least one media path could not be used with the planned UID/GID.')"
        ;;
      *)
        warn "$(tr_text 'Mindestens ein Medienpfad konnte mit der geplanten UID/GID nicht genutzt werden. Im aktuellen Modus wird nur berichtet.' 'At least one media path could not be used with the planned UID/GID. In the current mode this is only reported.')"
        ;;
    esac
  fi
}

scan_root_metadata() {
  is_true "$ROOT_METADATA_SCAN" || return 0
  : > "$ROOT_METADATA_REPORT"
  local src dst rw count=0
  log "$(tr_text 'Suche nach root-eigenen Jellyfin/Kodi-Metadaten ...' 'Scanning for root-owned Jellyfin/Kodi metadata ...')"
  while IFS=$'\t' read -r src dst rw; do
    [ -n "$src" ] || continue
    {
      echo "### $src -> $dst"
      find "$src" -xdev \( \
        -iname "*.nfo" -o \
        -iname "poster.*" -o \
        -iname "fanart.*" -o \
        -iname "backdrop.*" -o \
        -iname "banner.*" -o \
        -iname "landscape.*" -o \
        -iname "logo.*" -o \
        -iname "clearlogo.*" -o \
        -iname "clearart.*" -o \
        -iname "folder.*" -o \
        -iname "season*.jpg" -o \
        -iname "season*.png" \
      \) -user root -printf '%u:%g %m %p\n' 2>/dev/null | head -n "$ROOT_METADATA_REPORT_LIMIT"
      echo
    } >> "$ROOT_METADATA_REPORT"
  done < "$MEDIA_MOUNTS_FILE"
  count="$(grep -E '^root:' "$ROOT_METADATA_REPORT" | wc -l | tr -d ' ')"
  if [ "$count" -gt 0 ]; then
    warn "$(tr_text "Root-eigene Metadaten gefunden: $count Treffer im Bericht." "Root-owned metadata found: $count entries in report.")"
    log "$(tr_text 'Da der Zugriffstest erfolgreich war, wird nichts automatisch geändert.' 'Since the access test was successful, nothing is changed automatically.')"
  else
    log "$(tr_text 'Keine root-eigenen Metadaten im Scan gefunden.' 'No root-owned metadata found in scan.')"
  fi
}

# Optional repair function, only for future use / explicit action after failed access.
repair_root_metadata_if_requested() {
  local count
  count="$(grep -E '^root:' "$ROOT_METADATA_REPORT" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ] || return 0

  case "$(lower "$ROOT_METADATA_ACTION")" in
    skip|ask|*)
      # v0.1 is report-only for metadata repair. The prompt will be enabled after more real-world tests.
      return 0
      ;;
    owner|owner-perms)
      warn "$(tr_text 'Metadaten-Reparatur v0.1 ist absichtlich noch nicht aktiv umgesetzt. Es wurde nichts geändert.' 'Metadata repair v0.1 is intentionally not active yet. Nothing was changed.')"
      warn "$(tr_text 'Der Bericht wurde gesichert; Reparatur folgt in einer späteren Version nach weiteren Tests.' 'The report was saved; repair will follow in a later version after more testing.')"
      ;;
  esac
}

# -----------------------------
# Backup and migration
# -----------------------------
tar_create() {
  local archive="$1" src="$2" base name
  base="$(dirname "$src")"
  name="$(basename "$src")"
  if tar --help 2>/dev/null | grep -q -- '--xattrs'; then
    tar --acls --xattrs -czf "$archive" -C "$base" "$name" 2>/dev/null || tar -czf "$archive" -C "$base" "$name"
  else
    tar -czf "$archive" -C "$base" "$name"
  fi
}

tar_create_cache() {
  local archive="$1" src="$2" base name
  base="$(dirname "$src")"
  name="$(basename "$src")"

  # /cache/transcodes contains temporary files that can change while Jellyfin is playing/transcoding.
  # The cache itself is not required for a safe migration, but backing it up without transcodes
  # avoids harmless tar warnings such as "file changed as we read it" during real-world tests.
  if [ -d "$src/transcodes" ]; then
    log "$(tr_text 'Überspringe temporären Cache-Unterordner im Backup: /cache/transcodes' 'Skipping temporary cache subfolder in backup: /cache/transcodes')"
  fi

  if tar --help 2>/dev/null | grep -q -- '--xattrs'; then
    tar --acls --xattrs       --exclude="$name/transcodes"       --exclude="$name/transcodes/*"       -czf "$archive" -C "$base" "$name" 2>/dev/null       || tar --exclude="$name/transcodes" --exclude="$name/transcodes/*" -czf "$archive" -C "$base" "$name"
  else
    tar --exclude="$name/transcodes" --exclude="$name/transcodes/*" -czf "$archive" -C "$base" "$name"
  fi
}

create_backup() {
  local ts
  ts="$(date '+%Y%m%d_%H%M%S')"
  BACKUP_RUN_DIR="${BACKUP_PATH}/${ts}"
  mkdir -p "$BACKUP_RUN_DIR" || fail "Backupordner konnte nicht erstellt werden: $BACKUP_RUN_DIR"

  log "$(tr_text "Erstelle Backup nach: $BACKUP_RUN_DIR" "Creating backup in: $BACKUP_RUN_DIR")"
  cp -a "$WORK_DIR/docker-inspect.json" "$BACKUP_RUN_DIR/docker-inspect-container.json" 2>/dev/null || true
  docker logs --tail=500 "$UGREEN_CONTAINER" > "$BACKUP_RUN_DIR/docker-logs-tail.txt" 2>&1 || true
  cp -a "$MEDIA_MOUNTS_FILE" "$BACKUP_RUN_DIR/media-mounts.tsv"
  cp -a "$DEVICES_FILE" "$BACKUP_RUN_DIR/devices.tsv"
  cp -a "$WORK_DIR/container-access-test.log" "$BACKUP_RUN_DIR/container-access-test.log" 2>/dev/null || true
  cp -a "$ROOT_METADATA_REPORT" "$BACKUP_RUN_DIR/root-owned-metadata-report.txt" 2>/dev/null || true
  cp -a "$LOG_FILE" "$BACKUP_RUN_DIR/migration-pre-backup.log" 2>/dev/null || true

  tar_create "$BACKUP_RUN_DIR/ugreen-config.tar.gz" "$UGREEN_CONFIG_SOURCE" || fail "Config-Backup fehlgeschlagen."
  if [ -n "$UGREEN_CACHE_SOURCE" ] && [ -d "$UGREEN_CACHE_SOURCE" ]; then
    tar_create_cache "$BACKUP_RUN_DIR/ugreen-cache.tar.gz" "$UGREEN_CACHE_SOURCE" || warn "Cache-Backup fehlgeschlagen."
  fi
  if [ -n "$UGREEN_PLUGIN_SOURCE" ] && [ -d "$UGREEN_PLUGIN_SOURCE" ]; then
    tar_create "$BACKUP_RUN_DIR/ugreen-plugins.tar.gz" "$UGREEN_PLUGIN_SOURCE" || fail "Plugin-Backup fehlgeschlagen."
  fi

  (cd "$BACKUP_RUN_DIR" && sha256sum * > checksums.sha256 2>/dev/null || true)
  cat > "$BACKUP_RUN_DIR/restore-info.txt" <<EOF_RESTORE
UGREEN NAS Jellyfin Migration Backup
Date: $(date)
Old container: $UGREEN_CONTAINER
Old image: $UGREEN_IMAGE
Old config: $UGREEN_CONFIG_SOURCE
Old cache: $UGREEN_CACHE_SOURCE
Old plugin source: $UGREEN_PLUGIN_SOURCE
Old restart policy before migration: ${UGREEN_OLD_RESTART_POLICY:-unknown}
New project path planned: $DOCKER_PROJECT_PATH
EOF_RESTORE
  BACKUP_SUCCESS="true"
}

prepare_project() {
  mkdir -p "$DOCKER_PROJECT_PATH/config" "$DOCKER_PROJECT_PATH/cache" "$DOCKER_PROJECT_PATH/logs" || fail "Projektordner konnte nicht erstellt werden."

  log "$(tr_text 'Kopiere Jellyfin-Konfiguration ...' 'Copying Jellyfin configuration ...')"
  cp -a "$UGREEN_CONFIG_SOURCE/." "$DOCKER_PROJECT_PATH/config/" || fail "Kopieren von /config fehlgeschlagen."

  if [ -n "$UGREEN_PLUGIN_SOURCE" ] && [ -d "$UGREEN_PLUGIN_SOURCE" ]; then
    log "$(tr_text 'Kopiere separaten UGREEN-Pluginordner nach /config/plugins ...' 'Copying separate UGREEN plugin folder into /config/plugins ...')"
    mkdir -p "$DOCKER_PROJECT_PATH/config/plugins"
    cp -a "$UGREEN_PLUGIN_SOURCE/." "$DOCKER_PROJECT_PATH/config/plugins/" || fail "Plugin-Kopie fehlgeschlagen."
  fi

  if is_true "$CACHE_MIGRATE" && [ -n "$UGREEN_CACHE_SOURCE" ] && [ -d "$UGREEN_CACHE_SOURCE" ]; then
    log "$(tr_text 'Kopiere Cache, weil CACHE_MIGRATE=true ...' 'Copying cache because CACHE_MIGRATE=true ...')"
    cp -a "$UGREEN_CACHE_SOURCE/." "$DOCKER_PROJECT_PATH/cache/" || warn "Cache-Kopie fehlgeschlagen. Neuer leerer Cache wird verwendet."
  fi

  chown -R "${JELLYFIN_UID}:${JELLYFIN_GID}" "$DOCKER_PROJECT_PATH/config" "$DOCKER_PROJECT_PATH/cache" || fail "chown auf Projektordner fehlgeschlagen."
  chmod -R u+rwX,g+rwX,o-rwx "$DOCKER_PROJECT_PATH/config" "$DOCKER_PROJECT_PATH/cache" || true
}

generate_env_file() {
  cat > "$DOCKER_PROJECT_PATH/.env" <<EOF_ENV
# Generated by UGREEN NAS Jellyfin Migration v${SCRIPT_VERSION}
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
TZ=${TZ}
JELLYFIN_IMAGE=${JELLYFIN_IMAGE}
JELLYFIN_CONTAINER_NAME=${JELLYFIN_CONTAINER_NAME}
JELLYFIN_PORT_HTTP=${JELLYFIN_PORT_HTTP}
JELLYFIN_UID=${JELLYFIN_UID}
JELLYFIN_GID=${JELLYFIN_GID}
EOF_ENV
}

generate_compose() {
  local compose="$DOCKER_PROJECT_PATH/${COMPOSE_FILE_NAME}" src dst rw esc_src esc_dst mode hp cp perm esc_hp esc_cp g
  generate_env_file
  cat > "$compose" <<'EOF_COMPOSE'
services:
  jellyfin:
    image: "${JELLYFIN_IMAGE}"
    container_name: "${JELLYFIN_CONTAINER_NAME}"
    hostname: jellyfin
    restart: unless-stopped
    user: "${JELLYFIN_UID}:${JELLYFIN_GID}"
    ports:
      - "${JELLYFIN_PORT_HTTP}:8096"
    environment:
      - TZ=${TZ}
    volumes:
      - "./config:/config"
      - "./cache:/cache"
EOF_COMPOSE

  while IFS=$'\t' read -r src dst rw; do
    [ -n "$src" ] || continue
    mode="$MEDIA_MOUNT_MODE"
    [ "$mode" = "rw" ] || mode="ro"
    esc_src="$(shell_escape_double_quotes "$src")"
    esc_dst="$(shell_escape_double_quotes "$dst")"
    echo "      - \"${esc_src}:${esc_dst}:${mode}\"" >> "$compose"
  done < "$MEDIA_MOUNTS_FILE"

  if [ -s "$DEVICES_FILE" ] && { [ "$ENABLE_HARDWARE_ACCEL" = "auto" ] || is_true "$ENABLE_HARDWARE_ACCEL"; }; then
    echo "    devices:" >> "$compose"
    while IFS=$'\t' read -r hp cp perm; do
      [ -n "$hp" ] || continue
      if [ -e "$hp" ]; then
        esc_hp="$(shell_escape_double_quotes "$hp")"
        esc_cp="$(shell_escape_double_quotes "$cp")"
        echo "      - \"${esc_hp}:${esc_cp}\"" >> "$compose"
      elif is_true "$ENABLE_HARDWARE_ACCEL"; then
        fail "Hardwarebeschleunigung wurde erzwungen, aber Device fehlt: $hp"
      fi
    done < "$DEVICES_FILE"
  fi

  if [ -n "${JELLYFIN_GROUPS:-}" ]; then
    echo "    group_add:" >> "$compose"
    IFS=',' read -ra _groups <<< "$JELLYFIN_GROUPS"
    for g in "${_groups[@]}"; do
      [ -n "$g" ] || continue
      [ "$g" = "$JELLYFIN_GID" ] && continue
      echo "      - \"$g\"" >> "$compose"
    done
  fi

  cat >> "$compose" <<'EOF_COMPOSE2'
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF_COMPOSE2
}


register_ugos_project_if_requested() {
  UGOS_DB_STATUS="$(tr_text 'nicht ausgeführt' 'not executed')"
  case "$(lower "${REGISTER_UGOS_PROJECT:-ask}")" in
    false|0|no|nein|n|off)
      UGOS_DB_STATUS="$(tr_text 'deaktiviert' 'disabled')"
      return 0
      ;;
    true|1|yes|ja|j|y)
      ;;
    ask|*)
      if is_false "$INTERACTIVE" || is_true "$ASSUME_YES"; then
        UGOS_DB_STATUS="$(tr_text 'übersprungen, ask im nicht-interaktiven Modus' 'skipped, ask in non-interactive mode')"
        return 0
      fi
      if ! ask_yes_no "$(tr_text 'Neues Projekt in der UGOS-Docker-App registrieren?' 'Register the new project in the UGOS Docker app?')" "yes"; then
        UGOS_DB_STATUS="$(tr_text 'vom Benutzer übersprungen' 'skipped by user')"
        return 0
      fi
      ;;
  esac

  if [ -z "${UGOS_DOCKER_DB:-}" ] || [ ! -f "$UGOS_DOCKER_DB" ]; then
    UGOS_DB_STATUS="$(tr_text 'übersprungen, keine UGOS-Docker-DB gefunden' 'skipped, no UGOS Docker DB found')"
    warn "$UGOS_DB_STATUS"
    return 0
  fi

  local compose_path db_bak side_bak
  compose_path="${DOCKER_PROJECT_PATH}/${COMPOSE_FILE_NAME}"
  [ -f "$compose_path" ] || { UGOS_DB_STATUS="$(tr_text 'übersprungen, Compose-Datei fehlt' 'skipped, compose file missing')"; warn "$UGOS_DB_STATUS"; return 0; }

  db_bak="${BACKUP_RUN_DIR}/ugos-docker-db-before-migration.db"
  side_bak="${UGOS_DOCKER_DB}.jellyfin-migration-backup-$(date '+%Y%m%d_%H%M%S')"
  cp -a "$UGOS_DOCKER_DB" "$db_bak" 2>/dev/null || { UGOS_DB_STATUS="$(tr_text 'fehlgeschlagen, DB-Backup konnte nicht erstellt werden' 'failed, could not create DB backup')"; warn "$UGOS_DB_STATUS"; return 0; }
  cp -a "$UGOS_DOCKER_DB" "$side_bak" 2>/dev/null || true
  UGOS_DB_BACKUP="$db_bak"

  log "$(tr_text "UGOS-Docker-DB Sicherheitskopie: $db_bak" "UGOS Docker DB safety backup: $db_bak")"

  if python3 - "$UGOS_DOCKER_DB" "$UGOS_PROJECT_NAME" "$compose_path" <<'PYUGOSDB' >> "$LOG_FILE" 2>&1
import datetime, sqlite3, sys, os

db, name, path = sys.argv[1:4]
now = datetime.datetime.now().astimezone().isoformat(sep=" ")
conn = sqlite3.connect(db)
cur = conn.cursor()
tables = [r[0] for r in cur.execute("select name from sqlite_master where type='table'")]
if "compose" not in tables:
    raise SystemExit("compose table not found")
cols = [r[1] for r in cur.execute("pragma table_info(compose)")]
# Known UGOS schema from dockersich restore: created_at, updated_at, name, state, path, content, app_id, container_num.
exists = cur.execute("select id from compose where name=?", (name,)).fetchone()
values = {
    "created_at": now,
    "updated_at": now,
    "name": name,
    "state": 1,
    "path": path,
    "content": "",
    "app_id": None,
    "container_num": 1,
}
if exists:
    set_cols = [c for c in ("updated_at","state","path","content","app_id","container_num") if c in cols]
    sql = "update compose set " + ", ".join(f"{c}=?" for c in set_cols) + " where name=?"
    cur.execute(sql, [values[c] for c in set_cols] + [name])
else:
    insert_cols = [c for c in ("created_at","updated_at","name","state","path","content","app_id","container_num") if c in cols]
    sql = "insert into compose (" + ",".join(insert_cols) + ") values (" + ",".join("?" for _ in insert_cols) + ")"
    cur.execute(sql, [values[c] for c in insert_cols])
conn.commit()
conn.close()
print(f"registered {name} -> {path}")
PYUGOSDB
  then
    UGOS_DB_STATUS="$(tr_text 'erfolgreich registriert' 'registered successfully'): ${UGOS_PROJECT_NAME}"
    log "[UGOS-DB] $UGOS_DB_STATUS"
  else
    UGOS_DB_STATUS="$(tr_text 'Registrierung fehlgeschlagen, Migration läuft ohne UGOS-DB-Eintrag weiter' 'registration failed, migration continues without UGOS DB entry')"
    warn "[UGOS-DB] $UGOS_DB_STATUS"
    warn "$(tr_text "DB-Backup liegt hier: $db_bak" "DB backup is here: $db_bak")"
  fi
}

list_running_container_names() {
  docker ps --format '{{.Names}}' 2>/dev/null | sed '/^$/d' || true
}

verify_ugos_project_registration() {
  case "$(lower "${REGISTER_UGOS_PROJECT:-ask}")" in
    false|0|no|nein|n|off) return 0 ;;
  esac
  [ -n "${UGOS_DOCKER_DB:-}" ] && [ -f "$UGOS_DOCKER_DB" ] || return 0

  if python3 - "$UGOS_DOCKER_DB" "$UGOS_PROJECT_NAME" <<'PYVERIFY' >> "$LOG_FILE" 2>&1
import sqlite3, sys
db, name = sys.argv[1:3]
conn = sqlite3.connect(db)
cur = conn.cursor()
row = cur.execute("select name,path,container_num,app_id from compose where name=?", (name,)).fetchone()
conn.close()
if not row:
    raise SystemExit(2)
print("verified", row)
PYVERIFY
  then
    log "$(tr_text "[UGOS-DB] Eintrag nach Docker-App-Refresh bestätigt: $UGOS_PROJECT_NAME" "[UGOS DB] Entry confirmed after Docker app refresh: $UGOS_PROJECT_NAME")"
  else
    warn "$(tr_text "[UGOS-DB] Eintrag nach Docker-App-Refresh nicht gefunden: $UGOS_PROJECT_NAME" "[UGOS DB] Entry not found after Docker app refresh: $UGOS_PROJECT_NAME")"
    UGOS_DB_STATUS="${UGOS_DB_STATUS}; $(tr_text 'nach Refresh nicht bestätigt' 'not confirmed after refresh')"
  fi
}

restore_running_containers_after_refresh() {
  local before_file="$1" name running_now exists
  [ -f "$before_file" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    exists="$(docker inspect -f '{{.Name}}' "$name" 2>/dev/null || true)"
    [ -n "$exists" ] || continue
    running_now="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)"
    if [ "$running_now" != "true" ]; then
      log "$(tr_text "Container war vor dem Docker-App-Refresh aktiv und wird erneut gestartet: $name" "Container was running before Docker app refresh and is started again: $name")"
      docker start "$name" >> "$LOG_FILE" 2>&1 || true
    fi
  done < "$before_file"
}

refresh_ugos_app_if_requested() {
  UGOS_REFRESH_STATUS="$(tr_text 'nicht ausgeführt' 'not executed')"
  case "$(lower "${REFRESH_UGOS_DOCKER_APP:-ask}")" in
    false|0|no|nein|n|off)
      UGOS_REFRESH_STATUS="$(tr_text 'deaktiviert' 'disabled')"
      return 0
      ;;
    true|1|yes|ja|j|y)
      ;;
    ask|*)
      if is_false "$INTERACTIVE" || is_true "$ASSUME_YES"; then
        UGOS_REFRESH_STATUS="$(tr_text 'übersprungen, ask im nicht-interaktiven Modus' 'skipped, ask in non-interactive mode')"
        return 0
      fi
      if ! ask_yes_no "$(tr_text 'UGOS-Docker-App nach der Projektregistrierung aktualisieren?' 'Refresh the UGOS Docker app after project registration?')" "yes"; then
        UGOS_REFRESH_STATUS="$(tr_text 'vom Benutzer übersprungen' 'skipped by user')"
        return 0
      fi
      ;;
  esac

  local service_name="$UGOS_DOCKER_SERVICE" unit="${UGOS_DOCKER_SERVICE}.service" before_file="${WORK_DIR}/docker-running-before-ugos-refresh.txt"
  list_running_container_names > "$before_file" || true

  if command -v systemctl >/dev/null 2>&1 && { systemctl cat "$unit" >/dev/null 2>&1 || systemctl status "$unit" >/dev/null 2>&1; }; then
    log "$(tr_text "Starte UGOS-Docker-Dienst neu: $unit" "Restarting UGOS Docker service: $unit")"
    if systemctl restart "$unit" >> "$LOG_FILE" 2>&1; then
      UGOS_REFRESH_STATUS="$(tr_text 'erfolgreich per systemctl' 'successful via systemctl'): $unit"
      restore_running_containers_after_refresh "$before_file"
    else
      UGOS_REFRESH_STATUS="$(tr_text 'fehlgeschlagen per systemctl' 'failed via systemctl'): $unit"
      warn "$UGOS_REFRESH_STATUS"
    fi
    return 0
  fi

  if command -v service >/dev/null 2>&1 && service "$service_name" status >/dev/null 2>&1; then
    log "$(tr_text "Starte UGOS-Docker-Dienst neu: $service_name" "Restarting UGOS Docker service: $service_name")"
    if service "$service_name" restart >> "$LOG_FILE" 2>&1; then
      UGOS_REFRESH_STATUS="$(tr_text 'erfolgreich per service' 'successful via service'): $service_name"
      restore_running_containers_after_refresh "$before_file"
    else
      UGOS_REFRESH_STATUS="$(tr_text 'fehlgeschlagen per service' 'failed via service'): $service_name"
      warn "$UGOS_REFRESH_STATUS"
    fi
    return 0
  fi

  UGOS_REFRESH_STATUS="$(tr_text 'übersprungen, Dienst nicht gefunden' 'skipped, service not found'): $service_name"
  warn "$UGOS_REFRESH_STATUS"
}

post_start_checks() {
  [ "$NEW_CONTAINER_STARTED" = "true" ] || return 0
  local ok="true" src dst rw log_hits runtime_log="$WORK_DIR/post-start-runtime-access.log"
  : > "$runtime_log"

  log "$(tr_text 'Führe Post-Migration-Zugriffstest im laufenden Container aus ...' 'Running post-migration access test in the running container ...')"
  for dst in /config /cache; do
    if docker exec "$JELLYFIN_CONTAINER_NAME" sh -c 'p="$1"; test -r "$p" && test -x "$p" && test -w "$p" && touch "$p/.jellyfin_post_start_test" && rm -f "$p/.jellyfin_post_start_test"' sh "$dst" >> "$runtime_log" 2>&1; then
      log "  $dst OK"
    else
      warn "$(tr_text "Post-Start Zugriff fehlgeschlagen: $dst" "Post-start access failed: $dst")"
      ok="false"
    fi
  done

  while IFS=$'\t' read -r src dst rw; do
    [ -n "$dst" ] || continue
    if docker exec "$JELLYFIN_CONTAINER_NAME" sh -c 'p="$1"; test -r "$p" && test -x "$p" && test -w "$p" && touch "$p/.jellyfin_post_start_test" && rm -f "$p/.jellyfin_post_start_test"' sh "$dst" >> "$runtime_log" 2>&1; then
      log "  $dst OK"
    else
      warn "$(tr_text "Post-Start Zugriff fehlgeschlagen: $dst" "Post-start access failed: $dst")"
      ok="false"
    fi
  done < "$MEDIA_MOUNTS_FILE"

  cp -a "$runtime_log" "$BACKUP_RUN_DIR/post-start-runtime-access.log" 2>/dev/null || true

  log_hits="$(docker logs --tail=250 "$JELLYFIN_CONTAINER_NAME" 2>&1 | grep -iE 'permission|denied|unauthorized|failed|error' || true)"
  if [ -n "$log_hits" ]; then
    printf '%s\n' "$log_hits" > "$BACKUP_RUN_DIR/post-start-log-warnings.txt" 2>/dev/null || true
    if printf '%s\n' "$log_hits" | grep -qi 'Directory watcher'; then
      if [ "$ok" = "true" ]; then
        POST_START_WARNING="true"
        warn "$(tr_text 'Jellyfin meldet einen Directory-Watcher-Hinweis, der echte Zugriffstest war aber erfolgreich.' 'Jellyfin reports a directory watcher warning, but the real access test was successful.')"
        warn "$(tr_text 'Das betrifft wahrscheinlich nur die Echtzeitüberwachung. Normale Scans/Wiedergabe bitte trotzdem testen.' 'This probably only affects realtime monitoring. Please still test regular scans/playback.')"
      else
        warn "$(tr_text 'Jellyfin meldet Berechtigungsfehler und der echte Zugriffstest war nicht vollständig erfolgreich.' 'Jellyfin reports permission errors and the real access test was not fully successful.')"
      fi
    else
      warn "$(tr_text 'Jellyfin-Logs enthalten Warn-/Fehlermeldungen. Details wurden im Backup gespeichert.' 'Jellyfin logs contain warning/error messages. Details were saved in the backup.')"
    fi
  fi
}

stop_old_app_if_needed() {
  if is_true "$STOP_UGREEN_APP"; then
    UGREEN_OLD_RESTART_POLICY="$(docker inspect "$UGREEN_CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || true)"
    if [ -n "$UGREEN_OLD_RESTART_POLICY" ] && [ "$UGREEN_OLD_RESTART_POLICY" != "no" ] && [ "$UGREEN_OLD_RESTART_POLICY" != "" ]; then
      log "$(tr_text "Setze Restart-Policy der alten UGREEN-App vorübergehend auf no: $UGREEN_CONTAINER (vorher: $UGREEN_OLD_RESTART_POLICY)" "Setting old UGREEN app restart policy temporarily to no: $UGREEN_CONTAINER (previously: $UGREEN_OLD_RESTART_POLICY)")"
      docker update --restart=no "$UGREEN_CONTAINER" >> "$LOG_FILE" 2>&1 || warn "$(tr_text 'Restart-Policy der alten UGREEN-App konnte nicht geändert werden.' 'Could not change restart policy of the old UGREEN app.')"
    fi
    log "$(tr_text "Stoppe alte UGREEN-Jellyfin-App: $UGREEN_CONTAINER" "Stopping old UGREEN Jellyfin app: $UGREEN_CONTAINER")"
    docker stop "$UGREEN_CONTAINER" || fail "Alte UGREEN-App konnte nicht gestoppt werden."
    verify_old_app_stopped
  else
    fail "STOP_UGREEN_APP=false ist in v0.1 für Migration mit gleichem Port nicht erlaubt."
  fi
}

verify_old_app_stopped() {
  local running=""
  [ -n "${UGREEN_CONTAINER:-}" ] || return 0
  running="$(docker inspect "$UGREEN_CONTAINER" --format '{{.State.Running}}' 2>/dev/null || true)"
  if [ "$running" = "true" ]; then
    warn "$(tr_text "Die alte UGREEN-Jellyfin-App läuft wieder und wird erneut gestoppt: $UGREEN_CONTAINER" "The old UGREEN Jellyfin app is running again and will be stopped again: $UGREEN_CONTAINER")"
    docker stop "$UGREEN_CONTAINER" >> "$LOG_FILE" 2>&1 || warn "$(tr_text 'Alte UGREEN-App konnte beim Nachcheck nicht gestoppt werden.' 'Old UGREEN app could not be stopped during re-check.')"
  fi
  running="$(docker inspect "$UGREEN_CONTAINER" --format '{{.State.Running}}' 2>/dev/null || true)"
  if [ "$running" = "true" ]; then
    OLD_APP_STATUS="$(tr_text 'läuft noch' 'still running')"
    warn "$(tr_text 'Alte UGREEN-App läuft noch. Bitte nicht beide Jellyfin-Instanzen parallel verwenden.' 'Old UGREEN app is still running. Please do not use both Jellyfin instances in parallel.')"
  else
    OLD_APP_STATUS="$(tr_text 'gestoppt' 'stopped')"
    log "$(tr_text "Alte UGREEN-Jellyfin-App ist gestoppt: $UGREEN_CONTAINER" "Old UGREEN Jellyfin app is stopped: $UGREEN_CONTAINER")"
  fi
}

start_new_container() {
  log "$(tr_text 'Starte neuen Jellyfin-Container ...' 'Starting new Jellyfin container ...')"
  (cd "$DOCKER_PROJECT_PATH" && "${COMPOSE_CMD[@]}" -p "$COMPOSE_PROJECT_NAME" -f "$DOCKER_PROJECT_PATH/${COMPOSE_FILE_NAME}" up -d) || fail "docker compose up -d fehlgeschlagen."
  NEW_CONTAINER_STARTED="true"
  sleep 5
  if docker ps --format '{{.Names}}' | grep -qx "$JELLYFIN_CONTAINER_NAME"; then
    log "$(tr_text 'Neuer Jellyfin-Container läuft.' 'New Jellyfin container is running.')"
  else
    warn "$(tr_text 'Neuer Jellyfin-Container scheint nicht zu laufen. Prüfe docker logs.' 'New Jellyfin container does not seem to be running. Check docker logs.')"
    docker logs --tail=100 "$JELLYFIN_CONTAINER_NAME" 2>&1 | tee -a "$LOG_FILE" || true
    fail "Neuer Jellyfin-Container läuft nicht."
  fi
}

remove_old_app_if_allowed() {
  is_true "$REMOVE_UGREEN_APP" || return 0
  is_true "$I_UNDERSTAND_UGREEN_APP_REMOVAL" || fail "REMOVE_UGREEN_APP=true, aber I_UNDERSTAND_UGREEN_APP_REMOVAL=false."
  [ "$BACKUP_SUCCESS" = "true" ] || fail "Backup nicht erfolgreich; Entfernung wird verweigert."
  [ "$NEW_CONTAINER_STARTED" = "true" ] || fail "Neuer Container läuft nicht; Entfernung wird verweigert."

  warn "$(tr_text 'FULL_MIGRATION entfernt nur den alten Docker-Container, nicht die UGREEN-App über das App Center.' 'FULL_MIGRATION only removes the old Docker container, not the UGREEN app via App Center.')"
  if ask_yes_no "$(tr_text "Alten Container $UGREEN_CONTAINER wirklich entfernen?" "Really remove old container $UGREEN_CONTAINER?")" "no"; then
    docker rm "$UGREEN_CONTAINER" || fail "Alter Container konnte nicht entfernt werden."
  fi
}

copy_reports_to_backup() {
  [ -n "${BACKUP_RUN_DIR:-}" ] && [ -d "$BACKUP_RUN_DIR" ] || return 0
  cp -a "$LOG_FILE" "$BACKUP_RUN_DIR/migration.log" 2>/dev/null || true
  cp -a "$ROOT_METADATA_REPORT" "$BACKUP_RUN_DIR/root-owned-metadata-report.txt" 2>/dev/null || true
  cp -a "$WORK_DIR/container-access-test.log" "$BACKUP_RUN_DIR/container-access-test.log" 2>/dev/null || true
  cp -a "$DOCKER_PROJECT_PATH/${COMPOSE_FILE_NAME}" "$BACKUP_RUN_DIR/docker-compose.generated.yaml" 2>/dev/null || true
}

show_summary() {
  echo
  echo "============================================================"
  echo "UGREEN NAS Jellyfin Migration v${SCRIPT_VERSION}"
  echo "============================================================"
  echo "$(tr_text 'Modus' 'Mode'):                 $MIGRATION_MODE"
  echo "$(tr_text 'NAS-Modell' 'NAS model'):            $NAS_MODEL"
  echo "$(tr_text 'Architektur' 'Architecture'):         $ARCH"
  echo "$(tr_text 'Alter Container' 'Old container'):        $UGREEN_CONTAINER"
  echo "$(tr_text 'Altes Image' 'Old image'):            $UGREEN_IMAGE"
  echo "$(tr_text 'UGREEN Config' 'UGREEN config'):       $UGREEN_CONFIG_SOURCE"
  echo "$(tr_text 'UGREEN Cache' 'UGREEN cache'):        $UGREEN_CACHE_SOURCE"
  echo "$(tr_text 'UGREEN Plugins' 'UGREEN plugins'):     ${UGREEN_PLUGIN_SOURCE:-$(tr_text 'kein separater Mount' 'no separate mount')}"
  echo "$(tr_text 'Alter Port' 'Old port'):             ${UGREEN_HOST_PORT:-?} -> ${UGREEN_CONTAINER_PORT:-8096}"
  echo "$(tr_text 'Neuer Port' 'New port'):             $JELLYFIN_PORT_HTTP -> 8096"
  echo "$(tr_text 'Docker-Basis' 'Docker base'):          $DOCKER_BASE_DIR"
  echo "$(tr_text 'Neues Projekt' 'New project'):         $DOCKER_PROJECT_PATH"
  echo "$(tr_text 'Compose-Projekt' 'Compose project'):      $COMPOSE_PROJECT_NAME"
  echo "$(tr_text 'Containername' 'Container name'):       $JELLYFIN_CONTAINER_NAME"
  echo "$(tr_text 'UGOS-Projekt' 'UGOS project'):          $UGOS_PROJECT_NAME"
  echo "$(tr_text 'UGOS-Docker-DB' 'UGOS Docker DB'):        ${UGOS_DOCKER_DB:-$(tr_text 'nicht gefunden' 'not found')}"
  echo "$(tr_text 'Backup-Pfad' 'Backup path'):          $BACKUP_PATH"
  echo "$(tr_text 'Jellyfin UID/GID' 'Jellyfin UID/GID'):   ${JELLYFIN_UID}:${JELLYFIN_GID}"
  echo "$(tr_text 'Gruppen' 'Groups'):              ${JELLYFIN_GROUPS:-}"
  echo "$(tr_text 'Medien-Mounts' 'Media mounts'):"
  awk -F'\t' '{printf "  - %s -> %s (%s)\n", $1, $2, "'"$MEDIA_MOUNT_MODE"'"}' "$MEDIA_MOUNTS_FILE"
  echo "============================================================"
  echo
}

execute_mode() {
  case "$(lower "$MIGRATION_MODE")" in
    check_only|check-only)
      log "CHECK_ONLY: $(tr_text 'Es wurde nichts geändert.' 'Nothing was changed.')"
      ;;
    backup_only|backup-only)
      create_backup
      copy_reports_to_backup
      log "$(tr_text 'Backup abgeschlossen. Alte UGREEN-App läuft weiter.' 'Backup completed. Old UGREEN app keeps running.')"
      ;;
    safe_migration|safe-migration)
      create_backup
      prepare_project
      generate_compose
      stop_old_app_if_needed
      start_new_container
      register_ugos_project_if_requested
      refresh_ugos_app_if_requested
      verify_old_app_stopped
      verify_ugos_project_registration
      post_start_checks
      copy_reports_to_backup
      ;;
    full_migration|full-migration)
      create_backup
      prepare_project
      generate_compose
      stop_old_app_if_needed
      start_new_container
      register_ugos_project_if_requested
      refresh_ugos_app_if_requested
      verify_old_app_stopped
      verify_ugos_project_registration
      post_start_checks
      remove_old_app_if_allowed
      copy_reports_to_backup
      ;;
    *) fail "Unbekannter MIGRATION_MODE: $MIGRATION_MODE" ;;
  esac
}

final_message() {
  echo
  echo "============================================================"
  if [ "$NEW_CONTAINER_STARTED" = "true" ]; then
    echo "$(tr_text 'Migration erfolgreich abgeschlossen.' 'Migration completed successfully.')"
    echo
    echo "$(tr_text 'Die alte UGREEN-Jellyfin-App wurde gestoppt, aber nicht gelöscht.' 'The old UGREEN Jellyfin app was stopped, but not removed.')"
    echo "$(tr_text 'Das ist notwendig, damit der neue Jellyfin-Container denselben Port verwenden kann.' 'This is required so the new Jellyfin container can use the same port.')"
    echo
    if [ -n "${NAS_ACCESS_IP:-}" ]; then
      echo "URL: http://${NAS_ACCESS_IP}:${JELLYFIN_PORT_HTTP}"
    else
      echo "URL: http://<NAS-IP>:${JELLYFIN_PORT_HTTP}"
    fi
    echo "$(tr_text 'Neues Docker-Projekt' 'New Docker project'): $DOCKER_PROJECT_PATH"
    echo "$(tr_text 'Compose-Projekt' 'Compose project'): $COMPOSE_PROJECT_NAME"
    echo "$(tr_text 'Container' 'Container'): $JELLYFIN_CONTAINER_NAME"
    echo "$(tr_text 'UGOS-DB-Status' 'UGOS DB status'): $UGOS_DB_STATUS"
    echo "$(tr_text 'Docker-App-Refresh' 'Docker app refresh'): $UGOS_REFRESH_STATUS"
    echo "$(tr_text 'Alte UGREEN-App' 'Old UGREEN app'): ${OLD_APP_STATUS:-unknown}"
    if [ "$POST_START_WARNING" = "true" ]; then
      echo "$(tr_text 'Hinweis: Directory-Watcher-Warnung erkannt; echter Zugriffstest war erfolgreich.' 'Note: directory watcher warning detected; real access test was successful.')"
    fi
    echo
    echo "$(tr_text 'Nächste Schritte:' 'Next steps:')"
    echo "$(tr_text '1. Jellyfin im Browser öffnen und Benutzer, Bibliotheken, Medienpfade, Plugins und Wiedergabe/Transcoding prüfen.' '1. Open Jellyfin in the browser and verify users, libraries, media paths, plugins and playback/transcoding.')"
    echo "$(tr_text '2. Falls Jellyfin Plugin-Aktualisierungen meldet, Jellyfin danach einmal neu starten.' '2. If Jellyfin reports plugin updates, restart Jellyfin once afterwards.')"
    echo "$(tr_text '3. Wenn alles funktioniert, die alte UGREEN-Jellyfin-App im UGREEN App Center deinstallieren.' '3. If everything works, uninstall the old UGREEN Jellyfin app in the UGREEN App Center.')"
    echo "$(tr_text '   Wichtig: Diese Migration löscht die alte UGREEN-App bewusst nicht automatisch.' '   Important: this migration intentionally does not remove the old UGREEN app automatically.')"
    echo "$(tr_text '   Den neuen Docker-Projektordner nicht löschen: ' '   Do not delete the new Docker project folder: ')$DOCKER_PROJECT_PATH"
  else
    echo "$(tr_text 'Lauf abgeschlossen.' 'Run completed.')"
  fi
  [ -n "${BACKUP_RUN_DIR:-}" ] && echo "Backup: $BACKUP_RUN_DIR"
  echo "Log: ${BACKUP_RUN_DIR:-$WORK_DIR}/migration.log"
  echo "============================================================"
  echo
}

main() {
  require_root
  require_commands
  setup_workdir
  detect_system
  detect_access_ip
  detect_ugreen_jellyfin_container
  inspect_ugreen_container
  detect_docker_base_dir
  detect_ugos_docker_db
  resolve_auto_values
  resolve_uid_gid
  maybe_cleanup_legacy_test_migration
  maybe_cleanup_existing_target_migration
  validate_paths
  validate_port
  test_all_media_access
  scan_root_metadata
  show_summary

  if [ "$(lower "$MIGRATION_MODE")" != "check_only" ] && [ "$(lower "$MIGRATION_MODE")" != "check-only" ]; then
    if ! ask_yes_no "$(tr_text 'Mit dieser Planung fortfahren?' 'Continue with this plan?')" "yes"; then
      fail "$(tr_text 'Abgebrochen durch Benutzer.' 'Cancelled by user.')"
    fi
  fi

  repair_root_metadata_if_requested
  execute_mode
  final_message
}

main
