#!/usr/bin/env bash
# =============================================================================
# fix-cf-browser-ssh-users.sh
# 为已安装 Cloudflare Browser SSH 的服务器补充多用户登录配置。
#
# 用法：
#   sudo bash fix-cf-browser-ssh-users.sh \
#     --sso-email alice@example.com \
#     --sso-email bob@example.com
#
#   sudo bash fix-cf-browser-ssh-users.sh \
#     --sso-emails alice@example.com,bob@example.com
#
# 可选：
#   --ca-pubkey <string|filepath>  写入/追加 Cloudflare SSH CA 公钥
#   --login-user <username>        直接补充 Linux 用户，可重复；也支持逗号分隔
#   --login-users <user,...>       多个 Linux 用户
#   --allow-all-principals         允许任意 Access principal 登录指定用户
#   --dry-run                      只打印将要执行的操作
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step() { echo -e "\n${CYAN}===> $*${NC}"; }

SSHD_CONFIG="/etc/ssh/sshd_config"
CA_PUB_FILE="/etc/ssh/ca.pub"
BACKUP_SUFFIX="bak.$(date +%Y%m%d_%H%M%S)"

CA_PUBKEY=""
SSO_EMAILS=()
LOGIN_USERS=()
ALLOW_ALL_PRINCIPALS=false
DRY_RUN=false

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

trim_value() {
  echo "$1" | xargs
}

add_unique_sso_email() {
  local email
  email="$(trim_value "$1")"
  [[ -z "$email" ]] && return 0
  local existing
  for existing in "${SSO_EMAILS[@]}"; do
    [[ "$existing" == "$email" ]] && return 0
  done
  SSO_EMAILS+=("$email")
}

add_unique_login_user() {
  local user
  user="$(trim_value "$1")"
  [[ -z "$user" ]] && return 0
  local existing
  for existing in "${LOGIN_USERS[@]}"; do
    [[ "$existing" == "$user" ]] && return 0
  done
  LOGIN_USERS+=("$user")
}

add_sso_emails() {
  local raw="$1"
  raw="${raw//$'\n'/,}"
  raw="${raw//;/,}"
  raw="${raw//，/,}"
  raw="${raw//,/ }"
  local item
  for item in $raw; do
    add_unique_sso_email "$item"
  done
}

add_login_users() {
  local raw="$1"
  raw="${raw//$'\n'/,}"
  raw="${raw//;/,}"
  raw="${raw//，/,}"
  raw="${raw//,/ }"
  local item
  for item in $raw; do
    add_unique_login_user "$item"
  done
}

derive_login_users_from_sso() {
  local email user
  for email in "${SSO_EMAILS[@]}"; do
    user="${email%%@*}"
    add_unique_login_user "$user"
    info "从邮箱 '$email' 提取的登录用户名: $user"
  done
}

has_login_user() {
  local target="$1"
  local user
  for user in "${LOGIN_USERS[@]}"; do
    [[ "$user" == "$target" ]] && return 0
  done
  return 1
}

join_values() {
  local result=""
  local item
  for item in "$@"; do
    if [[ -z "$result" ]]; then
      result="$item"
    else
      result="$result, $item"
    fi
  done
  echo "$result"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ca-pubkey) CA_PUBKEY="$2"; shift 2 ;;
    --sso-email|--sso-emails) add_sso_emails "$2"; shift 2 ;;
    --login-user|--login-users) add_login_users "$2"; shift 2 ;;
    --allow-all-principals) ALLOW_ALL_PRINCIPALS=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      awk '/^# =====/{ if(n++) exit } n{ sub(/^# ?/,""); print }' "$0"
      exit 0
      ;;
    *) err "未知参数: $1"; exit 1 ;;
  esac
done

check_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请使用 root 或 sudo 执行此脚本"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    err "无法检测操作系统，此脚本仅支持 Ubuntu/Debian"
    exit 1
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  case "$ID" in
    ubuntu|debian) info "检测到系统: $PRETTY_NAME" ;;
    *) err "此脚本仅支持 Ubuntu/Debian，当前系统: $ID"; exit 1 ;;
  esac
}

