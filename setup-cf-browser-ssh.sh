#!/usr/bin/env bash
# =============================================================================
# setup-cf-browser-ssh.sh
# Cloudflare Browser-rendered SSH + Short-lived Certificate 服务器端一键配置
# 支持系统：Ubuntu / Debian
#
# 功能：
#   1. 安装 cloudflared（如未安装）
#   2. 可选：用 Tunnel Token 注册 cloudflared 系统服务
#   3. 写入 Cloudflare CA 公钥到 /etc/ssh/ca.pub
#   4. 配置 sshd_config 信任 Cloudflare CA
#   5. 配置用户名映射（支持 root 共享登录）
#   6. 安装本机 metrics 监控探针
#   7. 校验 sshd 配置并 reload
#
# 用法：
#   交互式（推荐）：
#     sudo bash setup-cf-browser-ssh.sh
#
#   非交互式（全部参数传入）：
#     sudo bash setup-cf-browser-ssh.sh \
#       --ca-pubkey "ecdsa-sha2-nistp256 AAAA... open-ssh-ca@cloudflareaccess.org" \
#       --sso-email admin@example.com \
#       --tunnel-token "eyJhIjoiNz..."
#
# 选项：
#   --ca-pubkey <string|filepath>  Cloudflare short-lived CA 公钥（内容或文件路径）
#   --sso-email <email>            Cloudflare SSO 登录邮箱（用于提取用户名）
#   --login-user <username>        浏览器终端登录的 Linux 用户（默认：root）
#   --tunnel-token <token>         cloudflared Tunnel Token（可选，不传则跳过服务注册）
#   --skip-cloudflared             跳过 cloudflared 安装
#   --metrics-port <port>          metrics 监听端口（默认：9101）
#   --allow-all-principals         允许任意 Access 用户登录 --login-user（默认开启 root 时自动启用）
#   --dry-run                      只打印将要执行的操作，不实际修改
#   -h, --help                     显示帮助
#
# 回滚：
#   脚本会在修改前备份 sshd_config，备份文件名如 sshd_config.bak.20260412_120000
#   如果 sshd -t 校验失败，脚本会自动还原备份并拒绝 reload。
# =============================================================================
set -euo pipefail

# ----- 颜色输出 -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}===> $*${NC}"; }

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

# ----- 默认值 -----
CA_PUBKEY="ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBNaOWfUfFLTlHn0EwdTk1Qs0gljISZ4o1ycKO/Aw9ZvzKmY16pFJ5Tg1ktXpR0t6s/CFIOCkPG9v9ZxiJ0yC83s= open-ssh-ca@cloudflareaccess.org"
SSO_EMAIL="aizfun.top@foxmail.com"
LOGIN_USER=""
TUNNEL_TOKEN=""
METRICS_PORT="${METRICS_PORT:-9101}"
SKIP_CLOUDFLARED=false
ALLOW_ALL_PRINCIPALS=false
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 从完整命令或纯 token 中提取 tunnel token
# 支持输入: "sudo cloudflared service install eyJ..." 或直接 "eyJ..."
extract_tunnel_token() {
  local input="$1"
  # 去掉首尾空白
  input="$(echo "$input" | xargs)"
  # 如果包含 "install"，取最后一个参数作为 token
  if [[ "$input" == *"install "* ]]; then
    input="${input##*install }"
    input="$(echo "$input" | awk '{print $1}')"
  fi
  echo "$input"
}

SSHD_CONFIG="/etc/ssh/sshd_config"
CA_PUB_FILE="/etc/ssh/ca.pub"
BACKUP_SUFFIX="bak.$(date +%Y%m%d_%H%M%S)"

