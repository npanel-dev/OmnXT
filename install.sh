#!/bin/bash
# OmnXT Node 一键安装脚本
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/install.sh | sudo bash -s -- --beta
#   curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/install.sh | sudo bash -s -- 0.1.0
#   curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/install.sh | sudo bash -s -- --repo=npanel-dev/OmnXT
#   curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/install.sh | bash -s -- v1.0.0 --panel-type=ppanel --panel-url=https://api.example.com --server-id=3 --secret-key=xxx --protocol=simnet

set -euo pipefail

# ============ 颜色定义 ============
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
cyan='\033[0;36m'
bold='\033[1m'
plain='\033[0m'

# ============ 路径定义 ============
INSTALL_DIR="/usr/local/omnxt"
CONFIG_DIR="/etc/omnxt"
STATE_DIR="/var/lib/omnxt"
LOG_DIR="/var/log/omnxt"
BIN_LINK="/usr/local/bin/omnxt-node"
CLI_LINK="/usr/local/bin/omncli"
CLI_REAL_LINK="/usr/local/bin/omncli-real"
SYSTEMD_DIR="/etc/systemd/system"
OPENRC_SERVICE="/etc/init.d/omnxt"
OPENRC_RUNLEVEL="default"

# ============ 仓库配置 ============
GITHUB_REPO="${OMNXT_GITHUB_REPO:-npanel-dev/OmnXT}"
LEGO_VERSION="${OMNXT_LEGO_VERSION:-v4.25.2}"
SERVICE_MANAGER=""
MIN_INSTALL_FREE_KB="${OMNXT_INSTALL_MIN_FREE_KB:-2097152}"

# ============ UI 函数 ============
print_banner() {
    echo ""
    echo -e "${cyan}${bold}================================================${plain}"
    printf "${cyan}${bold}  %s${plain}\n" "$1"
    echo -e "${cyan}${bold}================================================${plain}"
}

print_section() {
    echo ""
    echo -e "${cyan}--- $1 ---${plain}"
}

info()  { echo -e "${green}[INFO]${plain}  $*"; }
warn()  { echo -e "${yellow}[WARN]${plain}  $*"; }
error() { echo -e "${red}[ERROR]${plain} $*"; }

prompt_read() {
    local prompt="$1"
    local var_name="$2"
    local value=""

    if [[ ! -r /dev/tty ]]; then
        error "当前安装方式没有可交互终端，无法读取输入"
        error "请改用非交互参数，例如: bash -s -- v1.0.0 --panel-type=ppanel --panel-url=https://panel.example.com --server-id=7 --secret-key=xxx"
        return 1
    fi

    read -r -p "${prompt}" value < /dev/tty || value=""
    printf -v "${var_name}" '%s' "${value}"
}

# ============ 前置检查 ============
[[ $EUID -ne 0 ]] && error "必须使用 root 用户运行此脚本" && exit 1

if [[ "$(getconf LONG_BIT 2>/dev/null)" != "64" ]]; then
    error "OmnXT 仅支持 64 位系统"
    exit 2
fi

# ============ 检测系统 ============
detect_os() {
    if [[ -f /etc/alpine-release ]] || grep -Eq '^ID="?alpine"?$' /etc/os-release 2>/dev/null; then
        OS="alpine"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
    elif grep -Eqi "debian" /etc/issue 2>/dev/null || grep -Eqi "debian" /proc/version 2>/dev/null; then
        OS="debian"
    elif grep -Eqi "ubuntu" /etc/issue 2>/dev/null || grep -Eqi "ubuntu" /proc/version 2>/dev/null; then
        OS="ubuntu"
    elif grep -Eqi "centos|red hat|redhat" /etc/issue 2>/dev/null; then
        OS="centos"
    else
        OS="unknown"
        warn "未识别的系统发行版，将尝试继续安装"
    fi
}

detect_arch() {
    local raw_arch
    raw_arch=$(uname -m)
    case "${raw_arch}" in
        x86_64|x64|amd64) ARCH="x86_64" ;;
        aarch64|arm64)    ARCH="aarch64" ;;
        *)
            error "不支持的 CPU 架构: ${raw_arch}"
            exit 1
            ;;
    esac
    # Rust target triple
    TARGET="unknown-linux-gnu"
    if [[ "${OS}" == "alpine" ]]; then
        TARGET="unknown-linux-musl"
    fi
    RUST_TARGET="${ARCH}-${TARGET}"
}

