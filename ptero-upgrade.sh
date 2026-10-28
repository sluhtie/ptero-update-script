#!/usr/bin/env bash
#
# ptero-upgrade.sh - Upgrade a native Pterodactyl Panel 1.x installation to 2.0
#
# Follows the official guide:
#   https://docs.pterodactyl.io/v2/upgrading/upgrading-from-v1
#
# 2.0 is installed in a new directory next to 1.x, the database is migrated,
# then the directories are swapped. The 1.x files are kept so you can roll back
# with:  ./ptero-upgrade.sh --rollback <backup-dir>
#
# This is a community script and is not affiliated with the Pterodactyl project.
# Use at your own risk and keep your backups.
#
# SPDX-License-Identifier: MIT

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
GITHUB_REPO="pterodactyl/panel"
FALLBACK_RELEASE="v2.0.0-beta.2"
DOCS_URL="https://docs.pterodactyl.io/v2/upgrading/upgrading-from-v1"

# ----------------------------------------------------------------------------
# Defaults (override with flags, see --help)
# ----------------------------------------------------------------------------
PANEL_DIR="/var/www/pterodactyl"
TARGET_RELEASE=""
BACKUP_ROOT="/root"
WEBSERVER="auto"
WEB_USER=""
QUEUE_SERVICE="pteroq"
TARGET_PHP="8.3"
ASSUME_YES=0
SEED_EGGS="ask"
CHECK_ONLY=0
MODE="upgrade"
ROLLBACK_DIR=""
LOG_FILE=""

# ----------------------------------------------------------------------------
# Runtime state
# ----------------------------------------------------------------------------
STAGE="init"
NEW_DIR=""
OLD_DIR=""
BACKUP_DIR=""
WORK_DIR=""
PHP_VER=""
FPM_SERVICE=""
WEB_GROUP=""
WEB_CONF=""
CURRENT_VERSION=""
DB_NAME=""
MYSQL_OPTS=()
CREATED_NEW_DIR=0
RECOVERED=0
OS_ID=""
DOWNLOAD_URL=""
NGINX_PHP_SOCK_VER=""
MISSING_EXT=()
WARNINGS=()

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
    C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

info()    { printf '%s[INFO]%s  %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()      { printf '%s[ OK ]%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s[WARN]%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; WARNINGS+=("$*"); }
error()   { printf '%s[FAIL]%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()     { error "$*"; exit 1; }
section() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# Prompts read from the terminal so the script also works when piped into bash.
tty_available() { [[ -r /dev/tty && -w /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }

# confirm "Question" [default y|n]
confirm() {
    local question="$1" default="${2:-n}" answer hint
    if [[ $ASSUME_YES -eq 1 ]]; then
        info "$question -> yes (--yes)"
        return 0
    fi
    if ! tty_available; then
        die "No terminal available to ask: '$question'. Re-run with --yes to accept all prompts."
    fi
    [[ $default == y ]] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        printf '%s?%s %s %s ' "$C_YELLOW" "$C_RESET" "$question" "$hint" >/dev/tty
        read -r answer </dev/tty || answer=""
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes|j|ja) return 0 ;;
            n|no|nein)  return 1 ;;
        esac
    done
}

# confirm_word "Explanation" WORD - the user has to type WORD exactly.
confirm_word() {
    local text="$1" word="$2" answer
    if [[ $ASSUME_YES -eq 1 ]]; then
        info "$text -> confirmed (--yes)"
        return 0
    fi
    tty_available || die "No terminal available. Re-run with --yes to accept all prompts."
    printf '%s?%s %s\n  Type %s%s%s to continue: ' "$C_YELLOW" "$C_RESET" "$text" "$C_BOLD" "$word" "$C_RESET" >/dev/tty
    read -r answer </dev/tty || answer=""
    [[ $answer == "$word" ]]
}

usage() {
    cat <<EOF
ptero-upgrade.sh v${SCRIPT_VERSION} - upgrade Pterodactyl Panel 1.x to 2.0

Usage:
  sudo ./ptero-upgrade.sh [options]
  sudo ./ptero-upgrade.sh --rollback <backup-dir>

Options:
  -d, --dir <path>          Panel directory (default: ${PANEL_DIR})
  -r, --release <tag>       Release tag to install, e.g. v2.0.0-beta.2
                            (default: newest 2.x release on GitHub)
  -b, --backup-dir <path>   Parent directory for backups (default: ${BACKUP_ROOT})
  -w, --webserver <name>    nginx | apache | caddy | none (default: auto-detect)
  -u, --web-user <user>     Web server user (default: owner of the panel dir)
  -q, --queue-service <n>   Queue worker systemd unit (default: ${QUEUE_SERVICE})
  -p, --php <version>       PHP version to install if PHP < 8.3 (8.3 or 8.4, default: ${TARGET_PHP})
      --seed-eggs           Update the default eggs after migrating (db:seed)
      --no-seed-eggs        Do not update the default eggs
  -c, --check               Only run the pre-flight checks, change nothing
  -y, --yes                 Answer all prompts with yes (non-interactive)
      --rollback <dir>      Roll back to 1.x using a backup made by this script
  -h, --help                Show this help

Guide: ${DOCS_URL}
EOF
}

# ----------------------------------------------------------------------------
# Generic helpers
# ----------------------------------------------------------------------------

# ver_ge A B -> true if version A >= B
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

have() { command -v "$1" >/dev/null 2>&1; }

unit_exists() { systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q "^$1.service"; }

# env_get FILE KEY -> value of KEY in a dotenv file, without surrounding quotes
env_get() {
    local file="$1" key="$2" line value
    line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n1 || true)"
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ $value =~ ^\"(.*)\"$ ]]; then
        # Double quotes: dotenv unescapes \" and \\
        value="$(printf '%s' "${BASH_REMATCH[1]}" | sed -e 's/\\\(["\\]\)/\1/g')"
    elif [[ $value =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    printf '%s' "$value"
}

artisan() { (cd "$1" && shift && php artisan "$@"); }

run_composer() { (cd "$1" && shift && COMPOSER_ALLOW_SUPERUSER=1 composer --no-interaction "$@"); }

mysql_run() { mysql "${MYSQL_OPTS[@]}" "$@"; }

cleanup() {
    [[ -n $WORK_DIR && -d $WORK_DIR ]] && rm -rf "$WORK_DIR"
    return 0
}

# ----------------------------------------------------------------------------
# Error handling: bring the 1.x panel back online if something fails
# ----------------------------------------------------------------------------
on_err() {
    # Only report in the main shell; subshells inherit this trap (set -E)
    [[ $BASHPID == "$$" ]] && error "Command failed (exit $2) at line $1 during stage '${STAGE}'."
    return 0
}

on_exit() {
    local code=$?
    trap - ERR
    if [[ $code -ne 0 && $RECOVERED -eq 0 ]]; then
        RECOVERED=1
        case "$STAGE" in
            prepare)
                remove_new_dir
                info "Your 1.x panel was not changed."
                ;;
            maintenance|backup)
                remove_new_dir
                info "Bringing the 1.x panel back online ..."
                artisan "$PANEL_DIR" up || true
                systemctl start "$QUEUE_SERVICE" 2>/dev/null || true
                info "Your 1.x panel is back online and the database was not changed."
                ;;
            migrate)
                handle_migration_failure
                ;;
            switch|finish)
                error "The upgrade stopped after the directories were swapped."
                error "Check the output above, then either fix the problem or roll back with:"
                error "  sudo $0 --rollback ${BACKUP_DIR}"
                ;;
        esac
        [[ -n $LOG_FILE ]] && error "Full log: ${LOG_FILE}"
    fi
    cleanup
    exit "$code"
}