# ----- 参数解析 -----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ca-pubkey)          CA_PUBKEY="$2";            shift 2 ;;
    --sso-email)          SSO_EMAIL="$2";            shift 2 ;;
    --login-user)         LOGIN_USER="$2";           shift 2 ;;
    --tunnel-token)       TUNNEL_TOKEN="$(extract_tunnel_token "$2")"; shift 2 ;;
    --skip-cloudflared)   SKIP_CLOUDFLARED=true;     shift   ;;
    --metrics-port)       METRICS_PORT="$2";         shift 2 ;;
    --allow-all-principals) ALLOW_ALL_PRINCIPALS=true; shift ;;
    --dry-run)            DRY_RUN=true;              shift   ;;
    -h|--help)
      awk '/^# =====/{ if(n++) exit } n{ sub(/^# ?/,""); print }' "$0"
      exit 0
      ;;
    *) err "未知参数: $1"; exit 1 ;;
  esac
done

if [[ ! "$METRICS_PORT" =~ ^[0-9]+$ ]] || (( METRICS_PORT < 1 || METRICS_PORT > 65535 )); then
  err "--metrics-port 必须是 1-65535 的数字"
  exit 1
fi

# ----- 前置检查 -----
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
    *)
      err "此脚本仅支持 Ubuntu/Debian，当前系统: $ID"
      exit 1
      ;;
  esac
}

# ----- 交互式收集缺失参数 -----
prompt_missing_params() {
  # CA 公钥
  if [[ -z "$CA_PUBKEY" ]]; then
    echo ""
    warn "未提供 Cloudflare CA 公钥。"
    echo "  获取方式：Cloudflare One → Access controls → Service credentials → SSH"
    echo "  → 选择对应 Application → 复制 CA public key"
    echo ""
    read -rp "请粘贴 CA 公钥（一行，以 ecdsa-sha2 或 ssh-rsa 开头），或输入本地文件路径: " CA_PUBKEY
  fi

  # 如果是文件路径，读取内容
  if [[ -f "$CA_PUBKEY" ]]; then
    info "从文件读取 CA 公钥: $CA_PUBKEY"
    CA_PUBKEY="$(cat "$CA_PUBKEY")"
  fi

  # 校验公钥格式
  if [[ ! "$CA_PUBKEY" =~ ^(ecdsa-sha2-nistp256|ssh-rsa|ssh-ed25519)[[:space:]] ]]; then
    err "CA 公钥格式不正确，应以 ecdsa-sha2-nistp256 / ssh-rsa / ssh-ed25519 开头"
    exit 1
  fi

  # SSO 邮箱 → 登录用户名
  if [[ -z "$LOGIN_USER" ]]; then
    if [[ -z "$SSO_EMAIL" ]]; then
      echo ""
      echo -e "  ${YELLOW}⚠️  重要：Cloudflare 浏览器 SSH 强制使用 SSO 邮箱前缀作为用户名${NC}"
      echo "  例如：admin@moe.tips → 用户名自动变为 admin"
      echo "  你无法在浏览器终端里选择用户名，它由邮箱前缀决定。"
      echo ""
      read -rp "请输入你的 Cloudflare SSO 登录邮箱: " SSO_EMAIL
    fi
    if [[ -n "$SSO_EMAIL" ]]; then
      LOGIN_USER="${SSO_EMAIL%%@*}"
      info "从邮箱 '$SSO_EMAIL' 提取的登录用户名: $LOGIN_USER"
    else
      LOGIN_USER="root"
      warn "未提供邮箱，默认使用 root（仅当你的邮箱前缀是 root 时才有效）"
    fi
  fi

  # root 模式自动启用 allow-all-principals
  if [[ "$LOGIN_USER" == "root" ]]; then
    ALLOW_ALL_PRINCIPALS=true
  fi

  # Tunnel Token
  if [[ -z "$TUNNEL_TOKEN" && "$SKIP_CLOUDFLARED" != true ]]; then
    echo ""
    echo -e "  ${CYAN}Tunnel Token 获取方式：${NC}"
    echo "  Cloudflare One → Networks → Tunnels → 选择/创建 Tunnel → Install connector"
    echo ""
    echo "  直接把控制台给你的整条命令粘贴进来，脚本会自动提取 Token："
    echo -e "  ${GREEN}sudo cloudflared service install eyJhIjoiZDZjN2MwNT...${NC}"
    echo ""
    echo "  （也可以只粘贴 eyJ... Token 部分；留空则跳过隧道服务注册）"
    echo ""
    read -rp "请粘贴命令或 Token: " TUNNEL_TOKEN_RAW
    TUNNEL_TOKEN="$(extract_tunnel_token "$TUNNEL_TOKEN_RAW")"
  fi
}