detect_service_manager() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        SERVICE_MANAGER="systemd"
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        SERVICE_MANAGER="openrc"
    elif command -v systemctl >/dev/null 2>&1; then
        SERVICE_MANAGER="systemd"
    else
        error "未检测到可用的服务管理器（systemd / OpenRC）"
        exit 1
    fi
}

check_disk_space() {
    print_section "检查磁盘空间"

    local probe_path="/"
    if [[ -d "${STATE_DIR}" ]]; then
        probe_path="${STATE_DIR}"
    elif [[ -d "$(dirname "${STATE_DIR}")" ]]; then
        probe_path="$(dirname "${STATE_DIR}")"
    fi

    local available_kb
    available_kb=$(df -Pk "${probe_path}" 2>/dev/null | awk 'NR == 2 { print $4 }')
    if [[ ! "${available_kb}" =~ ^[0-9]+$ ]]; then
        error "无法读取 ${probe_path} 的可用磁盘空间"
        return 1
    fi
    if (( available_kb < MIN_INSTALL_FREE_KB )); then
        error "可用磁盘空间不足，安装前至少需要 $((MIN_INSTALL_FREE_KB / 1024)) MiB"
        error "当前仅剩 $((available_kb / 1024)) MiB；服务尚未停止"
        if [[ -e "${STATE_DIR}/state.db" ]]; then
            ls -lh "${STATE_DIR}/state.db"* 2>/dev/null || true
        fi
        return 1
    fi
    info "磁盘空间检查通过: $((available_kb / 1024)) MiB 可用"
}

stop_existing_service() {
    print_section "停止旧版 OmnXT Node"

    local stopped=false
    if [[ "${SERVICE_MANAGER}" == "systemd" ]]; then
        if systemctl list-unit-files omnxt-node.service >/dev/null 2>&1; then
            systemctl stop omnxt-node 2>/dev/null || true
            stopped=true
        fi
    elif [[ "${SERVICE_MANAGER}" == "openrc" ]]; then
        if [[ -f "${OPENRC_SERVICE}" ]]; then
            rc-service omnxt stop 2>/dev/null || true
            stopped=true
        fi
    fi

    if pgrep -x omnxt-node >/dev/null 2>&1; then
        warn "检测到仍有 omnxt-node 进程，尝试结束"
        pkill -TERM -x omnxt-node 2>/dev/null || true
        sleep 2
        pkill -KILL -x omnxt-node 2>/dev/null || true
        stopped=true
    fi

    if ${stopped}; then
        info "旧版 OmnXT Node 已停止"
    else
        info "未检测到正在运行的旧版 OmnXT Node"
    fi
}

# ============ 解析参数 ============
INSTALL_BETA=false
INSTALL_VERSION=""
PANEL_TYPE=""
PANEL_API_HOST=""
PANEL_SERVER_ID=""
PANEL_SECRET_KEY=""
PANEL_PROTOCOL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --beta|beta)
            INSTALL_BETA=true
            shift
            ;;
        --panel-type=*)
            PANEL_TYPE="${1#*=}"
            shift
            ;;
        --panel-url=*)
            PANEL_API_HOST="${1#*=}"
            shift
            ;;
        --server-id=*)
            PANEL_SERVER_ID="${1#*=}"
            shift
            ;;
        --secret-key=*)
            PANEL_SECRET_KEY="${1#*=}"
            shift
            ;;
        --protocol=*)
            PANEL_PROTOCOL="${1#*=}"
            shift
            ;;
        --protocol)
            PANEL_PROTOCOL="${2:-}"
            shift 2
            ;;
        --repo=*)
            GITHUB_REPO="${1#*=}"
            shift
            ;;
        *)
            if [[ -z "${INSTALL_VERSION}" ]] && echo "$1" | grep -qE '^[0-9v]'; then
                INSTALL_VERSION="${1#v}"
            fi
            shift
            ;;
    esac
done

