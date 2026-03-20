#!/usr/bin/env bash

set -euo pipefail

FORCE=0
NO_INPUT=0
CHANGED=0
RESULT="already ready"
SESSION_API_KEY=""

NODE_STATUS="missing"
NPM_STATUS="missing"
CODEX_STATUS="missing"
AUTH_STATUS="missing"

PRE_NODE=0
PRE_NPM=0
PRE_CODEX=0
PRE_AUTH=0

APT_BACKUP_DIR=""
PACMAN_BACKUP_FILE=""

NPM_MIRROR_REGISTRY="https://registry.npmmirror.com"
NPM_OFFICIAL_REGISTRY="https://registry.npmjs.org"
TUNA_GIT_ENDPOINT="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew"
TUNA_BREW_API="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
TUNA_BREW_BOTTLES="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"

usage() {
  cat <<'EOF'
用法:
  ./bootstrap.sh [--force] [--no-input]

参数:
  --force      忽略已安装检查，强制重装
  --no-input   非交互模式，跳过 API Key 录入
  -h, --help   显示帮助
EOF
}

log() {
  printf '[codex-init] %s\n' "$*"
}

warn() {
  printf '[codex-init] WARN: %s\n' "$*" >&2
}

die() {
  printf '[codex-init] ERROR: %s\n' "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sudo_cmd() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    printf '%s' ""
  elif has_cmd sudo; then
    printf '%s' "sudo"
  else
    die "需要管理员权限，但当前系统没有 sudo。"
  fi
}

run_privileged() {
  local sudo_bin
  sudo_bin="$(sudo_cmd)"
  if [ -n "$sudo_bin" ]; then
    "$sudo_bin" "$@"
  else
    "$@"
  fi
}

detect_auth() {
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    return 0
  fi
  return 1
}

current_api_key() {
  if [ -n "$SESSION_API_KEY" ]; then
    printf '%s' "$SESSION_API_KEY"
    return 0
  fi

  if [ -n "${OPENAI_API_KEY:-}" ]; then
    printf '%s' "${OPENAI_API_KEY}"
    return 0
  fi

  printf '%s' ""
}

record_precheck() {
  if has_cmd node && node -v >/dev/null 2>&1; then
    PRE_NODE=1
  fi
  if has_cmd npm && npm -v >/dev/null 2>&1; then
    PRE_NPM=1
  fi
  if has_cmd codex && codex --version >/dev/null 2>&1; then
    PRE_CODEX=1
  fi
  if detect_auth; then
    PRE_AUTH=1
  fi
}

set_component_statuses() {
  if has_cmd node && node -v >/dev/null 2>&1; then
    NODE_STATUS="installed"
  else
    NODE_STATUS="missing"
  fi

  if has_cmd npm && npm -v >/dev/null 2>&1; then
    NPM_STATUS="installed"
  else
    NPM_STATUS="missing"
  fi

  if has_cmd codex && codex --version >/dev/null 2>&1; then
    CODEX_STATUS="installed"
  else
    CODEX_STATUS="missing"
  fi

  if detect_auth || [ -n "$SESSION_API_KEY" ]; then
    AUTH_STATUS="installed"
  elif [ "$NO_INPUT" -eq 1 ]; then
    AUTH_STATUS="skipped"
  else
    AUTH_STATUS="missing"
  fi
}

cleanup() {
  if [ -n "$APT_BACKUP_DIR" ] && [ -d "$APT_BACKUP_DIR" ]; then
    restore_apt_sources || true
  fi

  if [ -n "$PACMAN_BACKUP_FILE" ] && [ -f "$PACMAN_BACKUP_FILE" ]; then
    restore_pacman_mirror || true
  fi
}

trap cleanup EXIT