remove_new_dir() {
    if [[ $CREATED_NEW_DIR -eq 1 && -n $NEW_DIR && -d $NEW_DIR ]]; then
        info "Removing unfinished ${NEW_DIR} ..."
        rm -rf "$NEW_DIR"
        CREATED_NEW_DIR=0
    fi
}

handle_migration_failure() {
    error "The database migration failed."
    error "If the message above says the database is 'missing ... 1.x migration(s)', nothing"
    error "was changed: update 1.x to the latest 1.x release, run 'php artisan migrate --force'"
    error "there, and start this script again."
    if confirm "Restore the database from the backup taken a moment ago (recommended)?" y; then
        restore_database "${BACKUP_DIR}/panel-1.x.sql" || error "Database restore failed. Restore it by hand from ${BACKUP_DIR}/panel-1.x.sql"
    else
        warn "Database NOT restored. The 1.x panel may not work until you restore it."
    fi
    remove_new_dir
    info "Bringing the 1.x panel back online ..."
    systemctl start "$QUEUE_SERVICE" 2>/dev/null || true
    artisan "$PANEL_DIR" up \
        || error "'php artisan up' failed in ${PANEL_DIR}. Fix the error above, then run it again to leave maintenance mode."
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dir)            PANEL_DIR="${2:?missing value for $1}"; shift 2 ;;
            -r|--release)        TARGET_RELEASE="${2:?missing value for $1}"; shift 2 ;;
            -b|--backup-dir)     BACKUP_ROOT="${2:?missing value for $1}"; shift 2 ;;
            -w|--webserver)      WEBSERVER="${2:?missing value for $1}"; shift 2 ;;
            -u|--web-user)       WEB_USER="${2:?missing value for $1}"; shift 2 ;;
            -q|--queue-service)  QUEUE_SERVICE="${2:?missing value for $1}"; shift 2 ;;
            -p|--php)            TARGET_PHP="${2:?missing value for $1}"; shift 2 ;;
            --seed-eggs)         SEED_EGGS="yes"; shift ;;
            --no-seed-eggs)      SEED_EGGS="no"; shift ;;
            -c|--check)          CHECK_ONLY=1; shift ;;
            -y|--yes)            ASSUME_YES=1; shift ;;
            --rollback)          MODE="rollback"; ROLLBACK_DIR="${2:?missing value for $1}"; shift 2 ;;
            -h|--help)           usage; exit 0 ;;
            *)                   usage >&2; die "Unknown option: $1" ;;
        esac
    done

    PANEL_DIR="${PANEL_DIR%/}"
    case "$WEBSERVER" in auto|nginx|apache|caddy|none) ;; *) die "--webserver must be nginx, apache, caddy or none" ;; esac
    case "$TARGET_PHP" in 8.3|8.4) ;; *) die "--php must be 8.3 or 8.4" ;; esac
    if [[ -n $TARGET_RELEASE && ! $TARGET_RELEASE =~ ^v?2\. ]]; then
        die "--release must be a 2.x tag, e.g. ${FALLBACK_RELEASE}"
    fi
    [[ -n $TARGET_RELEASE && $TARGET_RELEASE != v* ]] && TARGET_RELEASE="v${TARGET_RELEASE}"
    return 0
}

start_logging() {
    LOG_FILE="/var/log/ptero-upgrade-$(date +%Y%m%d-%H%M%S).log"
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "ptero-upgrade.sh v${SCRIPT_VERSION} - log: ${LOG_FILE}"
}

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || die "Please run this script as root (sudo)."
}

check_os() {
    local id="unknown" version="?" pretty="unknown"
    if [[ -r /etc/os-release ]]; then
        id="$(env_get /etc/os-release ID)"
        version="$(env_get /etc/os-release VERSION_ID)"
        pretty="$(env_get /etc/os-release PRETTY_NAME)"
    fi
    OS_ID="$id"
    case "$id:$version" in
        ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:12|debian:13)
            ok "Operating system: ${pretty}" ;;
        ubuntu:*|debian:*)
            warn "Operating system ${pretty} is not on the 2.0 support list (Ubuntu 22.04/24.04/26.04, Debian 12/13)." ;;
        *)
            warn "Operating system ${pretty} is not Debian/Ubuntu. This script only automates package installs on Debian/Ubuntu." ;;
    esac
}

check_tools() {
    local missing=() tool
    for tool in php composer curl tar gzip mysql mysqldump systemctl sort awk sed; do
        have "$tool" || missing+=("$tool")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"
    if ! COMPOSER_ALLOW_SUPERUSER=1 composer --version --no-interaction 2>/dev/null | grep -qE 'version 2\.'; then
        die "Composer 2 is required. Update it with: composer self-update --2"
    fi
    ok "Required tools found (composer $(COMPOSER_ALLOW_SUPERUSER=1 composer --version --no-interaction 2>/dev/null | awk '{print $3}'))"
}