# ============ 下载函数 ============
download_file() {
    local url="$1"
    local out="$2"

    case "${url}" in
        https://*) ;;
        *) error "拒绝非 HTTPS 下载: ${url}"; return 1 ;;
    esac

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 30 --retry 3 -H "Cache-Control: no-cache" -o "${out}" "${url}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=30 --tries=3 -O "${out}" "${url}"
    else
        error "curl 和 wget 均不可用，无法下载"
        return 1
    fi
}

# ============ 安装依赖 ============
install_dependencies() {
    print_section "安装基础依赖"
    case "${OS}" in
        centos)
            yum install -y epel-release >/dev/null 2>&1 || true
            yum install -y wget curl tar socat tzdata
            ;;
        alpine)
            apk add --no-cache bash ca-certificates curl wget tar tzdata socat openssl openrc
            update-ca-certificates >/dev/null 2>&1 || true
            ;;
        debian|ubuntu)
            apt-get update -qq -o Acquire::ForceIPv4=true
            apt-get install -qq -y -o Acquire::ForceIPv4=true wget curl tar socat tzdata || {
                warn "部分依赖安装失败，尝试跳过 socat"
                apt-get install -qq -y -o Acquire::ForceIPv4=true wget curl tar tzdata
            }
            ;;
        *)
            warn "未知系统，跳过依赖安装，请确保已安装 curl/wget/tar"
            ;;
    esac
}

# ============ 安装 lego ============
install_lego() {
    print_section "安装 lego（用于 HTTP/DNS 自动 TLS 证书）"

    if command -v lego >/dev/null 2>&1; then
        info "lego 已安装: $(command -v lego)"
        return 0
    fi

    local installed=false
    case "${OS}" in
        debian|ubuntu)
            apt-get update -qq -o Acquire::ForceIPv4=true >/dev/null 2>&1 || true
            if apt-get install -qq -y -o Acquire::ForceIPv4=true lego >/dev/null 2>&1; then
                installed=true
            fi
            ;;
        alpine)
            if apk add --no-cache lego >/dev/null 2>&1; then
                installed=true
            fi
            ;;
        centos)
            if yum install -y lego >/dev/null 2>&1; then
                installed=true
            fi
            ;;
    esac

    if ${installed} && command -v lego >/dev/null 2>&1; then
        info "lego 安装成功: $(command -v lego)"
        return 0
    fi

    local lego_arch=""
    case "${ARCH}" in
        x86_64)  lego_arch="amd64" ;;
        aarch64) lego_arch="arm64" ;;
        *)
            warn "当前架构不支持自动下载 lego: ${ARCH}"
            return 0
            ;;
    esac

    local tmp_dir="/tmp/omnxt-lego-install"
    local tarball="${tmp_dir}/lego.tar.gz"
    local url="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/lego_${LEGO_VERSION}_linux_${lego_arch}.tar.gz"

    mkdir -p "${tmp_dir}"
    info "尝试下载 lego: ${url}"
    if download_file "${url}" "${tarball}" 2>/dev/null && tar -xzf "${tarball}" -C "${tmp_dir}" lego 2>/dev/null; then
        install -m 0755 "${tmp_dir}/lego" /usr/local/bin/lego
        rm -rf "${tmp_dir}"
        if command -v lego >/dev/null 2>&1; then
            info "lego 安装成功: $(command -v lego)"
            return 0
        fi
    fi

    rm -rf "${tmp_dir}"
    warn "lego 安装失败（不影响 OmnXT 启动，但 cert_mode=http/dns 无法自动申请证书）"
    warn "可手动安装后重启: https://github.com/go-acme/lego/releases"
}

# ============ 安装 acme.sh ============
install_acme() {
    print_section "安装 acme.sh（可选，用于自动 TLS 证书）"
    if [[ -f /root/.acme.sh/acme.sh ]]; then
        info "acme.sh 已安装，跳过"
        return 0
    fi
    curl -s https://get.acme.sh | sh 2>/dev/null || true
    if [[ -f /root/.acme.sh/acme.sh ]]; then
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt 2>/dev/null || true
        info "acme.sh 安装成功"
    else
        warn "acme.sh 安装失败（不影响 OmnXT 运行，仅影响自动证书申请）"
    fi
}