with_brew_mirror_env() {
  HOMEBREW_BREW_GIT_REMOTE="${TUNA_GIT_ENDPOINT}/brew.git" \
  HOMEBREW_CORE_GIT_REMOTE="${TUNA_GIT_ENDPOINT}/homebrew-core.git" \
  HOMEBREW_API_DOMAIN="${TUNA_BREW_API}" \
  HOMEBREW_BOTTLE_DOMAIN="${TUNA_BREW_BOTTLES}" \
  HOMEBREW_INSTALL_FROM_API=1 \
  "$@"
}

ensure_brew_in_path() {
  if has_cmd brew; then
    return 0
  fi

  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    return 0
  fi

  if [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
    return 0
  fi

  return 1
}

ensure_homebrew() {
  if ensure_brew_in_path; then
    return 0
  fi

  if ! has_cmd git || ! has_cmd curl; then
    die "macOS 安装 Homebrew 需要 git 和 curl。"
  fi

  if ! xcode-select -p >/dev/null 2>&1; then
    die "缺少 Xcode Command Line Tools，请先执行 xcode-select --install。"
  fi

  log "未检测到 Homebrew，使用清华镜像安装。"
  local tmpdir
  tmpdir="$(mktemp -d)"
  git clone --depth=1 "${TUNA_GIT_ENDPOINT}/install.git" "${tmpdir}/brew-install"
  with_brew_mirror_env env NONINTERACTIVE=1 /bin/bash "${tmpdir}/brew-install/install.sh"
  ensure_brew_in_path || die "Homebrew 安装完成后仍不可用。"
  CHANGED=1
}

install_node_macos() {
  ensure_homebrew
  log "安装 Node.js/npm。"
  if ! with_brew_mirror_env brew install node; then
    warn "Homebrew 国内镜像安装失败，回退官方源重试。"
    brew install node
  fi
}

backup_apt_sources() {
  if [ -n "$APT_BACKUP_DIR" ]; then
    return 0
  fi

  APT_BACKUP_DIR="$(mktemp -d)"
  if [ -f /etc/apt/sources.list ]; then
    run_privileged cp /etc/apt/sources.list "${APT_BACKUP_DIR}/sources.list"
  fi
  if [ -d /etc/apt/sources.list.d ]; then
    run_privileged cp -a /etc/apt/sources.list.d "${APT_BACKUP_DIR}/sources.list.d"
  fi
}

restore_apt_sources() {
  [ -n "$APT_BACKUP_DIR" ] || return 0
  if [ -f "${APT_BACKUP_DIR}/sources.list" ]; then
    run_privileged cp "${APT_BACKUP_DIR}/sources.list" /etc/apt/sources.list
  fi
  if [ -d "${APT_BACKUP_DIR}/sources.list.d" ]; then
    run_privileged rm -rf /etc/apt/sources.list.d
    run_privileged cp -a "${APT_BACKUP_DIR}/sources.list.d" /etc/apt/sources.list.d
  fi
  rm -rf "$APT_BACKUP_DIR"
  APT_BACKUP_DIR=""
}

apply_apt_tuna_mirror() {
  backup_apt_sources
  local file
  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$file" ] || continue
    run_privileged sed -E -i \
      's#https?://(archive\.ubuntu\.com|security\.ubuntu\.com|deb\.debian\.org|security\.debian\.org)#https://mirrors.tuna.tsinghua.edu.cn#g' \
      "$file"
  done
}

install_node_apt() {
  local mirror_applied=0
  log "使用 apt 安装 Node.js/npm。"
  if apply_apt_tuna_mirror; then
    mirror_applied=1
  fi

  if ! run_privileged apt-get update || ! run_privileged apt-get install -y nodejs npm; then
    if [ "$mirror_applied" -eq 1 ]; then
      warn "apt 国内镜像失败，恢复原源后重试。"
      restore_apt_sources
      run_privileged apt-get update
      run_privileged apt-get install -y nodejs npm
    else
      return 1
    fi
  fi

  if [ "$mirror_applied" -eq 1 ]; then
    restore_apt_sources
  fi
}

restore_pacman_mirror() {
  [ -n "$PACMAN_BACKUP_FILE" ] || return 0
  run_privileged cp "$PACMAN_BACKUP_FILE" /etc/pacman.d/mirrorlist
  rm -f "$PACMAN_BACKUP_FILE"
  PACMAN_BACKUP_FILE=""
}

install_node_pacman() {
  log "使用 pacman 安装 Node.js/npm。"
  PACMAN_BACKUP_FILE="$(mktemp)"
  run_privileged cp /etc/pacman.d/mirrorlist "$PACMAN_BACKUP_FILE"
  printf 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch\n' | run_privileged tee /etc/pacman.d/mirrorlist >/dev/null
  if ! run_privileged pacman -Sy --noconfirm nodejs npm; then
    warn "pacman 国内镜像失败，恢复原源后重试。"
    restore_pacman_mirror
    run_privileged pacman -Sy --noconfirm nodejs npm
  else
    restore_pacman_mirror
  fi
}

install_node_dnf() {
  local distro_id="${ID:-}"
  local version_id="${VERSION_ID:-}"
  local arch
  arch="$(uname -m)"

  log "使用 dnf 安装 Node.js/npm。"
  if [ "$distro_id" = "fedora" ] && [ -n "$version_id" ]; then
    if ! run_privileged dnf install -y \
      --disablerepo='*' \
      --repofrompath=fedora,"https://mirrors.tuna.tsinghua.edu.cn/fedora/releases/${version_id}/Everything/${arch}/os/" \
      --repofrompath=updates,"https://mirrors.tuna.tsinghua.edu.cn/fedora/updates/${version_id}/Everything/${arch}/" \
      --enablerepo=fedora \
      --enablerepo=updates \
      nodejs npm; then
      warn "dnf 国内镜像失败，回退系统现有源重试。"
      run_privileged dnf install -y nodejs npm
    fi
  else
    warn "当前 dnf 发行版未做临时换源，改用系统现有源安装。"
    run_privileged dnf install -y nodejs npm
  fi
}

install_node_linux() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi

  if has_cmd apt-get; then
    install_node_apt
    return 0
  fi

  if has_cmd dnf; then
    install_node_dnf
    return 0
  fi

  if has_cmd pacman; then
    install_node_pacman
    return 0
  fi

  die "当前 Linux 发行版未识别到受支持的包管理器。"
}