# ----- 安装 cloudflared -----
install_cloudflared() {
  step "安装 cloudflared"

  if command -v cloudflared &>/dev/null; then
    local ver
    ver=$(cloudflared --version 2>&1 | head -1)
    info "cloudflared 已安装: $ver（跳过安装）"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] 将安装 cloudflared（apt 方式）"
    return 0
  fi

  info "添加 Cloudflare GPG key 和 apt 源..."
  mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
    | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

  info "正在安装 cloudflared（全程无交互）..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq cloudflared

  if command -v cloudflared &>/dev/null; then
    info "cloudflared 安装成功: $(cloudflared --version 2>&1 | head -1)"
  else
    err "cloudflared 安装失败"
    exit 1
  fi
}

# ----- 注册 cloudflared 系统服务 -----
register_cloudflared_service() {
  step "注册 cloudflared 系统服务"

  if [[ -z "$TUNNEL_TOKEN" ]]; then
    warn "未提供 Tunnel Token，跳过服务注册"
    echo ""
    echo "  后续手动注册命令："
    echo "    sudo cloudflared service install <YOUR_TUNNEL_TOKEN>"
    echo ""
    return 0
  fi

  if systemctl is-active --quiet cloudflared 2>/dev/null; then
    info "cloudflared 服务已在运行（跳过）"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] 将执行: cloudflared service install <TOKEN>"
    return 0
  fi

  info "执行 cloudflared service install ..."
  cloudflared service install "$TUNNEL_TOKEN"

  if systemctl is-active --quiet cloudflared 2>/dev/null; then
    info "cloudflared 服务已启动"
  else
    warn "cloudflared 服务注册完成但未自动启动，尝试启动..."
    systemctl start cloudflared
    systemctl enable cloudflared
  fi
}

# ----- 写入 CA 公钥 -----
write_ca_pubkey() {
  step "写入 Cloudflare CA 公钥 → $CA_PUB_FILE"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] 将写入 CA 公钥到 $CA_PUB_FILE"
    return 0
  fi

  # 幂等：检查是否已包含相同公钥
  if [[ -f "$CA_PUB_FILE" ]]; then
    if grep -qF "$CA_PUBKEY" "$CA_PUB_FILE" 2>/dev/null; then
      info "CA 公钥已存在于 $CA_PUB_FILE（跳过）"
      return 0
    fi
    # 文件存在但内容不同，追加
    info "$CA_PUB_FILE 已存在，追加新公钥"
    echo "$CA_PUBKEY" >> "$CA_PUB_FILE"
  else
    echo "$CA_PUBKEY" > "$CA_PUB_FILE"
  fi

  chmod 644 "$CA_PUB_FILE"
  info "CA 公钥已写入"
}