# ============ 获取版本号 ============
resolve_version() {
    if ${INSTALL_BETA}; then
        info "查询最新 beta 版本..."
        local releases
        releases=$(curl -sL "https://api.github.com/repos/${GITHUB_REPO}/releases")
        local tag=""
        while IFS= read -r line; do
            if echo "${line}" | grep -q '"tag_name"'; then
                tag=$(echo "${line}" | sed 's/.*"tag_name": "//;s/".*//')
            fi
            if echo "${line}" | grep -q '"prerelease": true'; then
                if [[ -n "${tag}" ]]; then
                    INSTALL_VERSION="${tag#v}"
                    info "最新 beta: v${INSTALL_VERSION}"
                    return 0
                fi
            fi
            # GitHub API 按时间倒序返回，遇到正式版说明没有更新的 beta
            if echo "${line}" | grep -q '"prerelease": false'; then
                if [[ -n "${tag}" ]]; then
                    # 当前 tag 是 beta 之后的第一个正式版，tag 中保存的是上一个版本（可能是 beta）
                    break
                fi
            fi
        done <<< "${releases}"
        error "未找到 beta 版本"
        exit 1
    elif [[ -z "${INSTALL_VERSION}" ]]; then
        info "查询最新正式版..."
        local tag
        tag=$(curl -sL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
              | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "//;s/".*//')
        if [[ -z "${tag}" ]]; then
            error "无法获取最新版本号（请检查网络或 GitHub 是否有 release）"
            exit 1
        fi
        INSTALL_VERSION="${tag#v}"
        info "最新正式版: v${INSTALL_VERSION}"
    fi
}

# ============ 下载并解压 ============
download_and_extract() {
    print_section "下载 OmnXT v${INSTALL_VERSION}"
    local tarball="/tmp/omnxt-node.tar.gz"
    rm -f "${tarball}"

    # 尝试多种 URL 模式
    local urls=(
        "https://github.com/${GITHUB_REPO}/releases/download/v${INSTALL_VERSION}/omnxt-node-${RUST_TARGET}.tar.gz"
        "https://github.com/${GITHUB_REPO}/releases/download/${INSTALL_VERSION}/omnxt-node-${RUST_TARGET}.tar.gz"
        "https://github.com/${GITHUB_REPO}/releases/download/v${INSTALL_VERSION}/omnxt-node-linux-${ARCH}.tar.gz"
    )

    local ok=false
    for url in "${urls[@]}"; do
        info "尝试下载: ${url}"
        if download_file "${url}" "${tarball}" 2>/dev/null; then
            if tar -tzf "${tarball}" >/dev/null 2>&1; then
                ok=true
                break
            fi
        fi
        rm -f "${tarball}"
    done

    if ! ${ok}; then
        error "下载 OmnXT v${INSTALL_VERSION} 失败"
        error "请确保 GitHub Release 中包含 ${RUST_TARGET} 的构建产物"
        error "或手动下载: https://github.com/${GITHUB_REPO}/releases"
        exit 1
    fi

    # 解压安装。保留 /etc/omnxt、/var/lib/omnxt、/var/log/omnxt，只覆盖二进制。
    mkdir -p "${INSTALL_DIR}"
    rm -f "${INSTALL_DIR}/omnxt-node" "${INSTALL_DIR}/omncli"
    find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'omnxt-node-*' -exec rm -rf {} +
    tar -xzf "${tarball}" -C "${INSTALL_DIR}" --strip-components=0 2>/dev/null \
        || tar -xzf "${tarball}" -C "${INSTALL_DIR}" 2>/dev/null
    rm -f "${tarball}"

    # 确保二进制可执行
    local node_bin="${INSTALL_DIR}/omnxt-node"
    local cli_bin="${INSTALL_DIR}/omncli"
    if [[ ! -x "${node_bin}" ]]; then
        node_bin=$(find "${INSTALL_DIR}" -maxdepth 3 -type f -name omnxt-node -perm -111 | head -1 || true)
    fi
    if [[ ! -x "${cli_bin}" ]]; then
        cli_bin=$(find "${INSTALL_DIR}" -maxdepth 3 -type f -name omncli -perm -111 | head -1 || true)
    fi
    if [[ -z "${node_bin}" || ! -f "${node_bin}" ]]; then
        error "安装包中未找到 omnxt-node 可执行文件"
        error "请检查 Release 包结构或手动查看: find ${INSTALL_DIR} -maxdepth 3 -type f"
        exit 1
    fi
    chmod +x "${node_bin}" 2>/dev/null || true
    [[ -n "${cli_bin}" && -f "${cli_bin}" ]] && chmod +x "${cli_bin}" 2>/dev/null || true

    # Release 包可能带顶层目录。统一创建稳定入口，systemd/OpenRC 固定使用这里。
    if [[ "${node_bin}" != "${INSTALL_DIR}/omnxt-node" ]]; then
        ln -sf "${node_bin}" "${INSTALL_DIR}/omnxt-node"
    fi
    if [[ -n "${cli_bin}" && -f "${cli_bin}" && "${cli_bin}" != "${INSTALL_DIR}/omncli" ]]; then
        ln -sf "${cli_bin}" "${INSTALL_DIR}/omncli"
    fi

    # 创建符号链接
    ln -sf "${INSTALL_DIR}/omnxt-node" "${BIN_LINK}"
    if [[ -e "${INSTALL_DIR}/omncli" ]]; then
        ln -sf "${INSTALL_DIR}/omncli" "${CLI_REAL_LINK}"
        cat > "${CLI_LINK}" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    if [[ "\${arg}" == "--bootstrap" ]]; then
        exec "${INSTALL_DIR}/omncli" "\$@"
    fi
done
exec "${INSTALL_DIR}/omncli" "\$@" --bootstrap "${CONFIG_DIR}/bootstrap.toml"
EOF
        chmod 755 "${CLI_LINK}"
    fi

    info "二进制文件安装到 ${INSTALL_DIR}"
}

# ============ 创建目录结构 ============
setup_directories() {
    mkdir -p "${CONFIG_DIR}"
    mkdir -p "${STATE_DIR}"
    mkdir -p "${LOG_DIR}"
}

# ============ 生成默认配置 ============
generate_config() {
    local bootstrap="${CONFIG_DIR}/bootstrap.toml"

    if [[ -f "${bootstrap}" ]]; then
        info "配置文件已存在，保留现有配置: ${bootstrap}"
        if ! grep -q '^metadata\.listener_accept_mode[[:space:]]*=' "${bootstrap}"; then
            cat >> "${bootstrap}" <<EOF

# OmnXT Node 监听模式
metadata.listener_accept_mode = "real_once"
EOF
            info "已补充真实 TCP/TLS 监听模式: metadata.listener_accept_mode = \"real_once\""
        fi
        if ! grep -q '^metadata\.node_run_mode[[:space:]]*=' "${bootstrap}"; then
            cat >> "${bootstrap}" <<EOF

# OmnXT Node 服务运行模式
metadata.node_run_mode = "service"
EOF
            info "已补充服务运行模式: metadata.node_run_mode = \"service\""
        fi
        if ! grep -q '^metadata\.service_tick_interval_ms[[:space:]]*=' "${bootstrap}"; then
            cat >> "${bootstrap}" <<EOF
metadata.service_tick_interval_ms = "100"
EOF
            info "已补充服务 tick 间隔: metadata.service_tick_interval_ms = \"100\""
        fi
        if grep -q '^panel_type = "ppanel"' "${bootstrap}" \
            && ! grep -q '^metadata\.ppanel_protocol[[:space:]]*=' "${bootstrap}"; then
            local existing_protocol="${PANEL_PROTOCOL:-simnet}"
            cat >> "${bootstrap}" <<EOF

# PPanel/NPanel 节点协议
metadata.ppanel_protocol = "${existing_protocol}"
EOF
            info "已补充 PPanel/NPanel 协议字段: metadata.ppanel_protocol = \"${existing_protocol}\""
        fi
        return 0
    fi

    print_section "生成配置文件"

    # 如果命令行没传面板参数，交互式询问
    if [[ -z "${PANEL_TYPE}" ]]; then
        echo ""
        echo -e "${cyan}请选择面板类型:${plain}"
        echo "  1) ppanel     (PPanel / NPanel 兼容接口)"
        echo "  2) v2board    (V2Board)"
        echo "  3) xboard     (XBoard)"
        echo "  4) sspanel    (SSPanel-UIM)"
        echo "  5) standalone (独立模式，无面板)"
        echo ""
        prompt_read "请输入选项 [1-5，默认 5]: " panel_choice
        case "${panel_choice}" in
            1) PANEL_TYPE="ppanel" ;;
            2) PANEL_TYPE="v2board" ;;
            3) PANEL_TYPE="xboard" ;;
            4) PANEL_TYPE="sspanel" ;;
            *)  PANEL_TYPE="standalone" ;;
        esac
    fi
    if [[ "${PANEL_TYPE}" == "npanel" ]]; then
        warn "NPanel 使用 PPanel 兼容接口，已自动按 ppanel 写入配置"
        PANEL_TYPE="ppanel"
    fi

    if [[ "${PANEL_TYPE}" != "standalone" ]]; then
        [[ -z "${PANEL_API_HOST}" ]] && prompt_read "面板地址 (如 https://panel.example.com): " PANEL_API_HOST
        [[ -z "${PANEL_SERVER_ID}" ]] && prompt_read "节点 ID: " PANEL_SERVER_ID
        [[ -z "${PANEL_SECRET_KEY}" ]] && prompt_read "通信密钥: " PANEL_SECRET_KEY
        if [[ "${PANEL_TYPE}" == "ppanel" && -z "${PANEL_PROTOCOL}" ]]; then
            echo ""
            echo -e "${cyan}请选择 PPanel/NPanel 节点协议:${plain}"
            echo "  1) simnet"
            echo "  2) shadowsocks"
            echo "  3) trojan"
            echo "  4) vmess"
            echo "  5) vless"
            echo ""
            prompt_read "请输入选项 [1-5，默认 1]: " protocol_choice
            case "${protocol_choice}" in
                2) PANEL_PROTOCOL="shadowsocks" ;;
                3) PANEL_PROTOCOL="trojan" ;;
                4) PANEL_PROTOCOL="vmess" ;;
                5) PANEL_PROTOCOL="vless" ;;
                *) PANEL_PROTOCOL="simnet" ;;
            esac
        fi
    fi

    # 生成 hostname 作为 instance_id
    local instance_id
    instance_id="omnxt-$(hostname -s 2>/dev/null || echo 'node')"

    cat > "${bootstrap}" <<EOF