check_panel_dir() {
    [[ -d $PANEL_DIR ]] || die "Panel directory ${PANEL_DIR} does not exist. Use --dir to point to your panel."
    [[ -f $PANEL_DIR/artisan && -f $PANEL_DIR/.env ]] || die "${PANEL_DIR} does not look like a Pterodactyl panel (artisan or .env missing)."
    [[ -L $PANEL_DIR ]] && die "${PANEL_DIR} is a symlink. Please pass the real directory with --dir."

    CURRENT_VERSION="$(sed -nE "s/^[[:space:]]*'version'[[:space:]]*=>[[:space:]]*'([^']+)'.*/\1/p" "$PANEL_DIR/config/app.php" 2>/dev/null | head -n1)"
    if [[ -z $CURRENT_VERSION ]]; then
        warn "Could not read the panel version from config/app.php."
        confirm "Continue anyway?" n || die "Aborted."
    elif [[ $CURRENT_VERSION =~ ^v?2\. ]]; then
        die "This panel already runs ${CURRENT_VERSION}. Nothing to do."
    elif [[ $CURRENT_VERSION =~ ^v?1\.[0-9]+ ]]; then
        if ver_ge "${CURRENT_VERSION#v}" "1.12.0"; then
            ok "Panel version: ${CURRENT_VERSION}"
        else
            die "Panel ${CURRENT_VERSION} is too old. Update to the latest 1.x release first (https://docs.pterodactyl.io/v1/panel/updating), then run this script again."
        fi
    else
        warn "Panel version is '${CURRENT_VERSION}' (not a release build). The migration itself still refuses outdated databases."
        confirm "Continue anyway?" n || die "Aborted."
    fi

    NEW_DIR="${PANEL_DIR}-2.0"
    OLD_DIR="${PANEL_DIR}-1.x"
    [[ -e $NEW_DIR ]] && die "${NEW_DIR} already exists (left over from an earlier attempt?). Move or delete it first."
    [[ -e $OLD_DIR ]] && die "${OLD_DIR} already exists. Move or delete it first."

    if [[ -z $WEB_USER ]]; then
        WEB_USER="$(stat -c %U "$PANEL_DIR")"
        [[ $WEB_USER == root || $WEB_USER == UNKNOWN ]] && WEB_USER="www-data"
    fi
    id "$WEB_USER" >/dev/null 2>&1 || die "Web server user '${WEB_USER}' does not exist. Set it with --web-user."
    WEB_GROUP="$(id -gn "$WEB_USER")"
    ok "Web server user: ${WEB_USER}:${WEB_GROUP}"

    # Modifications are not carried over to 2.0 (only .env is copied)
    if [[ -e $PANEL_DIR/blueprint.sh || -d $PANEL_DIR/.blueprint ]]; then
        warn "Blueprint was detected. Blueprint extensions and themes do NOT carry over to 2.0."
    fi
    if [[ -d $PANEL_DIR/.git ]] && (cd "$PANEL_DIR" && git status --porcelain 2>/dev/null | grep -q .); then
        warn "The panel directory has local source changes (git). Theme and code changes do NOT carry over to 2.0."
    fi
}

detect_php() {
    PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
    if ver_ge "$PHP_VER" "8.3"; then
        ok "PHP version: ${PHP_VER}"
    else
        warn "PHP ${PHP_VER} is too old: 2.0 needs PHP 8.3 or 8.4."
    fi
    FPM_SERVICE="php${PHP_VER}-fpm"
}

check_php_extensions() {
    local ext missing=()
    for ext in intl bcmath mbstring pdo_mysql xml zip gd curl openssl sodium tokenizer; do
        php -m 2>/dev/null | grep -qix "$ext" || missing+=("$ext")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "PHP extensions: all present"
    else
        warn "Missing PHP extensions for PHP ${PHP_VER}: ${missing[*]}"
    fi
    MISSING_EXT=("${missing[@]}")
}

detect_webserver() {
    local f
    if [[ $WEBSERVER == auto ]]; then
        WEBSERVER="none"
        for f in /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/conf.d/pterodactyl.conf; do
            [[ -f $f ]] && { WEBSERVER="nginx"; WEB_CONF="$f"; break; }
        done
        if [[ $WEBSERVER == none ]]; then
            for f in /etc/apache2/sites-available/pterodactyl.conf /etc/httpd/conf.d/pterodactyl.conf; do
                [[ -f $f ]] && { WEBSERVER="apache"; WEB_CONF="$f"; break; }
            done
        fi
        if [[ $WEBSERVER == none && -f /etc/caddy/Caddyfile ]] && grep -q "$PANEL_DIR/public" /etc/caddy/Caddyfile; then
            WEBSERVER="caddy"; WEB_CONF="/etc/caddy/Caddyfile"
        fi
        if [[ $WEBSERVER == none ]]; then
            # Fall back to searching for any config that serves the panel
            f="$(grep -rlsF "$PANEL_DIR/public" /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null | head -n1 || true)"
            [[ -n $f ]] && { WEBSERVER="nginx"; WEB_CONF="$f"; }
        fi
    else
        case "$WEBSERVER" in
            nginx)  for f in /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/conf.d/pterodactyl.conf; do [[ -f $f ]] && { WEB_CONF="$f"; break; }; done ;;
            apache) for f in /etc/apache2/sites-available/pterodactyl.conf /etc/httpd/conf.d/pterodactyl.conf; do [[ -f $f ]] && { WEB_CONF="$f"; break; }; done ;;
            caddy)  [[ -f /etc/caddy/Caddyfile ]] && WEB_CONF="/etc/caddy/Caddyfile" ;;
        esac
    fi

    if [[ $WEBSERVER == none ]]; then
        warn "No web server configuration for the panel was found. You need to add the /assets/ block by hand (see README)."
    elif [[ -z $WEB_CONF ]]; then
        warn "${WEBSERVER} selected, but its panel configuration file was not found. You need to add the /assets/ block by hand."
    else
        ok "Web server: ${WEBSERVER} (${WEB_CONF})"
    fi

    if [[ $WEBSERVER == nginx && -n $WEB_CONF ]]; then
        NGINX_PHP_SOCK_VER="$(grep -oE 'php8\.[0-9]+-fpm\.sock' "$WEB_CONF" | head -n1 | sed -E 's/php(8\.[0-9]+)-fpm\.sock/\1/' || true)"
        if [[ -n $NGINX_PHP_SOCK_VER ]]; then
            info "NGINX passes PHP requests to PHP ${NGINX_PHP_SOCK_VER}-FPM."
            FPM_SERVICE="php${NGINX_PHP_SOCK_VER}-fpm"
        fi
    fi
}

