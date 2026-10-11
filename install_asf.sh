#!/bin/bash
###############################################################################
#  ArchiSteamFarm 一键安装脚本（增强版）
#
#  支持功能：
#    - 自动检测并安装依赖
#    - 自动获取最新 ASF 版本
#    - 自定义安装目录 / 运行用户 / IPC 端口
#    - 生成 ASF.json 与 IPC.config
#    - 生成 systemd 服务单元
#    - 自动修正目录权限
#    - 可选择是否立即启动
#
#  用法：
#    sudo bash install_asf.sh
#    sudo INSTALL_DIR=/opt/asf2 bash install_asf.sh
#    sudo ASF_USER=steam bash install_asf.sh
#    sudo ASF_PORT=1243 bash install_asf.sh
#    sudo ASF_VERSION=6.3.10.3 bash install_asf.sh
###############################################################################

set -Eeuo pipefail

# ============================== 可配置变量 ====================================
INSTALL_DIR="${INSTALL_DIR:-/opt/asf}"
ASF_USER="${ASF_USER:-root}"
ASF_PORT="${ASF_PORT:-1242}"
ASF_VERSION="${ASF_VERSION:-}"

# ================================ 颜色输��� ====================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ================================ 环境检查 ====================================
check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        log_error "请使用 root 权限运行： sudo bash $0"
        exit 1
    fi
}

check_os() {
    if ! command -v apt-get >/dev/null 2>&1; then
        log_error "此脚本仅支持 Ubuntu / Debian 系统"
        exit 1
    fi
}

ensure_user() {
    if [[ "${ASF_USER}" != "root" ]]; then
        if ! id -u "${ASF_USER}" >/dev/null 2>&1; then
            log_warn "用户 ${ASF_USER} 不存在，正在创建..."
            useradd -m -s /bin/bash "${ASF_USER}"
        fi
    fi
}