# ----- 配置 sshd_config -----
configure_sshd() {
  step "配置 $SSHD_CONFIG"

  if [[ ! -f "$SSHD_CONFIG" ]]; then
    err "$SSHD_CONFIG 不存在"
    exit 1
  fi

  # 备份
  local backup="${SSHD_CONFIG}.${BACKUP_SUFFIX}"
  cp "$SSHD_CONFIG" "$backup"
  info "已备份: $backup"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] 将修改 $SSHD_CONFIG"
    info "[DRY-RUN]   PubkeyAuthentication yes"
    info "[DRY-RUN]   TrustedUserCAKeys $CA_PUB_FILE"
    if [[ "$ALLOW_ALL_PRINCIPALS" == true ]]; then
      info "[DRY-RUN]   AuthorizedPrincipalsCommand (allow all for $LOGIN_USER)"
    fi
    return 0
  fi

  local changed=false

  # --- PubkeyAuthentication yes ---
  if grep -qE '^\s*PubkeyAuthentication\s' "$SSHD_CONFIG"; then
    # 如果存在但不是 yes，替换
    if ! grep -qE '^\s*PubkeyAuthentication\s+yes' "$SSHD_CONFIG"; then
      sed -i 's/^\s*PubkeyAuthentication\s.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
      info "已修改 PubkeyAuthentication → yes"
      changed=true
    else
      info "PubkeyAuthentication yes 已存在"
    fi
  else
    # 不存在，添加到文件顶部（跳过注释）
    sed -i '1i PubkeyAuthentication yes' "$SSHD_CONFIG"
    info "已添加 PubkeyAuthentication yes"
    changed=true
  fi

  # --- TrustedUserCAKeys ---
  local ca_directive="TrustedUserCAKeys $CA_PUB_FILE"
  if grep -qE '^\s*TrustedUserCAKeys\s' "$SSHD_CONFIG"; then
    if ! grep -qF "$ca_directive" "$SSHD_CONFIG"; then
      sed -i "s|^\s*TrustedUserCAKeys\s.*|$ca_directive|" "$SSHD_CONFIG"
      info "已修改 TrustedUserCAKeys → $CA_PUB_FILE"
      changed=true
    else
      info "TrustedUserCAKeys 已正确配置"
    fi
  else
    # 添加到 PubkeyAuthentication 之后
    sed -i "/^PubkeyAuthentication/a $ca_directive" "$SSHD_CONFIG"
    info "已添加 $ca_directive"
    changed=true
  fi

  # --- 用户名映射（root / 共享账号模式）---
  if [[ "$ALLOW_ALL_PRINCIPALS" == true ]]; then
    configure_principals "$LOGIN_USER"
  fi

  # --- 确保 PermitRootLogin 允许公钥登录（仅 root 模式）---
  if [[ "$LOGIN_USER" == "root" ]]; then
    ensure_root_login
  fi

  if [[ "$changed" == true ]]; then
    info "sshd_config 已修改"
  else
    info "sshd_config 无需修改"
  fi

  # --- 校验 ---
  validate_and_reload "$backup"
}

# 配置 AuthorizedPrincipalsCommand，让任意 Access 用户都可以登录指定用户
configure_principals() {
  local user="$1"

  # 标记行，用于幂等检查
  local marker="# --- Cloudflare Access short-lived cert: $user ---"

  if grep -qF "$marker" "$SSHD_CONFIG" 2>/dev/null; then
    info "AuthorizedPrincipalsCommand（$user）已配置（跳过）"
    return 0
  fi

  warn "⚠️  将允许任意通过 Cloudflare Access 认证的用户以 '$user' 身份登录"
  warn "⚠️  请确保你的 Access Policy 已正确限制可访问人员！"

  # 对于 root，使用全局 AuthorizedPrincipalsCommand
  # 对于其他用户，使用 Match User 块
  if [[ "$user" == "root" ]]; then
    cat >> "$SSHD_CONFIG" << EOF

$marker
# 允许任意 Cloudflare Access 短期证书用户以 root 登录
# 安全性完全依赖 Cloudflare Access Policy，请务必正确配置！
Match User root
  AuthorizedPrincipalsCommand /bin/bash -c "echo '%t %k' | ssh-keygen -L -f - | grep -A1 Principals"
  AuthorizedPrincipalsCommandUser nobody
EOF
  else
    cat >> "$SSHD_CONFIG" << EOF

$marker
Match User $user
  AuthorizedPrincipalsCommand /bin/bash -c "echo '%t %k' | ssh-keygen -L -f - | grep -A1 Principals"
  AuthorizedPrincipalsCommandUser nobody
EOF
  fi

  info "已添加 AuthorizedPrincipalsCommand（$user）"
}

# 确保 root 可以通过公钥登录
ensure_root_login() {
  # PermitRootLogin 需要为 yes 或 prohibit-password 或 without-password
  if grep -qE '^\s*PermitRootLogin\s+(no|forced-commands-only)\b' "$SSHD_CONFIG"; then
    sed -i 's/^\s*PermitRootLogin\s.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
    info "已修改 PermitRootLogin → prohibit-password（允许证书登录，禁止密码）"
  elif grep -qE '^\s*PermitRootLogin\s' "$SSHD_CONFIG"; then
    info "PermitRootLogin 当前设置允许公钥登录"
  else
    echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
    info "已添加 PermitRootLogin prohibit-password"
  fi
}