check_queue_service() {
    if unit_exists "$QUEUE_SERVICE"; then
        ok "Queue worker: ${QUEUE_SERVICE}.service"
    else
        warn "Queue worker unit '${QUEUE_SERVICE}.service' not found. Use --queue-service if it has another name."
    fi
}

setup_database_access() {
    local env_file="$1" conn host port user pass cnf
    conn="$(env_get "$env_file" DB_CONNECTION)"
    DB_NAME="$(env_get "$env_file" DB_DATABASE)"
    host="$(env_get "$env_file" DB_HOST)"
    port="$(env_get "$env_file" DB_PORT)"
    user="$(env_get "$env_file" DB_USERNAME)"
    pass="$(env_get "$env_file" DB_PASSWORD)"

    case "${conn:-mysql}" in mysql|mariadb) ;; *) die "Unsupported DB_CONNECTION '${conn}'. Only MySQL/MariaDB are supported." ;; esac
    [[ -n $DB_NAME ]] || die "DB_DATABASE is not set in ${env_file}."

    WORK_DIR="${WORK_DIR:-$(mktemp -d /tmp/ptero-upgrade.XXXXXX)}"
    chmod 700 "$WORK_DIR"
    cnf="$WORK_DIR/my.cnf"
    pass="${pass//\\/\\\\}"
    pass="${pass//\"/\\\"}"
    (
        umask 077
        printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\n' \
            "${host:-127.0.0.1}" "${port:-3306}" "${user:-pterodactyl}" "$pass" >"$cnf"
    )

    MYSQL_OPTS=("--defaults-extra-file=$cnf")
    if mysql_run -e 'SELECT 1' "$DB_NAME" >/dev/null 2>&1; then
        ok "Database connection: ${user}@${host:-127.0.0.1}/${DB_NAME}"
    else
        # Fall back to the local root account (unix socket), like the official guide
        MYSQL_OPTS=()
        if mysql_run -e 'SELECT 1' "$DB_NAME" >/dev/null 2>&1; then
            ok "Database connection: local root account / ${DB_NAME}"
        else
            die "Cannot connect to the database '${DB_NAME}' with the credentials from ${env_file} or as local root."
        fi
    fi
}

check_pending_migrations() {
    local pending
    pending="$(artisan "$PANEL_DIR" migrate:status 2>/dev/null | grep -c 'Pending' || true)"
    if [[ ${pending:-0} -gt 0 ]]; then
        error "Your 1.x database has ${pending} pending migration(s). 2.0 refuses to migrate such a database."
        die "Fix it first: cd ${PANEL_DIR} && php artisan migrate --force   (then run this script again)"
    fi
    ok "1.x database migrations are up to date"
}

check_database_version() {
    local version
    version="$(mysql_run -N -B -e 'SELECT VERSION()' 2>/dev/null || true)"
    if [[ -z $version ]]; then
        warn "Could not read the database server version."
    elif [[ ${version,,} == *mariadb* ]]; then
        if ver_ge "${version%%-*}" "10.11"; then ok "Database: MariaDB ${version%%-*}"
        else warn "MariaDB ${version%%-*} is not tested with 2.0 (tested: 10.11 and 11)."; fi
    else
        if ver_ge "${version%%-*}" "8.0"; then ok "Database: MySQL ${version%%-*}"
        else warn "MySQL ${version%%-*} is not tested with 2.0 (tested: 8 and 9)."; fi
    fi
}

check_disk_space() {
    local panel_mb db_mb parent_free backup_free need_parent need_backup
    [[ -d $BACKUP_ROOT ]] || die "Backup directory ${BACKUP_ROOT} does not exist."
    panel_mb="$(du -sm "$PANEL_DIR" 2>/dev/null | awk '{print $1}')"
    db_mb="$(mysql_run -N -B -e "SELECT CEIL(COALESCE(SUM(data_length+index_length),0)/1024/1024) FROM information_schema.tables WHERE table_schema='${DB_NAME}'" 2>/dev/null || echo 0)"
    parent_free="$(df -Pm "$(dirname "$PANEL_DIR")" | awk 'NR==2 {print $4}')"
    backup_free="$(df -Pm "$BACKUP_ROOT" | awk 'NR==2 {print $4}')"
    need_parent=$(( panel_mb + 500 ))
    need_backup=$(( panel_mb + db_mb * 2 + 100 ))
    if [[ $(stat -c %d "$(dirname "$PANEL_DIR")") == $(stat -c %d "$BACKUP_ROOT") ]]; then
        need_parent=$(( need_parent + need_backup ))
        need_backup=$need_parent
    fi
    (( parent_free >= need_parent )) || die "Not enough free space in $(dirname "$PANEL_DIR"): ${parent_free} MB free, about ${need_parent} MB needed."
    (( backup_free >= need_backup )) || die "Not enough free space in ${BACKUP_ROOT}: ${backup_free} MB free, about ${need_backup} MB needed."
    ok "Disk space: panel ${panel_mb} MB, database ~${db_mb} MB, enough free space"
}

