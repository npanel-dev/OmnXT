#!/usr/bin/env bash
# OmnXT Node standalone uninstall script.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/uninstall.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/uninstall.sh | sudo bash -s -- --purge

set -euo pipefail

INSTALL_DIR="/usr/local/omnxt"
CONFIG_DIR="/etc/omnxt"
STATE_DIR="/var/lib/omnxt"
LOG_DIR="/var/log/omnxt"
BIN_LINK="/usr/local/bin/omnxt-node"
CLI_LINK="/usr/local/bin/omncli"
SYSTEMD_SERVICE="/etc/systemd/system/omnxt-node.service"
OPENRC_SERVICE="/etc/init.d/omnxt"
OPENRC_RUNLEVEL="default"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
cyan='\033[0;36m'
bold='\033[1m'
plain='\033[0m'

info() { echo -e "${green}[INFO]${plain}  $*"; }
warn() { echo -e "${yellow}[WARN]${plain}  $*"; }
error() { echo -e "${red}[ERROR]${plain} $*"; }

prompt_read() {
    local prompt="$1"
    local var_name="$2"
    local value=""

    if [[ ! -r /dev/tty ]]; then
        warn "当前卸载方式没有可交互终端，默认保留配置、数据和日志；如需清理请传 --purge -y"
        printf -v "${var_name}" '%s' ""
        return 0
    fi

    read -r -p "${prompt}" value < /dev/tty || value=""
    printf -v "${var_name}" '%s' "${value}"
}

[[ "${EUID}" -ne 0 ]] && error "必须使用 root 用户运行此脚本" && exit 1

PURGE=false
ASSUME_YES=false
for arg in "$@"; do
    case "${arg}" in
        --purge|purge) PURGE=true ;;
        -y|--yes) ASSUME_YES=true ;;
    esac
done

echo ""
echo -e "${cyan}${bold}================================================${plain}"
echo -e "${cyan}${bold}  OmnXT Node 卸载${plain}"
echo -e "${cyan}${bold}================================================${plain}"

if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^omnxt-node\.service'; then
        info "停止 systemd 服务 omnxt-node"
        systemctl stop omnxt-node 2>/dev/null || true
        systemctl disable omnxt-node 2>/dev/null || true
    fi
    if [[ -f "${SYSTEMD_SERVICE}" ]]; then
        rm -f "${SYSTEMD_SERVICE}"
        systemctl daemon-reload 2>/dev/null || true
    fi
fi

if command -v rc-service >/dev/null 2>&1; then
    rc-service omnxt stop 2>/dev/null || true
fi
if command -v rc-update >/dev/null 2>&1; then
    rc-update del omnxt "${OPENRC_RUNLEVEL}" 2>/dev/null || true
fi
if [[ -f "${OPENRC_SERVICE}" ]]; then
    rm -f "${OPENRC_SERVICE}"
fi

rm -f "${BIN_LINK}" "${CLI_LINK}"
rm -rf "${INSTALL_DIR}"
info "已删除二进制和服务文件"

if ! ${PURGE}; then
    if ! ${ASSUME_YES}; then
        echo ""
        prompt_read "是否同时删除配置、数据和日志? [y/N]: " answer
        case "${answer}" in
            y|Y|yes|YES) PURGE=true ;;
        esac
    fi
fi

if ${PURGE}; then
    rm -rf "${CONFIG_DIR}" "${STATE_DIR}" "${LOG_DIR}"
    info "已删除配置、数据和日志"
else
    warn "已保留配置、数据和日志:"
    echo "  ${CONFIG_DIR}"
    echo "  ${STATE_DIR}"
    echo "  ${LOG_DIR}"
fi

info "OmnXT Node 卸载完成"
