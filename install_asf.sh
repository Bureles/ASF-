#!/bin/bash
###############################################################################
#  ArchiSteamFarm 稳定版一键安装脚本 (Ubuntu / Debian)
#
#  说明：
#    - 固定下载 ASF 6.1.7.3 版本
#    - 不执行 GitHub API 检测，避免版本号异常或网络问题
#    - 支持自定义安装目录 / 端口 / 运行用户 / IPC 密码
#    - 自动生成 IPC / ASF 配置
#    - 自动注册 systemd 服务
#    - 支持安装 / 卸载 / 状态检查 / 启动 / 停止 / 重启
#    - 自动配置 UFW 防火墙（可选）
#
#  用法：
#    sudo bash install_asf.sh
#    sudo INSTALL_DIR=/opt/asf2 bash install_asf.sh
#    sudo ASF_USER=steam bash install_asf.sh
#    sudo ASF_PORT=1243 bash install_asf.sh
#    sudo ASF_PASSWORD=MyStrongPass123 bash install_asf.sh
#    sudo ASF_OPEN_FIREWALL=yes bash install_asf.sh
#    sudo bash install_asf.sh uninstall
#    sudo bash install_asf.sh status
#    sudo bash install_asf.sh start
#    sudo bash install_asf.sh stop
#    sudo bash install_asf.sh restart
###############################################################################

set -Eeuo pipefail

# ============================== 可配置变量 ====================================
INSTALL_DIR="${INSTALL_DIR:-/opt/asf}"
ASF_USER="${ASF_USER:-root}"
ASF_PORT="${ASF_PORT:-1242}"
ASF_VERSION="6.1.7.3"
ASF_PASSWORD="${ASF_PASSWORD:-}"
SERVICE_NAME="asf"
ASF_OPEN_FIREWALL="${ASF_OPEN_FIREWALL:-yes}"

# ================================ 颜色输出 ====================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ================================ 工具函数 ====================================
show_usage() {
    echo "Usage:"
    echo "  sudo bash install_asf.sh                 # 安装"
    echo "  sudo bash install_asf.sh uninstall       # 卸载"
    echo "  sudo bash install_asf.sh status          # 状态"
    echo "  sudo bash install_asf.sh start           # 启动"
    echo "  sudo bash install_asf.sh stop            # 停止"
    echo "  sudo bash install_asf.sh restart         # 重启"
    echo ""
    echo "环境变量:"
    echo "  INSTALL_DIR=/opt/asf"
    echo "  ASF_USER=root"
    echo "  ASF_PORT=1242"
    echo "  ASF_PASSWORD=MyStrongPass123"
    echo "  ASF_OPEN_FIREWALL=yes"
    exit 0
}

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

service_status() {
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        echo "running"
    else
        echo "stopped"
    fi
}

start_service() {
    systemctl start "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    systemctl is-active --quiet "${SERVICE_NAME}.service"
}

stop_service() {
    systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    ! systemctl is-active --quiet "${SERVICE_NAME}.service"
}

restart_service() {
    systemctl restart "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    systemctl is-active --quiet "${SERVICE_NAME}.service"
}

configure_firewall() {
    if [[ "${ASF_OPEN_FIREWALL}" != "yes" ]]; then
        return 0
    fi

    if command -v ufw >/dev/null 2>&1; then
        log_info "配置 UFW 防火墙，允许 ASF 端口 ${ASF_PORT}..."
        if ! ufw status | grep -q "Status: active"; then
            ufw --force enable >/dev/null 2>&1 || true
        fi
        ufw allow "${ASF_PORT}/tcp" >/dev/null 2>&1 || true
        log_ok "防火墙规则已添加：${ASF_PORT}/tcp"
    else
        log_warn "未检测到 ufw，跳过防火墙配置；可手动开放端口 ${ASF_PORT}"
    fi
}

# ================================ 卸载功能 ====================================
uninstall_asf() {
    log_warn "开始卸载 ArchiSteamFarm..."

    if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    fi

    if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    fi

    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload

    if [[ -d "${INSTALL_DIR}" ]]; then
        rm -rf "${INSTALL_DIR}"
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${ASF_PORT}/tcp" >/dev/null 2>&1 || true
    fi

    log_ok "ArchiSteamFarm 已卸载"
    exit 0
}

# ================================ 安装步骤 ====================================
step_install_deps() {
    log_info "安装依赖..."
    apt-get update -qq
    apt-get install -y -qq wget unzip openssl ca-certificates ufw
    log_ok "依赖安装完成"
}

step_download() {
    local version="$1"
    local file_name="ASF-linux-x64.zip"
    local url="https://github.com/JustArchiNET/ArchiSteamFarm/releases/download/${version}/${file_name}"

    log_info "下载 ASF v${version}..."
    log_info "URL: ${url}"

    mkdir -p "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"

    if ! wget -q --show-progress --tries=3 --timeout=30 -O "${file_name}" "${url}"; then
        log_error "下载失败，请检查网络或 URL 是否正确"
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

    if [[ -z "${ASF_PASSWORD}" ]]; then
        ASF_PASSWORD="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    fi

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
  "IPCPassword": "${ASF_PASSWORD}"
}
EOF

    echo "${ASF_PASSWORD}" > "${INSTALL_DIR}/.ipc_password"
    chmod 600 "${INSTALL_DIR}/.ipc_password"

    log_ok "配置生成完成"
    log_info "IPC 密码已保存到 ${INSTALL_DIR}/.ipc_password"
}

step_create_service() {
    log_info "注册 systemd 服务..."

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
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
    systemctl enable "${SERVICE_NAME}.service"
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

# ================================ 主流程 ====================================
main() {
    check_root
    check_os

    case "${1:-install}" in
        install)
            ensure_user
            echo ""
            echo "============================================================"
            echo "       ArchiSteamFarm 稳定版一键安装脚本"
            echo "============================================================"
            echo ""

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
            configure_firewall
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
            ;;

        uninstall)
            uninstall_asf
            ;;

        status)
            if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
                echo "ASF 服务状态: running"
            else
                echo "ASF 服务状态: stopped"
            fi
            ;;

        start)
            if start_service; then
                echo "ASF 服务已启动"
            else
                echo "启动失败"
                exit 1
            fi
            ;;

        stop)
            if stop_service; then
                echo "ASF 服务已停止"
            else
                echo "停止失败"
                exit 1
            fi
            ;;

        restart)
            if restart_service; then
                echo "ASF 服务已重启"
            else
                echo "重启失败"
                exit 1
            fi
            ;;

        help|--help|-h)
            show_usage
            ;;

        *)
            log_error "未知参数: $1"
            show_usage
            ;;
    esac
}

main "$@"