resolve_release() {
    local tag api
    if [[ -z $TARGET_RELEASE ]]; then
        api="$(curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' \
            "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=50" 2>/dev/null || true)"
        tag="$(printf '%s' "$api" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v2\.[^"]+"' \
            | sed -E 's/.*"(v2\.[^"]+)"$/\1/' | head -n1 || true)"
        if [[ -n $tag ]]; then
            TARGET_RELEASE="$tag"
        else
            warn "Could not ask GitHub for the newest 2.x release, using ${FALLBACK_RELEASE}."
            TARGET_RELEASE="$FALLBACK_RELEASE"
        fi
    fi
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${TARGET_RELEASE}/panel.tar.gz"
    curl -fsL --max-time 30 -r 0-0 -o /dev/null "$DOWNLOAD_URL" \
        || die "Release ${TARGET_RELEASE} has no panel.tar.gz at ${DOWNLOAD_URL}"
    ok "Target release: ${TARGET_RELEASE}"
    if [[ $TARGET_RELEASE == *-* ]]; then
        warn "${TARGET_RELEASE} is a pre-release (open beta). Try the upgrade on a copy of your panel first."
    fi
}

check_wings() {
    local v
    if have wings; then
        v="$(wings --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
        info "Wings on this machine: ${v:-unknown}. Wings 1.13.2+ works with the 2.0 panel and can be upgraded later."
    fi
}

preflight() {
    section "Pre-flight checks"
    check_os
    check_tools
    check_panel_dir
    detect_php
    check_php_extensions
    detect_webserver
    check_queue_service
    setup_database_access "$PANEL_DIR/.env"
    check_database_version
    check_pending_migrations
    check_disk_space
    check_wings
    resolve_release
}

print_plan() {
    section "Upgrade plan"
    cat <<EOF
  Panel directory : ${PANEL_DIR}  (${CURRENT_VERSION:-unknown} -> ${TARGET_RELEASE})
  New 2.0 files   : ${NEW_DIR}  (swapped into place at the end)
  1.x files kept  : ${OLD_DIR}
  Backups         : ${BACKUP_ROOT}/ptero-upgrade-<timestamp>/
  Database        : ${DB_NAME}
  PHP             : ${PHP_VER}$(ver_ge "$PHP_VER" 8.3 || printf ' -> %s (will be installed)' "$TARGET_PHP")
  Web server      : ${WEBSERVER}${WEB_CONF:+ (${WEB_CONF})}
  Queue worker    : ${QUEUE_SERVICE}

  The panel goes into maintenance mode while the database is backed up and
  migrated. Game servers and Wings keep running.

  Before you continue, make sure that:
   - your billing module (e.g. WHMCS) supports 2.0. The Application API nest
     endpoints (/api/application/nests/...) are removed in 2.0.
   - you know that theme/code changes and addons are NOT carried over.
EOF
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        printf '\n  %sWarnings:%s\n' "$C_YELLOW" "$C_RESET"
        printf '   - %s\n' "${WARNINGS[@]}"
    fi
    echo
}

# ----------------------------------------------------------------------------
# Upgrade steps
# ----------------------------------------------------------------------------
install_php() {
    local v="$1" pkgs
    [[ $OS_ID == ubuntu || $OS_ID == debian ]] || die "Automatic PHP installation only works on Debian/Ubuntu. Install PHP ${v} by hand."
    section "Installing PHP ${v}"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-cache show "php${v}-cli" >/dev/null 2>&1; then
        if [[ $OS_ID == ubuntu ]]; then
            apt-get -y install software-properties-common
            LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
        else
            die "php${v} is not available from your APT sources. Add the sury.org PHP repository (see the Pterodactyl getting started guide) and run this script again."
        fi
    fi
    apt-get update
    pkgs=(php"$v" php"$v"-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl})
    apt-get -y install "${pkgs[@]}"
    update-alternatives --set php "/usr/bin/php${v}"
    PHP_VER="$v"
    FPM_SERVICE="php${v}-fpm"
    systemctl enable --now "$FPM_SERVICE"
    ok "PHP $(php -r 'echo PHP_VERSION;') installed and set as default."
}

install_php_extensions() {
    local ext pkgs=()
    for ext in "$@"; do
        case "$ext" in
            pdo_mysql)                    pkgs+=("php${PHP_VER}-mysql") ;;
            openssl|sodium|tokenizer)     pkgs+=("php${PHP_VER}-common") ;;
            *)                            pkgs+=("php${PHP_VER}-${ext}") ;;
        esac
    done
    [[ $OS_ID == ubuntu || $OS_ID == debian ]] || die "Install these PHP extensions by hand: $*"
    mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
    DEBIAN_FRONTEND=noninteractive apt-get -y install "${pkgs[@]}"
    if unit_exists "php${PHP_VER}-fpm"; then systemctl restart "php${PHP_VER}-fpm"; fi
    ok "Installed: ${pkgs[*]}"
}