ensure_node() {
  if [ "$FORCE" -eq 0 ] && [ "$PRE_NODE" -eq 1 ] && [ "$PRE_NPM" -eq 1 ]; then
    return 0
  fi

  case "$(uname -s)" in
    Darwin)
      install_node_macos
      ;;
    Linux)
      install_node_linux
      ;;
    *)
      die "bootstrap.sh 仅支持 macOS/Linux。"
      ;;
  esac

  has_cmd node || die "Node.js 安装失败。"
  has_cmd npm || die "npm 安装失败。"
  CHANGED=1
}

install_codex_with_registry() {
  local registry="$1"
  if npm install -g @openai/codex --registry="$registry"; then
    return 0
  fi

  if has_cmd sudo && [ "${EUID:-$(id -u)}" -ne 0 ]; then
    if sudo npm install -g @openai/codex --registry="$registry"; then
      return 0
    fi
  fi

  return 1
}

ensure_codex() {
  if [ "$FORCE" -eq 0 ] && [ "$PRE_CODEX" -eq 1 ]; then
    return 0
  fi

  log "安装 Codex CLI。"
  if ! install_codex_with_registry "$NPM_MIRROR_REGISTRY"; then
    warn "npm 国内镜像失败，回退官方源重试。"
    install_codex_with_registry "$NPM_OFFICIAL_REGISTRY"
  fi

  has_cmd codex || die "Codex CLI 安装失败。"
  CHANGED=1
}