# ----- 校验并 reload -----
validate_and_reload() {
  local backup="$1"

  step "校验 sshd 配置"

  if sshd -t 2>&1; then
    info "sshd -t 校验通过 ✓"
  else
    err "sshd -t 校验失败！正在回滚..."
    cp "$backup" "$SSHD_CONFIG"
    info "已回滚到备份: $backup"
    err "请手动检查 $SSHD_CONFIG 后重试"
    exit 1
  fi

  step "重新加载 SSH 服务"
  if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
    info "SSH 服务已 reload ✓"
  else
    warn "systemctl reload 失败，尝试 service ssh reload..."
    service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || {
      err "SSH 服务 reload 失败，请手动执行: systemctl reload ssh"
      exit 1
    }
  fi
}

# ----- 创建登录用户（如不存在） -----
create_login_user() {
  local user="$1"

  # root 不需要创建
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

  info "创建用户 '$user'（无密码，仅证书登录）..."
  # 新版 adduser 用 --allow-bad-names，旧版用 --force-badname
  local badname_flag="--allow-bad-names"
  if adduser --help 2>&1 | grep -q 'force-badname'; then
    badname_flag="--force-badname"
  fi
  adduser --disabled-password --gecos "" "$badname_flag" "$user"

  # 配置免密 sudo（证书用户没有密码，普通 sudo 组会要求输入密码）
  local sudoers_file="/etc/sudoers.d/${user//[^a-zA-Z0-9_-]/-}"
  echo "$user ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
  chmod 440 "$sudoers_file"
  info "用户 '$user' 已创建，免密 sudo 已配置 ✓"
}

# ----- 打印后续手工步骤 -----
print_next_steps() {
  echo ""
  echo -e "${CYAN}============================================================${NC}"
  echo -e "${CYAN}  服务器端配置完成！以下是你需要在 Cloudflare 控制台完成的步骤：${NC}"
  echo -e "${CYAN}============================================================${NC}"
  echo ""
  echo "  1. 创建 / 确认 Self-hosted Application"
  echo "     → Cloudflare One → Access controls → Applications"
  echo "     → 添加 Self-hosted Application，域名指向你的 SSH 服务"
  echo ""
  echo "  2. 开启 Browser Rendering"
  echo "     → 在 Application 设置中，Browser rendering → 选择 SSH"
  echo ""
  echo "  3. 生成 Short-lived Certificate（如果你还没生成 CA 公钥）"
  echo "     → Access controls → Service credentials → SSH"
  echo "     → Add a certificate → 选择你的 Application → Generate"
  echo ""
  echo "  4. 配置 Access Policy"
  echo "     → 在 Application 中配置谁可以访问（邮箱、域名、组等）"
  echo ""
  echo "  5. 测试"
  echo "     → 浏览器访问你配置的域名"
  echo "     → 完成 SSO 登录后，应直接进入网页 SSH 终端"
  echo ""
  echo -e "  ${YELLOW}ℹ️  浏览器终端强制使用 SSO 邮箱前缀作为用户名${NC}"
  echo "     你必须用邮箱前缀为 '${LOGIN_USER}' 的账号登录 SSO"
  if [[ -n "$SSO_EMAIL" ]]; then
    echo "     即使用: ${SSO_EMAIL}"
  fi
  echo ""

  if [[ "$LOGIN_USER" == "root" ]]; then
    echo -e "  ${YELLOW}⚠️  重要提醒：${NC}"
    echo -e "  ${YELLOW}    你配置的是 root 登录模式。${NC}"
    echo -e "  ${YELLOW}    只有邮箱前缀为 'root' 的 SSO 账号才能通过浏览器 SSH 登录！${NC}"
    echo -e "  ${YELLOW}    服务器安全性完全依赖 Access Policy，确保只允许受信任的用户访问！${NC}"
    echo ""
  else
    echo -e "  ${GREEN}✅  服务器已配置用户 '${LOGIN_USER}'（带 sudo 权限）${NC}"
    echo "     登录后可用 sudo -i 获取 root shell"
    echo ""
  fi

  if [[ -z "$TUNNEL_TOKEN" && "$SKIP_CLOUDFLARED" != true ]]; then
    echo "  ⓘ  cloudflared 已安装但 Tunnel 服务未注册。"
    echo "     如需注册，请在控制台获取 Token 后执行："
    echo "       sudo cloudflared service install <YOUR_TUNNEL_TOKEN>"
    echo ""
  fi

  echo -e "${GREEN}  配置文件位置：${NC}"
  echo "    CA 公钥:     $CA_PUB_FILE"
  echo "    sshd_config: $SSHD_CONFIG"
  echo "    sshd 备份:   ${SSHD_CONFIG}.${BACKUP_SUFFIX}"
  echo "    metrics:     http://127.0.0.1:${METRICS_PORT}/metrics.json"
  echo ""
}