ensure_php() {
    if ! ver_ge "$PHP_VER" "8.3"; then
        confirm "Install PHP ${TARGET_PHP} now (packages from the official PHP upgrade guide)?" y \
            || die "PHP 8.3 or newer is required. See https://docs.pterodactyl.io/v2/guides/configuration/php-upgrade"
        install_php "$TARGET_PHP"
        check_php_extensions
    fi
    if [[ ${#MISSING_EXT[@]} -gt 0 ]]; then
        confirm "Install the missing PHP extensions (${MISSING_EXT[*]})?" y \
            || die "Missing PHP extensions: ${MISSING_EXT[*]}"
        install_php_extensions "${MISSING_EXT[@]}"
    fi

    # NGINX must use an FPM socket of a supported PHP version
    if [[ $WEBSERVER == nginx && -n $WEB_CONF && -n ${NGINX_PHP_SOCK_VER:-} && $NGINX_PHP_SOCK_VER != "$PHP_VER" ]]; then
        if ver_ge "$NGINX_PHP_SOCK_VER" "8.3" && unit_exists "php${NGINX_PHP_SOCK_VER}-fpm"; then
            FPM_SERVICE="php${NGINX_PHP_SOCK_VER}-fpm"
            warn "NGINX uses PHP ${NGINX_PHP_SOCK_VER}-FPM but the CLI uses PHP ${PHP_VER}. Make sure both have the same extensions."
        else
            unit_exists "php${PHP_VER}-fpm" || die "php${PHP_VER}-fpm is not installed. Install it: apt install php${PHP_VER}-fpm"
            confirm "NGINX uses PHP ${NGINX_PHP_SOCK_VER}-FPM. Switch it to PHP ${PHP_VER}-FPM?" y \
                || die "The panel must be served by PHP 8.3 or newer."
            cp -a "$WEB_CONF" "$WORK_DIR/nginx-before-php-switch.conf"
            sed -i -e "s/php8\.[0-9]*-fpm\.sock/php${PHP_VER}-fpm.sock/" "$WEB_CONF"
            systemctl enable --now "php${PHP_VER}-fpm"
            if nginx -t; then
                systemctl reload nginx
                FPM_SERVICE="php${PHP_VER}-fpm"
                NGINX_PHP_SOCK_VER="$PHP_VER"
                ok "NGINX now uses PHP ${PHP_VER}-FPM."
            else
                cp -a "$WORK_DIR/nginx-before-php-switch.conf" "$WEB_CONF"
                die "nginx -t failed after switching the PHP socket. The change was reverted."
            fi
        fi
    fi
    if [[ $WEBSERVER == nginx ]] && ! unit_exists "$FPM_SERVICE"; then
        warn "${FPM_SERVICE}.service not found. Restart your PHP-FPM service by hand after the upgrade."
    fi
}

prepare_new_release() {
    STAGE="prepare"
    section "Downloading Pterodactyl ${TARGET_RELEASE}"
    curl -fL --retry 3 --progress-bar -o "$WORK_DIR/panel.tar.gz" "$DOWNLOAD_URL"
    tar -tzf "$WORK_DIR/panel.tar.gz" >/dev/null || die "The downloaded archive is damaged."

    mkdir "$NEW_DIR"
    CREATED_NEW_DIR=1
    tar -xzf "$WORK_DIR/panel.tar.gz" -C "$NEW_DIR"
    [[ -f $NEW_DIR/artisan ]] || die "The archive does not contain a panel (artisan missing)."

    # The .env needs no changes. Never run key:generate - the APP_KEY must stay the same.
    cp -p "$PANEL_DIR/.env" "$NEW_DIR/.env"
    ok "Unpacked to ${NEW_DIR} and copied .env"

    section "Installing PHP dependencies (composer)"
    run_composer "$NEW_DIR" install --no-dev --optimize-autoloader --no-interaction
    run_composer "$NEW_DIR" check-platform-reqs --no-dev \
        || die "PHP is missing something 2.0 needs (see above). Install it and run the script again."
    ok "Dependencies installed"
}

enter_maintenance() {
    STAGE="maintenance"
    section "Entering maintenance mode"
    artisan "$PANEL_DIR" down
    if unit_exists "$QUEUE_SERVICE"; then systemctl stop "$QUEUE_SERVICE"; fi
    ok "Panel is in maintenance mode, queue worker stopped"
}

create_backup() {
    STAGE="backup"
    section "Backing up the panel"
    BACKUP_DIR="${BACKUP_ROOT%/}/ptero-upgrade-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"

    info "Dumping database '${DB_NAME}' ..."
    local dump="$BACKUP_DIR/panel-1.x.sql"
    if ! mysqldump "${MYSQL_OPTS[@]}" --single-transaction --routines --triggers --no-tablespaces "$DB_NAME" >"$dump" 2>"$WORK_DIR/dump.err"; then
        cat "$WORK_DIR/dump.err" >&2
        warn "mysqldump with --routines failed (missing privilege?), retrying without routines ..."
        mysqldump "${MYSQL_OPTS[@]}" --single-transaction --triggers --no-tablespaces "$DB_NAME" >"$dump"
    fi
    tail -n1 "$dump" | grep -q 'Dump completed' || die "The database dump looks incomplete: ${dump}"
    chmod 600 "$dump"

    cp "$PANEL_DIR/.env" "$BACKUP_DIR/panel-1.x.env"
    chmod 600 "$BACKUP_DIR/panel-1.x.env"

    info "Archiving ${PANEL_DIR} ..."
    tar -czf "$BACKUP_DIR/panel-1.x-files.tar.gz" -C "$PANEL_DIR" .
    chmod 600 "$BACKUP_DIR/panel-1.x-files.tar.gz"

    if [[ -n $WEB_CONF && -f $WEB_CONF ]]; then
        cp "$WEB_CONF" "$BACKUP_DIR/webserver.conf"
        chmod 600 "$BACKUP_DIR/webserver.conf"
    fi

    write_state
    ok "Backup written to ${BACKUP_DIR} ($(du -sh "$BACKUP_DIR" | awk '{print $1}'))"
    info "Keep a copy of panel-1.x.env somewhere safe. Without its APP_KEY your data cannot be decrypted."
}

write_state() {
    local f="$BACKUP_DIR/upgrade.state"
    {
        echo "# Written by ptero-upgrade.sh v${SCRIPT_VERSION} on $(date -Is)"
        printf 'S_PANEL_DIR=%q\n' "$PANEL_DIR"
        printf 'S_OLD_DIR=%q\n' "$OLD_DIR"
        printf 'S_FROM_VERSION=%q\n' "$CURRENT_VERSION"
        printf 'S_TO_RELEASE=%q\n' "$TARGET_RELEASE"
        printf 'S_QUEUE_SERVICE=%q\n' "$QUEUE_SERVICE"
        printf 'S_FPM_SERVICE=%q\n' "$FPM_SERVICE"
        printf 'S_WEBSERVER=%q\n' "$WEBSERVER"
        printf 'S_WEB_CONF=%q\n' "$WEB_CONF"
        printf 'S_WEB_USER=%q\n' "$WEB_USER"
    } >"$f"
    chmod 600 "$f"
}

migrate_database() {
    STAGE="migrate"
    section "Migrating the database"
    artisan "$NEW_DIR" down || true
    # On failure the EXIT handler offers to restore the database (stage "migrate")
    artisan "$NEW_DIR" migrate --force
    ok "Database migrated"

    local seed="$SEED_EGGS"
    if [[ $seed == ask ]]; then
        if [[ $ASSUME_YES -eq 1 ]]; then seed="no"
        elif confirm "Update the default eggs (php artisan db:seed)? Optional; custom egg changes to default eggs may be overwritten." n; then seed="yes"
        else seed="no"; fi
    fi
    if [[ $seed == yes ]]; then
        artisan "$NEW_DIR" db:seed --force
        ok "Default eggs updated"
    fi
}

switch_directories() {
    STAGE="switch"
    section "Switching to 2.0"
    chown -R "$WEB_USER:$WEB_GROUP" "$NEW_DIR"
    mv "$PANEL_DIR" "$OLD_DIR"
    mv "$NEW_DIR" "$PANEL_DIR"
    CREATED_NEW_DIR=0
    ok "${PANEL_DIR} is now 2.0, 1.x moved to ${OLD_DIR}"
}

# Insert the /assets/ block before every "location ~ \.php$" in the panel's server blocks.
patch_nginx() {
    local tmp="$WORK_DIR/nginx.conf.new" count
    awk '
        /^[[:space:]]*location[[:space:]]+~[[:space:]]+\\\.php\$/ {
            match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
            print ind "location ^~ /assets/ {"
            print ind "    location ~ /\\. {"
            print ind "        deny all;"
            print ind "    }"
            print ""
            print ind "    try_files $uri =404;"
            print ind "}"
            print ""
            n++
        }
        { print }
        END { print n + 0 > "/dev/stderr" }
    ' "$WEB_CONF" >"$tmp" 2>"$WORK_DIR/nginx.count"
    count="$(cat "$WORK_DIR/nginx.count")"
    if [[ $count -eq 0 ]]; then
        return 1
    fi
    cat "$tmp" >"$WEB_CONF"
    if nginx -t; then
        systemctl reload nginx
        ok "Added the /assets/ block to ${WEB_CONF} (${count}x) and reloaded NGINX"
    else
        cp -p "$BACKUP_DIR/webserver.conf" "$WEB_CONF"
        error "nginx -t failed, the original configuration was restored."
        return 1
    fi
}

# Insert the assets <Directory> after the panel's public <Directory> block.
patch_apache() {
    local tmp="$WORK_DIR/apache.conf.new" count ctl
    if ! (apachectl -M 2>/dev/null || apache2ctl -M 2>/dev/null) | grep -q 'php.*_module'; then
        error "Apache does not use mod_php; the official snippet (php_admin_flag) needs it."
        return 1
    fi
    awk -v pub="$PANEL_DIR/public" '
        {
            print
            line = $0; gsub(/"/, "", line)
            if (line ~ /^[[:space:]]*<Directory[[:space:]]/ && index(line, pub ">") > 0) { inpub = 1; next }
            if (inpub && $0 ~ /^[[:space:]]*<\/Directory>/) {
                inpub = 0
                match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
                print ""
                print ind "<Directory \"" pub "/assets\">"
                print ind "    AllowOverride None"
                print ind "    php_admin_flag engine off"
                print ""
                print ind "    <FilesMatch \"^\\.\">"
                print ind "        Require all denied"
                print ind "    </FilesMatch>"
                print ind "</Directory>"
                n++
            }
        }
        END { print n + 0 > "/dev/stderr" }
    ' "$WEB_CONF" >"$tmp" 2>"$WORK_DIR/apache.count"
    count="$(cat "$WORK_DIR/apache.count")"
    [[ $count -gt 0 ]] || return 1
    cat "$tmp" >"$WEB_CONF"
    ctl="apachectl"; have apachectl || ctl="apache2ctl"
    if "$ctl" configtest; then
        if unit_exists apache2; then systemctl reload apache2; else systemctl reload httpd; fi
        ok "Added the assets <Directory> block to ${WEB_CONF} (${count}x) and reloaded Apache"
    else
        cp -p "$BACKUP_DIR/webserver.conf" "$WEB_CONF"
        error "Apache configtest failed, the original configuration was restored."
        return 1
    fi
}

print_manual_webserver_step() {
    warn "Please add the /assets/ block to your web server config by hand (the panel works without it, but themes/extensions need it)."
    case "$WEBSERVER" in
        apache)
            cat <<EOF
  Add inside the panel's <VirtualHost> (the :443 one with SSL), after the existing <Directory> block:

    <Directory "${PANEL_DIR}/public/assets">
        AllowOverride None
        php_admin_flag engine off

        <FilesMatch "^\.">
            Require all denied
        </FilesMatch>
    </Directory>

  Then: apachectl configtest && systemctl reload apache2
EOF
            ;;
        caddy)
            cat <<EOF
  In ${WEB_CONF:-/etc/caddy/Caddyfile}, add to the panel's site block and add @php to php_fastcgi:

    @assets-dotfiles path_regexp ^/assets/(.*/)?\.
    respond @assets-dotfiles 403

    @php not path /assets/*
    php_fastcgi @php unix//run/php/php${PHP_VER}-fpm.sock {

  Then: systemctl reload caddy
EOF
            ;;
        *)
            cat <<'EOF'
  NGINX - add inside the panel's server block (the port 443 one with SSL), next to "location /":

    location ^~ /assets/ {
        location ~ /\. {
            deny all;
        }

        try_files $uri =404;
    }

  Then: nginx -t && systemctl reload nginx
EOF
            ;;
    esac
}

update_webserver() {
    section "Updating the web server configuration"
    if [[ -z $WEB_CONF || ! -f $WEB_CONF ]]; then
        print_manual_webserver_step
        return 0
    fi
    case "$WEBSERVER" in
        nginx)
            if grep -qE 'location[[:space:]]+\^~[[:space:]]+/assets/' "$WEB_CONF"; then
                ok "NGINX already has the /assets/ block"
            elif ! patch_nginx; then
                print_manual_webserver_step
            fi
            ;;
        apache)
            if grep -qF "${PANEL_DIR}/public/assets" "$WEB_CONF"; then
                ok "Apache already has the assets <Directory> block"
            elif ! patch_apache; then
                print_manual_webserver_step
            fi
            ;;
        caddy)
            if grep -qF '@assets-dotfiles' "$WEB_CONF"; then
                ok "Caddyfile already has the assets rules"
            else
                print_manual_webserver_step
            fi
            ;;
        *)
            print_manual_webserver_step
            ;;
    esac
}

finish_upgrade() {
    STAGE="finish"
    section "Clearing caches and restarting services"
    artisan "$PANEL_DIR" optimize:clear
    if unit_exists "$FPM_SERVICE"; then systemctl restart "$FPM_SERVICE"; fi
    if [[ $WEBSERVER == apache ]]; then
        if unit_exists apache2; then systemctl reload apache2; elif unit_exists httpd; then systemctl reload httpd; fi
    fi
    if unit_exists "$QUEUE_SERVICE"; then systemctl start "$QUEUE_SERVICE"; fi

    section "Leaving maintenance mode"
    artisan "$PANEL_DIR" up
    ok "Panel is online"

    local url code
    url="$(env_get "$PANEL_DIR/.env" APP_URL)"
    if [[ -n $url ]]; then
        code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "$url" || true)"
        case "$code" in
            2*|3*) ok "${url} answers with HTTP ${code}" ;;
            *)     warn "${url} answered with HTTP ${code:-no response}. Check the panel in your browser and the log in ${PANEL_DIR}/storage/logs/." ;;
        esac
    fi
}

print_summary() {
    section "Done - Pterodactyl ${TARGET_RELEASE} is installed"
    cat <<EOF
  Backups   : ${BACKUP_DIR}
  1.x files : ${OLD_DIR}
  Log       : ${LOG_FILE}

  Next steps:
   1. Open the panel and sign in. Check servers, console, files and SFTP.
   2. Review egg tags in Admin -> Eggs (nests were converted to tags).
   3. Keep ${OLD_DIR} and the backup until you are sure everything works.
   4. Wings does not need an immediate update (1.13.2+ works with 2.0).

  Something wrong? Roll back to 1.x with:
    sudo $0 --rollback ${BACKUP_DIR}
EOF
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        printf '\n  %sWarnings during the run:%s\n' "$C_YELLOW" "$C_RESET"
        printf '   - %s\n' "${WARNINGS[@]}"
    fi
}

# ----------------------------------------------------------------------------
# Database restore + rollback
# ----------------------------------------------------------------------------
restore_database() {
    local dump="$1"
    [[ -s $dump ]] || { error "Backup ${dump} is missing or empty."; return 1; }
    info "Restoring database '${DB_NAME}' from ${dump} ..."
    mysql_run -e "DROP DATABASE \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\`;" || return 1
    mysql_run "$DB_NAME" <"$dump" || return 1
    ok "Database restored"
}

rollback() {
    local dir="${ROLLBACK_DIR%/}" state failed_dir
    state="$dir/upgrade.state"
    [[ -f $state && -f $dir/panel-1.x.sql && -f $dir/panel-1.x.env ]] \
        || die "${dir} is not a backup made by this script (upgrade.state, panel-1.x.sql or panel-1.x.env missing)."

    local S_PANEL_DIR="" S_OLD_DIR="" S_FROM_VERSION="" S_TO_RELEASE="" S_QUEUE_SERVICE="" S_FPM_SERVICE="" S_WEBSERVER="" S_WEB_CONF="" S_WEB_USER=""
    [[ $(stat -c %u "$state") -eq 0 ]] || die "${state} is not owned by root. Refusing to read it."
    # shellcheck disable=SC1090
    source "$state"
    PANEL_DIR="$S_PANEL_DIR"; QUEUE_SERVICE="$S_QUEUE_SERVICE"; FPM_SERVICE="$S_FPM_SERVICE"

    section "Rollback from ${S_TO_RELEASE:-2.0} to Pterodactyl ${S_FROM_VERSION:-1.x}"
    cat <<EOF
  Panel directory : ${S_PANEL_DIR}
  1.x files       : ${S_OLD_DIR}$([[ -d $S_OLD_DIR ]] || printf ' (missing - will be restored from the archive)')
  Database backup : ${dir}/panel-1.x.sql

  This replaces the current panel with 1.x and restores the database backup.
  Everything changed in the panel since the upgrade is lost. Servers created on
  2.0 stay on your Wings nodes, database passwords changed on 2.0 must be
  rotated again, and backups made on 2.0 stay in your backup storage.
EOF
    confirm_word "Roll back to 1.x?" "ROLLBACK" || die "Aborted."

    setup_database_access "$dir/panel-1.x.env"

    section "Stopping the panel"
    if [[ -f $PANEL_DIR/artisan ]]; then artisan "$PANEL_DIR" down || true; fi
    if unit_exists "$QUEUE_SERVICE"; then systemctl stop "$QUEUE_SERVICE"; fi

    section "Restoring 1.x files"
    failed_dir="${PANEL_DIR}-2.0-failed-$(date +%Y%m%d-%H%M%S)"
    if [[ -d $PANEL_DIR ]]; then
        mv "$PANEL_DIR" "$failed_dir"
        info "2.0 files moved to ${failed_dir}"
    fi
    if [[ -d $S_OLD_DIR ]]; then
        mv "$S_OLD_DIR" "$PANEL_DIR"
    else
        mkdir -p "$PANEL_DIR"
        tar -xzf "$dir/panel-1.x-files.tar.gz" -C "$PANEL_DIR"
        [[ -n $S_WEB_USER ]] && chown -R "$S_WEB_USER:$(id -gn "$S_WEB_USER")" "$PANEL_DIR"
    fi
    ok "1.x files are back in ${PANEL_DIR}"

    section "Restoring the database"
    restore_database "$dir/panel-1.x.sql" || die "Database restore failed. Restore ${dir}/panel-1.x.sql by hand, then run 'php artisan up'."

    if [[ -f $dir/webserver.conf && -n $S_WEB_CONF ]]; then
        section "Restoring the web server configuration"
        cp -p "$dir/webserver.conf" "$S_WEB_CONF"
        case "$S_WEBSERVER" in
            nginx)  nginx -t && systemctl reload nginx ;;
            apache) { apachectl configtest || apache2ctl configtest; } && { systemctl reload apache2 2>/dev/null || systemctl reload httpd; } ;;
            caddy)  systemctl reload caddy ;;
        esac || warn "Reloading ${S_WEBSERVER} failed. Check ${S_WEB_CONF}."
    fi

    section "Starting 1.x"
    artisan "$PANEL_DIR" cache:clear
    artisan "$PANEL_DIR" config:clear
    artisan "$PANEL_DIR" view:clear
    if unit_exists "$FPM_SERVICE"; then systemctl restart "$FPM_SERVICE"; fi
    if [[ $S_WEBSERVER == apache ]]; then systemctl reload apache2 2>/dev/null || systemctl reload httpd 2>/dev/null || true; fi
    if unit_exists "$QUEUE_SERVICE"; then systemctl start "$QUEUE_SERVICE"; fi
    artisan "$PANEL_DIR" up

    section "Rollback finished"
    echo "  The panel runs ${S_FROM_VERSION:-1.x} again. The 2.0 files are in ${failed_dir:-<none>}."
    echo "  Log: ${LOG_FILE}"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_root
    trap on_exit EXIT
    trap 'exit 130' INT TERM
    trap 'on_err $LINENO $?' ERR

    if [[ $MODE == rollback ]]; then
        start_logging
        check_os
        rollback
        return
    fi

    if [[ $CHECK_ONLY -eq 0 ]]; then start_logging; fi
    preflight

    if [[ $CHECK_ONLY -eq 1 ]]; then
        print_plan
        info "Check finished (--check). Nothing was changed."
        return
    fi

    print_plan
    confirm_word "Pterodactyl 2.0 is an open beta. Have you read ${DOCS_URL} and do you want to upgrade now?" "UPGRADE" \
        || die "Aborted. Nothing was changed."

    ensure_php
    prepare_new_release
    enter_maintenance
    create_backup
    migrate_database
    switch_directories
    update_webserver
    finish_upgrade
    STAGE="done"
    print_summary
}

main "$@"