# OmnXT Node 配置文件
# 由 install.sh 自动生成于 $(date -u +"%Y-%m-%dT%H:%M:%SZ")
instance_id = "${instance_id}"
state_store_path = "${STATE_DIR}/state.db"
panel_type = "${PANEL_TYPE}"

# 运行模式
metadata.listener_accept_mode = "real_once"
metadata.node_run_mode = "service"
metadata.service_tick_interval_ms = "100"
EOF

    # 追加面板配置
    case "${PANEL_TYPE}" in
        ppanel)
            cat >> "${bootstrap}" <<EOF

# PPanel 面板配置
# NPanel 请使用 PPanel 兼容接口，节点侧仍配置 panel_type = "ppanel"
metadata.ppanel_api_host = "${PANEL_API_HOST}"
metadata.ppanel_server_id = "${PANEL_SERVER_ID}"
metadata.ppanel_secret_key = "${PANEL_SECRET_KEY}"
metadata.ppanel_protocol = "${PANEL_PROTOCOL:-simnet}"
EOF
            ;;
        v2board|xboard)
            cat >> "${bootstrap}" <<EOF

# ${PANEL_TYPE} 面板配置
metadata.${PANEL_TYPE}_api_host = "${PANEL_API_HOST}"
metadata.${PANEL_TYPE}_token = "${PANEL_SECRET_KEY}"
metadata.${PANEL_TYPE}_node_id = "${PANEL_SERVER_ID}"
EOF
            ;;
        sspanel)
            cat >> "${bootstrap}" <<EOF