prompt_missing_params() {
  if [[ ${#LOGIN_USERS[@]} -eq 0 && ${#SSO_EMAILS[@]} -eq 0 ]]; then
    if is_interactive; then
      local sso_input=""
      echo ""
      echo "Cloudflare 浏览器 SSH 使用 SSO 邮箱前缀作为 Linux 用户名。"
      read -rp "请输入要补充的 SSO 邮箱（多个用逗号分隔）: " sso_input
      add_sso_emails "$sso_input"
    else
      err "非交互模式必须提供至少一个 --sso-email 或 --login-user"
      exit 1
    fi
  fi

  derive_login_users_from_sso

  if [[ ${#LOGIN_USERS[@]} -eq 0 ]]; then
    err "未解析到任何 Linux 登录用户"
    exit 1
  fi

  if has_login_user "root"; then
    ALLOW_ALL_PRINCIPALS=true
  fi
}

prepare_ca_pubkey() {
  if [[ -n "$CA_PUBKEY" && -f "$CA_PUBKEY" ]]; then
    info "从文件读取 CA 公钥: $CA_PUBKEY"
    CA_PUBKEY="$(cat "$CA_PUBKEY")"
  fi

  if [[ -n "$CA_PUBKEY" ]]; then
    if [[ ! "$CA_PUBKEY" =~ ^(ecdsa-sha2-nistp256|ssh-rsa|ssh-ed25519)[[:space:]] ]]; then
      err "CA 公钥格式不正确，应以 ecdsa-sha2-nistp256 / ssh-rsa / ssh-ed25519 开头"
      exit 1
    fi
    return 0
  fi

  if [[ ! -f "$CA_PUB_FILE" ]]; then
    err "未找到 $CA_PUB_FILE。请传入 --ca-pubkey，或先运行完整安装脚本。"
    exit 1
  fi
}

write_ca_pubkey() {
  [[ -z "$CA_PUBKEY" ]] && return 0

  step "写入 Cloudflare CA 公钥 → $CA_PUB_FILE"
  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] 将写入 CA 公钥到 $CA_PUB_FILE"
    return 0
  fi

  if [[ -f "$CA_PUB_FILE" ]] && grep -qF "$CA_PUBKEY" "$CA_PUB_FILE" 2>/dev/null; then
    info "CA 公钥已存在于 $CA_PUB_FILE（跳过）"
    return 0
  fi

  if [[ -f "$CA_PUB_FILE" ]]; then
    echo "$CA_PUBKEY" >> "$CA_PUB_FILE"
  else
    echo "$CA_PUBKEY" > "$CA_PUB_FILE"
  fi
  chmod 644 "$CA_PUB_FILE"
  info "CA 公钥已写入"
}

create_login_user() {
  local user="$1"
  if [[ "$user" == "root" ]]; then
    return 0
  fi

  step "检查 Linux 用户: $user"
  if id "$user" &>/dev/null; then
    info "用户 '$user' 已存在"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] 将创建用户 '$user' 并加入 sudo 组"
    return 0
  fi

  local badname_flag="--allow-bad-names"
  if adduser --help 2>&1 | grep -q 'force-badname'; then
    badname_flag="--force-badname"
  fi

  adduser --disabled-password --gecos "" "$badname_flag" "$user"

  local sudoers_file="/etc/sudoers.d/${user//[^a-zA-Z0-9_-]/-}"
  echo "$user ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
  chmod 440 "$sudoers_file"
  info "用户 '$user' 已创建，免密 sudo 已配置"
}

configure_principals() {
  local user="$1"
  local marker="# --- Cloudflare Access short-lived cert: $user ---"

  if grep -qF "$marker" "$SSHD_CONFIG" 2>/dev/null; then
    info "AuthorizedPrincipalsCommand（$user）已配置（跳过）"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] 将为 $user 添加 AuthorizedPrincipalsCommand"
    return 0
  fi

  warn "将允许任意通过 Cloudflare Access 认证的用户以 '$user' 身份登录"
  warn "请确保 Access Policy 已正确限制可访问人员"

  cat >> "$SSHD_CONFIG" << EOF

$marker
Match User $user
  AuthorizedPrincipalsCommand /bin/bash -c "echo '%t %k' | ssh-keygen -L -f - | grep -A1 Principals"
  AuthorizedPrincipalsCommandUser nobody
EOF

  info "已添加 AuthorizedPrincipalsCommand（$user）"
}

ensure_root_login() {
  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] 将确保 PermitRootLogin 允许证书登录"
    return 0
  fi

  if grep -qE '^\s*PermitRootLogin\s+(no|forced-commands-only)\b' "$SSHD_CONFIG"; then
    sed -i 's/^\s*PermitRootLogin\s.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
    info "已修改 PermitRootLogin → prohibit-password"
  elif grep -qE '^\s*PermitRootLogin\s' "$SSHD_CONFIG"; then
    info "PermitRootLogin 当前设置允许公钥登录"
  else
    echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
    info "已添加 PermitRootLogin prohibit-password"
  fi
}

configure_sshd() {
  step "检查 sshd 配置"

  if [[ ! -f "$SSHD_CONFIG" ]]; then
    err "$SSHD_CONFIG 不存在"
    exit 1
  fi

  local backup="${SSHD_CONFIG}.${BACKUP_SUFFIX}"
  if [[ "$DRY_RUN" != true ]]; then
    cp "$SSHD_CONFIG" "$backup"
    info "已备份: $backup"
  fi

  local ca_directive="TrustedUserCAKeys $CA_PUB_FILE"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] 将确保 PubkeyAuthentication yes"
    info "[DRY-RUN] 将确保 $ca_directive"
  else
    if grep -qE '^\s*PubkeyAuthentication\s' "$SSHD_CONFIG"; then
      sed -i 's/^\s*PubkeyAuthentication\s.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
    else
      sed -i '1i PubkeyAuthentication yes' "$SSHD_CONFIG"
    fi

    if grep -qE '^\s*TrustedUserCAKeys\s' "$SSHD_CONFIG"; then
      sed -i "s|^\s*TrustedUserCAKeys\s.*|$ca_directive|" "$SSHD_CONFIG"
    else
      sed -i "/^PubkeyAuthentication/a $ca_directive" "$SSHD_CONFIG"
    fi
  fi

  if [[ "$ALLOW_ALL_PRINCIPALS" == true ]]; then
    local user
    for user in "${LOGIN_USERS[@]}"; do
      configure_principals "$user"
    done
  fi

  if has_login_user "root"; then
    ensure_root_login
  fi

  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi

  step "校验 sshd 配置"
  if sshd -t 2>&1; then
    info "sshd -t 校验通过"
  else
    err "sshd -t 校验失败，正在回滚"
    cp "$backup" "$SSHD_CONFIG"
    exit 1
  fi

  step "重新加载 SSH 服务"
  if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
    info "SSH 服务已 reload"
  else
    service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || {
      err "SSH 服务 reload 失败，请手动执行: systemctl reload ssh"
      exit 1
    }
  fi
}

main() {
  echo ""
  echo -e "${CYAN}Cloudflare Browser SSH 多用户修复脚本${NC}"
  echo ""

  check_root
  check_os
  prompt_missing_params
  prepare_ca_pubkey

  info "将补充 Linux 用户: $(join_values "${LOGIN_USERS[@]}")"
  if [[ ${#SSO_EMAILS[@]} -gt 0 ]]; then
    info "对应 SSO 邮箱: $(join_values "${SSO_EMAILS[@]}")"
  fi

  write_ca_pubkey

  local user
  for user in "${LOGIN_USERS[@]}"; do
    create_login_user "$user"
  done

  configure_sshd

  echo ""
  echo -e "${GREEN}完成：已补充 ${#LOGIN_USERS[@]} 个用户。${NC}"
  echo "浏览器 SSH 仍由 Cloudflare Access Policy 控制可访问人员。"
}

main "$@"