get_latest_version() {
    log_info "正在检测最新版 ASF..."
    local latest=""
    
    # 尝试用 curl
    if command -v curl >/dev/null 2>&1; then
        latest=$(curl -fsSL "https://api.github.com/repos/JustArchiNET/ArchiSteamFarm/releases/latest" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+' | head -1) || latest=""
    fi
    
    # 如果 curl 失败，尝试 wget
    if [[ -z "${latest}" ]] && command -v wget >/dev/null 2>&1; then
        latest=$(wget -qO- "https://api.github.com/repos/JustArchiNET/ArchiSteamFarm/releases/latest" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+' | head -1) || latest=""
    fi
    
    if [[ -z "${latest}" ]]; then
        log_error "无法获取最新版 ASF，请检查网络或手动指定 ASF_VERSION"
        log_info "示例： sudo ASF_VERSION=6.3.10.3 bash $0"
        exit 1
    fi

    echo "${latest#v}"
}

# ================================ 安装步骤 ====================================
step_install_deps() {
    log_info "安装依赖..."
    apt-get update -qq
    apt-get install -y -qq wget curl unzip openssl ca-certificates
    log_ok "依赖安装完成"
}

step_download() {
    local version="$1"
    local file_name="ASF-linux-x64.zip"
    local url="https://github.com/JustArchiNET/ArchiSteamFarm/releases/download/${version}/${file_name}"

    log_info "下载 ASF v${version}..."

    mkdir -p "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"

    if ! wget -q --show-progress --tries=3 --timeout=30 -O "${file_name}" "${url}"; then
        log_error "下载失败，请检查网络或版本是否正确"
        log_error "URL: ${url}"
        rm -f "${file_name}"
        exit 1
    fi

    log_ok "下载完成"
}

step_extract() {
    log_info "解压 ASF..."
    cd "${INSTALL_DIR}"
    
    if ! unzip -qo "ASF-linux-x64.zip"; then
        log_error "解压失败"
        exit 1
    fi
    
    rm -f "ASF-linux-x64.zip"
    
    if ! chmod +x "ArchiSteamFarm"; then
        log_error "修改权限失败"
        exit 1
    fi
    
    log_ok "解压完成"
}

step_create_config() {
    log_info "生成 ASF 配置..."

    local ipc_password
    ipc_password="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)"

    mkdir -p "${INSTALL_DIR}/config"

    cat > "${INSTALL_DIR}/config/IPC.config" <<EOF
{
  "Kestrel": {
    "Endpoints": {
      "HTTP": {
        "Url": "http://*:${ASF_PORT}"
      }
    }
  }
}
EOF

    cat > "${INSTALL_DIR}/config/ASF.json" <<EOF
{
  "Headless": true,
  "WebServer": true,
  "IP": "0.0.0.0",
  "Port": ${ASF_PORT},
  "IPCPassword": "${ipc_password}"
}
EOF

    echo "${ipc_password}" > "${INSTALL_DIR}/.ipc_password"
    chmod 600 "${INSTALL_DIR}/.ipc_password"
    
    log_ok "配置生成完成"
    log_info "IPC 密码已保存到 ${INSTALL_DIR}/.ipc_password"
}

step_create_service() {
    log_info "注册 systemd 服务..."

    cat > /etc/systemd/system/asf.service <<EOF
[Unit]
Description=ArchiSteamFarm Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ASF_USER}
Group=${ASF_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/ArchiSteamFarm
Restart=on-failure
RestartSec=5
KillMode=process
TimeoutSec=300

# 安全加固
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable asf.service
    log_ok "systemd 服务注册完成"
}

step_fix_permissions() {
    if [[ "${ASF_USER}" != "root" ]]; then
        log_info "修正目录权限..."
        chown -R "${ASF_USER}:${ASF_USER}" "${INSTALL_DIR}"
        log_ok "权限修正完成"
    fi
}

print_summary() {
    local ipc_password
    ipc_password="$(cat "${INSTALL_DIR}/.ipc_password")"

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}ArchiSteamFarm 安装成功！${NC}"
    echo "============================================================"
    echo ""
    echo "  版本:        ASF v${ASF_VERSION}"
    echo "  安装目录:    ${INSTALL_DIR}"
    echo "  运行用户:    ${ASF_USER}"
    echo "  IPC 端口:    ${ASF_PORT}"
    echo "  IPC 密码:    ${ipc_password}"
    echo ""
    echo "------------------------------------------------------------"
    echo "  管理命令："
    echo "    启动:    sudo systemctl start asf"
    echo "    停止:    sudo systemctl stop asf"
    echo "    重启:    sudo systemctl restart asf"
    echo "    状态:    sudo systemctl status asf"
    echo "    日志:    sudo journalctl -u asf -f"
    echo "------------------------------------------------------------"
    echo "  Web 地址: http://<服务器IP>:${ASF_PORT}"
    echo "  请将 <服务器IP> 替换为你的实际地址"
    echo "------------------------------------------------------------"
    echo ""
    echo -e "  ${YELLOW}⚠️  请妥善保管 IPC 密码！${NC}"
    echo -e "  ${YELLOW}⚠️  首次使用请登录 Web 界面配置机器人账号！${NC}"
    echo ""
}

main() {
    echo ""
    echo "============================================================"
    echo "       ArchiSteamFarm 一键安装脚本（增强版）"
    echo "============================================================"
    echo ""

    check_root
    check_os
    ensure_user

    # 获取版本（仅在未指定时执行）
    if [[ -z "${ASF_VERSION}" ]]; then
        ASF_VERSION="$(get_latest_version)"
    fi

    log_info "目标版本: v${ASF_VERSION}"
    log_info "安装目录: ${INSTALL_DIR}"
    log_info "运行用户: ${ASF_USER}"
    log_info "IPC 端口: ${ASF_PORT}"
    echo ""

    step_install_deps
    echo ""
    step_download "${ASF_VERSION}"
    echo ""
    step_extract
    echo ""
    step_create_config
    echo ""
    step_create_service
    echo ""
    step_fix_permissions
    echo ""
    print_summary

    log_info "是否立即启动 ASF 服务？[y/N]"
    read -r -t 10 -p "  > " start_now || start_now="n"
    if [[ "${start_now}" =~ ^[Yy]$ ]]; then
        systemctl start asf
        log_ok "ASF 服务已启动"
        log_info "查看日志: sudo journalctl -u asf -f"
    else
        log_info "已完成安装，稍后可执行： sudo systemctl start asf"
    fi
}

main "$@"