# ----- 安装 metrics agent -----
install_metrics_agent() {
  step "安装服务器监控探针 (metrics-agent)"

  if systemctl is-active --quiet ssh-metrics.service 2>/dev/null; then
    info "ssh-metrics.service 已在运行，将刷新配置并重启"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] 将安装 metrics-agent（端口 ${METRICS_PORT}）"
    return 0
  fi

  local script_url="https://raw.githubusercontent.com/chunzhimoe/cfbash/main/metrics-agent.sh"
  local agent_script=""
  local tmp_dir=""

  if [[ -f "$SCRIPT_DIR/metrics-agent.sh" ]]; then
    agent_script="$SCRIPT_DIR/metrics-agent.sh"
    info "使用本地 metrics-agent.sh 安装..."
  else
    tmp_dir="$(mktemp -d)"
    agent_script="$tmp_dir/metrics-agent.sh"
    info "下载 metrics-agent.sh..."
    curl -fsSL "$script_url" -o "$agent_script"

    if [[ -f "$SCRIPT_DIR/metrics_server.py" ]]; then
      cp "$SCRIPT_DIR/metrics_server.py" "$tmp_dir/metrics_server.py"
    fi
  fi

  METRICS_PORT="$METRICS_PORT" bash "$agent_script" install

  if [[ -n "$tmp_dir" ]]; then
    rm -rf "$tmp_dir"
  fi

  info "metrics-agent 已安装 ✓"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  Cloudflare Browser SSH + Short-lived Certificates Setup   ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  check_root
  check_os
  prompt_missing_params

  echo ""
  info "配置摘要："
  info "  SSO 邮箱:          ${SSO_EMAIL:-(未提供)}"
  info "  登录用户:          $LOGIN_USER"
  info "  允许任意 principal: $ALLOW_ALL_PRINCIPALS"
  info "  安装 cloudflared:  $( [[ "$SKIP_CLOUDFLARED" == true ]] && echo '跳过' || echo '是' )"
  info "  Tunnel Token:      $( [[ -n "$TUNNEL_TOKEN" ]] && echo '已提供' || echo '未提供' )"
  info "  Metrics 端口:      $METRICS_PORT"
  info "  Dry Run:           $DRY_RUN"
  echo ""

  if [[ "$DRY_RUN" != true ]]; then
    if is_interactive; then
      local confirm=""
      read -rp "确认以上配置并继续？[Y/n] " confirm
      if [[ "${confirm,,}" =~ ^n ]]; then
        info "已取消"
        exit 0
      fi
    else
      warn "检测到非交互模式，跳过确认提示并继续执行"
    fi
  fi

  # 1. cloudflared
  if [[ "$SKIP_CLOUDFLARED" != true ]]; then
    install_cloudflared
    register_cloudflared_service
  else
    info "跳过 cloudflared 安装（--skip-cloudflared）"
  fi

  # 2. CA 公钥
  write_ca_pubkey

  # 3. 创建登录用户
  create_login_user "$LOGIN_USER"

  # 4. sshd 配置
  configure_sshd

  # 5. metrics agent
  install_metrics_agent

  # 6. 后续步骤
  print_next_steps
}

main "$@"