# SSPanel-UIM 面板配置
metadata.sspanel_api_host = "${PANEL_API_HOST}"
metadata.sspanel_mu_key = "${PANEL_SECRET_KEY}"
metadata.sspanel_node_id = "${PANEL_SERVER_ID}"
EOF
            ;;
        standalone)
            cat >> "${bootstrap}" <<EOF

# 独立模式 — 无面板
# 请手动配置协议参数，或使用 omncli 命令管理
EOF
            ;;
    esac

    info "配置已写入: ${bootstrap}"
}

# ============ Systemd 服务 ============
write_systemd_service() {
    cat > "${SYSTEMD_DIR}/omnxt-node.service" <<EOF
[Unit]
Description=OmnXT Node Service
Documentation=https://github.com/${GITHUB_REPO}
After=network.target nss-lookup.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
Environment=OMNXT_NODE_LOG_FILE=${LOG_DIR}/omnxt-node.log
Environment=OMNXT_LOG_MAX_BYTES=33554432
Environment=OMNXT_LOG_MAX_BACKUPS=7
Environment=OMNXT_STATE_MIN_FREE_BYTES=2147483648
Environment=OMNXT_STATE_MIN_FREE_PERCENT=10
ExecStart=${INSTALL_DIR}/omnxt-node --bootstrap ${CONFIG_DIR}/bootstrap.toml --service
WorkingDirectory=${INSTALL_DIR}
Restart=on-failure
RestartSec=5
LogRateLimitIntervalSec=30s
LogRateLimitBurst=2000
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# ============ OpenRC 服务 ============
write_openrc_service() {
    cat > "${OPENRC_SERVICE}" <<'SVCEOF'
#!/sbin/openrc-run

name="OmnXT Node"
description="OmnXT Node Service"

command="/usr/local/omnxt/omnxt-node"
command_args="--bootstrap /etc/omnxt/bootstrap.toml --service"
pidfile="/run/omnxt.pid"
directory="/usr/local/omnxt"
export OMNXT_NODE_LOG_FILE="/var/log/omnxt/omnxt-node.log"
export OMNXT_LOG_MAX_BYTES="33554432"
export OMNXT_LOG_MAX_BACKUPS="7"
export OMNXT_STATE_MIN_FREE_BYTES="2147483648"
export OMNXT_STATE_MIN_FREE_PERCENT="10"

depend() {
    need net
    use dns logger
}

start_pre() {
    checkpath --directory --mode 0755 /var/log/omnxt
}

start() {
    ebegin "Starting ${RC_SVCNAME}"
    start-stop-daemon --start \
        --background \
        --make-pidfile \
        --pidfile "${pidfile}" \
        --stdout /var/log/omnxt/omnxt.log \
        --stderr /var/log/omnxt/omnxt.err \
        --exec "${command}" -- ${command_args}
    eend $?
}

stop() {
    ebegin "Stopping ${RC_SVCNAME}"
    start-stop-daemon --stop --retry TERM/30/KILL/5 --pidfile "${pidfile}"
    local rc=$?
    rm -f "${pidfile}"
    eend ${rc}
}
SVCEOF
    chmod 755 "${OPENRC_SERVICE}"
}

# ============ 安装服务 ============
install_service() {
    print_section "安装系统服务 (${SERVICE_MANAGER})"

    if [[ "${SERVICE_MANAGER}" == "systemd" ]]; then
        write_systemd_service
        systemctl daemon-reload
        systemctl enable omnxt-node
        info "Systemd 服务已安装并设为开机自启"
    else
        write_openrc_service
        rc-update add omnxt "${OPENRC_RUNLEVEL}" 2>/dev/null || true
        info "OpenRC 服务已安装并设为开机自启"
    fi
}

# ============ 启动服务 ============
start_service() {
    print_section "启动 OmnXT Node"

    if [[ "${SERVICE_MANAGER}" == "systemd" ]]; then
        systemctl restart omnxt-node
        sleep 2
        if systemctl is-active --quiet omnxt-node; then
            info "OmnXT Node 启动成功 ✓"
        else
            warn "OmnXT Node 可能启动失败，请查看日志:"
            echo "  journalctl -u omnxt-node -f --no-pager"
        fi
    else
        rc-service omnxt restart >/dev/null 2>&1
        sleep 2
        if rc-service omnxt status >/dev/null 2>&1; then
            info "OmnXT Node 启动成功 ✓"
        else
            warn "OmnXT Node 可能启动失败，请查看日志:"
            echo "  cat /var/log/omnxt/omnxt.log"
        fi
    fi
}

# ============ 安装后指引 ============
print_post_install() {
    print_banner "安装完成"

    echo ""
    echo -e "${cyan}========== 目录结构 ==========${plain}"
    echo "  二进制:  ${INSTALL_DIR}/"
    echo "  配置:    ${CONFIG_DIR}/bootstrap.toml"
    echo "  数据:    ${STATE_DIR}/"
    echo "  日志:    ${LOG_DIR}/"
    echo ""
    echo -e "${cyan}========== 常用命令 ==========${plain}"
    if [[ "${SERVICE_MANAGER}" == "systemd" ]]; then
        echo "  systemctl status omnxt-node     查看运行状态"
        echo "  systemctl restart omnxt-node    重启服务"
        echo "  systemctl stop omnxt-node       停止服务"
        echo "  journalctl -u omnxt-node -f     查看实时日志"
    else
        echo "  rc-service omnxt status         查看运行状态"
        echo "  rc-service omnxt restart        重启服务"
        echo "  rc-service omnxt stop           停止服务"
        echo "  cat /var/log/omnxt/omnxt.log    查看日志"
    fi

    if [[ -f "${CLI_LINK}" ]]; then
        echo ""
        echo -e "${cyan}========== CLI 管理 ==========${plain}"
        echo "  omncli status                  查看节点状态"
        echo "  omncli panel show              查看面板配置"
        echo "  omncli config lint             验证配置"
        echo "  omncli control status          查看面板同步/上报"
    fi

    echo ""
    echo -e "${cyan}========== 面板类型 ==========${plain}"
    echo "  支持: ppanel, npanel(兼容 ppanel), v2board, xboard, sspanel, standalone"
    echo "  当前: ${PANEL_TYPE}"

    echo ""
    echo -e "${cyan}========== 配置示例 ==========${plain}"
    echo "  编辑配置: nano ${CONFIG_DIR}/bootstrap.toml"
    echo "  重启生效: systemctl restart omnxt-node"

    echo ""
    echo -e "${cyan}========== 卸载 ==========${plain}"
    echo "  curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/uninstall.sh | sudo bash"
    echo ""
}

# ============ 卸载 ============
uninstall() {
    print_banner "卸载 OmnXT Node"

    if [[ "${SERVICE_MANAGER}" == "systemd" ]]; then
        systemctl stop omnxt-node 2>/dev/null || true
        systemctl disable omnxt-node 2>/dev/null || true
        rm -f "${SYSTEMD_DIR}/omnxt-node.service"
        systemctl daemon-reload
    else
        rc-service omnxt stop 2>/dev/null || true
        rc-update del omnxt "${OPENRC_RUNLEVEL}" 2>/dev/null || true
        rm -f "${OPENRC_SERVICE}"
    fi

    rm -f "${BIN_LINK}" "${CLI_LINK}" "${CLI_REAL_LINK}"
    rm -rf "${INSTALL_DIR}"
    info "二进制文件已删除"

    echo ""
    prompt_read "是否同时删除配置和数据? [y/N]: " del_data
    if [[ "${del_data}" =~ ^[Yy]$ ]]; then
        rm -rf "${CONFIG_DIR}" "${STATE_DIR}" "${LOG_DIR}"
        info "配置和数据已清除"
    else
        info "配置和数据已保留: ${CONFIG_DIR}, ${STATE_DIR}"
    fi

    info "OmnXT Node 卸载完成"
    exit 0
}

# ============ 主流程 ============
main() {
    # 检查是否是卸载
    for arg in "$@"; do
        [[ "${arg}" == "--uninstall" || "${arg}" == "uninstall" ]] && {
            detect_os
            detect_service_manager
            uninstall
        }
    done

    print_banner "OmnXT Node 安装脚本"

    detect_os
    detect_arch
    detect_service_manager

    # 提前检测版本，确保显示正确的版本信息
    resolve_version

    echo -e "  系统:     ${green}${OS}${plain}"
    echo -e "  架构:     ${green}${ARCH}${plain}"
    echo -e "  Target:   ${green}${RUST_TARGET}${plain}"
    echo -e "  服务管理: ${green}${SERVICE_MANAGER}${plain}"
    if ${INSTALL_BETA}; then
        echo -e "  版本:     ${yellow}v${INSTALL_VERSION} (beta)${plain}"
    else
        echo -e "  版本:     ${green}v${INSTALL_VERSION}${plain}"
    fi

    check_disk_space
    install_dependencies
    install_lego
    install_acme
    stop_existing_service
    download_and_extract
    setup_directories
    generate_config
    install_service
    start_service
    print_post_install
}

main "$@"