prompt_for_auth() {
  if detect_auth && [ "$FORCE" -eq 0 ]; then
    return 0
  fi

  if [ "$NO_INPUT" -eq 1 ]; then
    return 0
  fi

  printf '请输入 OPENAI_API_KEY: '
  IFS= read -r -s SESSION_API_KEY
  printf '\n'

  if [ -z "$SESSION_API_KEY" ]; then
    warn "未输入 API Key，跳过认证。"
    return 0
  fi

  if has_cmd codex; then
    OPENAI_API_KEY="$SESSION_API_KEY" codex --version >/dev/null 2>&1 || true
  fi
  CHANGED=1
}

write_codex_files() {
  local codex_dir config_path auth_path api_key wrote_any
  codex_dir="${HOME}/.codex"
  config_path="${codex_dir}/config.toml"
  auth_path="${codex_dir}/auth.json"
  api_key="$(current_api_key)"
  wrote_any=0

  mkdir -p "$codex_dir"

  if [ -e "$config_path" ]; then
    log "${config_path} 已存在，默认跳过。"
  else
    cat >"$config_path" <<'EOF'
model_provider = "custom"
model = "gpt-5.4"
model_reasoning_effort = "high"
disable_response_storage = true

[model_providers.custom]
name = "custom"
wire_api = "responses"
requires_openai_auth = true
EOF
    log "已生成 ${config_path}。"
    wrote_any=1
  fi

  if [ -e "$auth_path" ]; then
    log "${auth_path} 已存在，默认跳过。"
  else
    printf '{\n  "OPENAI_API_KEY": "%s"\n}\n' "$api_key" >"$auth_path"
    log "已生成 ${auth_path}。"
    wrote_any=1
  fi

  if [ "$wrote_any" -eq 1 ]; then
    CHANGED=1
  fi
}

prompt_generate_codex_files() {
  if [ "$NO_INPUT" -eq 1 ]; then
    return 0
  fi

  printf '是否生成 ~/.codex/config.toml 和 ~/.codex/auth.json? [y/N]: '
  local reply
  IFS= read -r reply

  case "$reply" in
    y|Y|yes|YES|Yes)
      write_codex_files
      ;;
    *)
      log "跳过生成 Codex 配置文件。"
      ;;
  esac
}

print_auth_hint() {
  if detect_auth; then
    log "检测到当前会话已存在 OPENAI_API_KEY。"
    return 0
  fi

  if [ -n "$SESSION_API_KEY" ]; then
    local profile_file
    case "${SHELL:-}" in
      */zsh) profile_file="~/.zshrc" ;;
      */bash) profile_file="~/.bashrc" ;;
      *) profile_file="~/.profile" ;;
    esac
    log "如需持久化，请手动写入 ${profile_file}:"
    printf 'export OPENAI_API_KEY="%s"\n' "$SESSION_API_KEY"
  else
    warn "未检测到 OPENAI_API_KEY。你也可以用其他登录方式，但脚本未自动写入认证配置。"
  fi
}

print_summary() {
  set_component_statuses

  if [ "$CHANGED" -eq 1 ]; then
    RESULT="initialized"
  fi

  printf '\n'
  printf 'node: %s\n' "$NODE_STATUS"
  printf 'npm: %s\n' "$NPM_STATUS"
  printf 'codex: %s\n' "$CODEX_STATUS"
  printf 'auth: %s\n' "$AUTH_STATUS"
  printf 'result: %s\n' "$RESULT"

  if has_cmd node; then
    printf 'node -v: %s\n' "$(node -v 2>/dev/null || printf 'n/a')"
  fi
  if has_cmd npm; then
    printf 'npm -v: %s\n' "$(npm -v 2>/dev/null || printf 'n/a')"
  fi
  if has_cmd codex; then
    printf 'codex --version: %s\n' "$(codex --version 2>/dev/null || printf 'n/a')"
  fi
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)
        FORCE=1
        ;;
      --no-input)
        NO_INPUT=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
    shift
  done

  record_precheck
  ensure_node
  ensure_codex
  prompt_for_auth
  prompt_generate_codex_files
  print_summary
  print_auth_hint
}

main "$@"
