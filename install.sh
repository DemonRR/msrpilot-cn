#!/usr/bin/env bash
###############################################################################
# MSRPilot CN（Docker 版）交互式一键安装/升级/卸载脚本
#
# 用法:
#   bash install.sh                      # 交互菜单（快速安装 / 自定义 / 升级 / 卸载）
#   bash install.sh --quick              # 跳过菜单直接快速安装
#   bash install.sh --dir /opt/msrpilot-cn
#   bash install.sh --uninstall          # 卸载（会再次确认）
#
# compose.yaml 与 .env 模板均从 GitHub 仓库下载（脚本不内置任何副本）:
#   https://github.com/DemonRR/msrpilot-cn  (master 分支)
#   直连失败会自动通过 gh-proxy.com 加速重试；可用环境变量自定义:
#     MSRPILOT_GH_PROXY=<加速前缀>       → 默认 https://gh-proxy.com/
#     MSRPILOT_COMPOSE_URL=<完整链接>    → compose.yaml（优先于上面规则）
#     MSRPILOT_ENV_URL=<完整链接>        → env.example（优先于上面规则）
###############################################################################

set -euo pipefail

# ── 默认值（可用环境变量覆盖）────────────────────────────────────────────
COMPOSE_URL="$(printf '%s' "${MSRPILOT_COMPOSE_URL:-https://raw.githubusercontent.com/DemonRR/msrpilot-cn/master/compose.yaml}" | tr -d ' \r')"
ENV_URL="$(printf '%s' "${MSRPILOT_ENV_URL:-https://raw.githubusercontent.com/DemonRR/msrpilot-cn/master/env.example}" | tr -d ' \r')"
GH_PROXY="${MSRPILOT_GH_PROXY:-https://gh-proxy.com/}"
GH_PROXY="${GH_PROXY%/}/"
DEFAULT_TZ="Asia/Shanghai"
DEFAULT_CRON="30 7 * * *;30 15 * * *"
API_CONTAINER_PORT="3010"
DEFAULT_DIR="${HOME}/msrpilot-cn"

# ── 输出样式 ────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;36m'; C_0='\033[0m'
else
    C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi

# ── 输入净化 ────────────────────────────────────────────────────────────
# 剥离回车符：CRLF 文件/粘贴内容混入的 \r 会让终端显示错乱（光标回行首），
# 也会污染 docker tag 等命令参数（invalid reference format）。
strip_cr() { printf '%s' "$1" | tr -d '\r'; }

info()  { printf "${C_B}[INFO]${C_0} %s\n" "$(strip_cr "$*")"; }
ok()    { printf "${C_G}[ OK ]${C_0} %s\n" "$(strip_cr "$*")"; }
warn()  { printf "${C_Y}[WARN]${C_0} %s\n" "$(strip_cr "$*")"; }
err()   { printf "${C_R}[FAIL]${C_0} %s\n" "$(strip_cr "$*")" >&2; }
die()   { err "$*"; exit 1; }

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

# ── 交互输入辅助 ────────────────────────────────────────────────────────
ask() { # $1=提示 $2=默认值；EOF 回落默认值；提示与回答均剥离 \r
    local def ans=""
    def="$(strip_cr "$2")"
    read -r -p "$(strip_cr "$1") [$def]: " ans || ans=""
    ans="$(strip_cr "$ans")"
    printf '%s' "${ans:-$def}"
}

ask_yes() { # $1=提示 $2=y|n
    local ans
    while :; do
        read -r -p "$(strip_cr "$1") [$2]: " ans || ans=""
        ans="${ans:-$2}"
        case "$ans" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
        esac
        warn "请输入 y 或 n"
    done
}

is_valid_cron() { # 每段 5 个字段；read -a 分词避免 '*' 触发文件名展开
    local seg n_seg=0
    local arr=()
    while IFS= read -r seg; do
        [ -z "$seg" ] && continue
        read -r -a arr <<<"$seg"
        [ "${#arr[@]}" -eq 5 ] || return 1
        n_seg=$((n_seg + 1))
    done <<< "$(printf '%s' "$1" | tr ';' '\n')"
    [ "$n_seg" -ge 1 ]
}

is_valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

gen_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

detect_lan_ip() {
    local ip=""
    ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)"
    [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s' "$ip"
}

# ── 参数解析 ────────────────────────────────────────────────────────────
ARG_DIR=""; ARG_MODE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir)       [ -n "${2:-}" ] || die "--dir 需要一个路径参数"; ARG_DIR="$2"; shift 2 ;;
        --dir=*)     ARG_DIR="${1#*=}"; shift ;;
        --quick)     ARG_MODE="quick"; shift ;;
        --uninstall) ARG_MODE="uninstall"; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "未知参数: $1（用法见 $0 --help）" ;;
    esac
done

###############################################################################
# 1. 环境检查: Docker / Compose / sudo
###############################################################################
SUDO=""
if ! docker info >/dev/null 2>&1 \
    && [ "$(id -u)" -ne 0 ] \
    && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

ensure_docker() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        ok "Docker 已安装: $(docker --version | head -1)"
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        if [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
            ok "通过 sudo 使用 Docker"
            return 0
        fi
        die "无法连接 Docker daemon。请用 root 运行、将当前用户加入 docker 组，或安装并启用 sudo。"
    fi
    warn "未检测到 Docker。"
    if ask_yes "是否现在通过官方脚本 (get.docker.com) 自动安装 Docker？" y; then
        command -v curl >/dev/null 2>&1 || die "需要 curl 才能自动安装，请先安装 curl 或手动安装 Docker"
        $SUDO curl -fsSL https://get.docker.com | $SUDO sh
        $SUDO systemctl enable --now docker 2>/dev/null || true
        command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
            && ok "Docker 安装成功" || die "Docker 安装失败，请手动安装后重试"
    else
        die "请先安装 Docker 后再运行本脚本（https://docs.docker.com/engine/install/）"
    fi
}

ensure_docker

if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    die "未检测到 Docker Compose（需要 Compose v2: docker compose）。请升级 Docker。"
fi
ok "使用 Compose 命令: $COMPOSE"

# 仅在当前用户直连 daemon 失败时才借助 sudo
if ! docker info >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

###############################################################################
# 2. 通用检查: 容器名冲突 / 端口占用
###############################################################################
check_container_conflict() {
    local existing
    existing="$($SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x "$CONTAINER_NAME" || true)"
    if [ -n "$existing" ]; then
        warn "已存在同名容器 ${CONTAINER_NAME}（可能来自其他目录的旧安装）"
        if ask_yes "  停止并删除旧容器后继续？（数据目录/卷不会被删除）" y; then
            $SUDO docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
            ok "旧容器已删除"
        else
            die "已取消。请先处理同名容器（docker rm -f ${CONTAINER_NAME}）后重试"
        fi
    fi
}

check_port_free() { # $1=端口
    local in_use=""
    in_use="$($SUDO docker ps --format '{{.Ports}}' 2>/dev/null | grep ":$1->" || true)"
    if [ -z "$in_use" ]; then
        in_use="$( (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep ":$1 " || true )"
    fi
    [ -n "$in_use" ]
}

###############################################################################
# 3. 下载 compose.yaml / .env 模板（GitHub，直连失败自动走加速）
###############################################################################
gh_fetch() { # $1=url $2=dest → 成功返回 0
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --retry 2 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 10 -t 2 -O "$2" "$1"
    else
        return 1
    fi
}

gh_fetch_smart() { # 直连失败自动走 gh-proxy 加速
    gh_fetch "$1" "$2" && return 0
    warn "GitHub 直连失败，尝试通过 ${GH_PROXY} 加速重试 ..."
    gh_fetch "${GH_PROXY}$1" "$2"
}

download_templates() {
    if ! gh_fetch_smart "$COMPOSE_URL" "$INSTALL_DIR/compose.yaml" || ! grep -q '^services:' "$INSTALL_DIR/compose.yaml"; then
        rm -f "$INSTALL_DIR/compose.yaml"
        die "compose.yaml 下载失败（直连与加速均不可用）。
      1) 换加速前缀:       MSRPILOT_GH_PROXY=<前缀> bash $0
      2) 指定完整链接:     MSRPILOT_COMPOSE_URL=<链接> bash $0
      3) 手动下载放入 ${INSTALL_DIR} 后重新运行"
    fi
    # CRLF正規化: Windowsコミット由来のCRがIMAGE_REF等の変数に混入すると
    # docker tag が "invalid reference format" で拒否するため、ここで落とす
    sed -i 's/\r$//' "$INSTALL_DIR/compose.yaml"
    ok "已下载 compose.yaml"
    if ! gh_fetch_smart "$ENV_URL" "$INSTALL_DIR/.env.example" || ! grep -q '^API_TOKEN=' "$INSTALL_DIR/.env.example"; then
        rm -f "$INSTALL_DIR/.env.example"
        die ".env 模板下载失败（直连与加速均不可用）。
      1) 换加速前缀:       MSRPILOT_GH_PROXY=<前缀> bash $0
      2) 指定完整链接:     MSRPILOT_ENV_URL=<链接> bash $0
      3) 手动下载 env.example 放入 ${INSTALL_DIR} 并改名 .env.example 后重新运行"
    fi
    sed -i 's/\r$//' "$INSTALL_DIR/.env.example"
    ok "已下载 .env 模板（.env.example）"
}

###############################################################################
# 4. 配置写入
###############################################################################
set_env_kv() { # $1=file $2=key $3=value（兼容注释行；转义 sed 特殊字符）
    local esc
    esc=$(printf '%s' "$3" | sed -e 's/[\\|&]/\\&/g')
    if grep -qE "^#?${2}=" "$1"; then
        sed -i -E "s/^#?(${2})=.*/\\1=${esc}/" "$1"
    else
        printf '%s\n' "$2=$3" >> "$1"
    fi
}

write_env_file() {
    local f="$INSTALL_DIR/.env" i slot
    umask 077
    cp -f "$INSTALL_DIR/.env.example" "$f"
    set_env_kv "$f" "API_TOKEN" "$API_TOKEN_VALUE"
    set_env_kv "$f" "LICENSE_KEY" "$LICENSE_VALUE"
    i=0
    for email in ${ACC_EMAILS[@]+"${ACC_EMAILS[@]}"}; do
        slot=$((i + 1))
        set_env_kv "$f" "ACCOUNT_${slot}_EMAIL" "$email"
        set_env_kv "$f" "ACCOUNT_${slot}_PASSWORD" "${ACC_PASS[$i]}"
        set_env_kv "$f" "ACCOUNT_${slot}_TOTP_SECRET" "${ACC_TOTP[$i]}"
        set_env_kv "$f" "ACCOUNT_${slot}_ENABLED" "true"
        i=$((i + 1))
    done
    umask 022
    chmod 600 "$f"
}

write_config_preseed() { # PushPlus 直接写入 config.json（行为配置的唯一真源）
    [ -n "$PUSHPLUS_TOKEN_VALUE" ] || return 0
    mkdir -p "$INSTALL_DIR/config"
    local f="$INSTALL_DIR/config/config.json"
    if [ -f "$f" ]; then
        info "config/config.json 已存在，跳过预置（PushPlus 可在管理台开启）"
        return 0
    fi
    local token_escaped="${PUSHPLUS_TOKEN_VALUE//\\/\\\\}"
    token_escaped="${token_escaped//\"/\\\"}"
    cat > "$f" <<EOF
{
    "webhook": {
        "pushplus": {
            "enabled": true,
            "token": "$token_escaped",
            "title": "MSRPilot",
            "template": "html",
            "channel": "wechat"
        }
    }
}
EOF
    info "已预置 config/config.json（PushPlus 通知已启用，可在管理台修改）"
}

patch_compose() { # 按向导选择对下载的 compose.yaml 做最小修改
    COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
    cp -f "$COMPOSE_FILE" "$INSTALL_DIR/compose.yaml.orig"

    sed -i -E "s|^([[:space:]]*TZ:).*$|\1 \"$TZ_VALUE\"|"          "$COMPOSE_FILE"
    sed -i -E "s|^([[:space:]]*CRON_SCHEDULES:).*$|\1 \"$CRON_VALUE\"|" "$COMPOSE_FILE"
    sed -i -E "s|^([[:space:]]*RUN_ON_START:).*$|\1 \"$RUN_ON_START\"|"  "$COMPOSE_FILE"

    if [ "$API_MODE" = "true" ]; then
        if [ "$API_HOST_PORT" != "$API_CONTAINER_PORT" ] || [ -n "$API_BIND" ]; then
            sed -i -E "s|^([[:space:]]*)- \"[0-9]+:${API_CONTAINER_PORT}\"|\1- \"${API_BIND}${API_HOST_PORT}:${API_CONTAINER_PORT}\"|" "$COMPOSE_FILE"
        fi
    else
        sed -i -E "s|^([[:space:]]*API_MODE:).*$|\1 \"false\"|" "$COMPOSE_FILE"
        sed -i -E "s|^([[:space:]]*)- \"[0-9]+:${API_CONTAINER_PORT}\"|\1# - \"${API_CONTAINER_PORT}:${API_CONTAINER_PORT}\"|" "$COMPOSE_FILE"
    fi

    cmp -s "$COMPOSE_FILE" "$INSTALL_DIR/compose.yaml.orig" && rm -f "$INSTALL_DIR/compose.yaml.orig"

    CONTAINER_NAME="$(grep -m1 'container_name:' "$COMPOSE_FILE" | awk '{print $2}' | tr -d '"\r' || true)"
    CONTAINER_NAME="${CONTAINER_NAME:-msrpilot-cn}"
}

###############################################################################
# 5. 卸载
###############################################################################
do_uninstall() {
    if [ -z "$INSTALL_DIR" ]; then
        INSTALL_DIR="$(ask "要卸载的安装目录" "$DEFAULT_DIR")"
        INSTALL_DIR="${INSTALL_DIR%/}"
    fi
    [ -f "$INSTALL_DIR/compose.yaml" ] || die "${INSTALL_DIR} 下没有 compose.yaml，无已安装实例"

    echo ""
    echo "即将卸载: ${INSTALL_DIR}"
    echo "  ├─ 停止并删除容器（必做）"
    echo "  ├─ 数据目录 config/ sessions/ diagnostics/ 与 .env（可选删除）"
    echo "  └─ 镜像（可选删除）"
    ask_yes "确认停止并删除容器？" y || { info "已取消。"; exit 0; }

    (cd "$INSTALL_DIR" && $SUDO $COMPOSE down --remove-orphans) || warn "容器停止失败（可能本来就没在运行）"

    if ask_yes "同时删除数据与配置（config/ sessions/ diagnostics/ .env，不可恢复）？" n; then
        ask_yes "  再次确认：数据删除后无法恢复，确定？" n && {
            rm -rf "$INSTALL_DIR/config" "$INSTALL_DIR/sessions" "$INSTALL_DIR/diagnostics"
            rm -f  "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.bak" "$INSTALL_DIR/install-info.txt"
            ok "数据与配置已删除"
        }
    else
        info "数据已保留，可重新安装后继续使用"
    fi

    local img
    img="$(grep -m1 -E '^[[:space:]]*image:' "$INSTALL_DIR/compose.yaml" | awk '{print $2}' | tr -d '"\r' || true)"
    if [ -n "$img" ] && ask_yes "同时删除镜像 ${img}？" n; then
        $SUDO docker rmi "$img" >/dev/null 2>&1 && ok "镜像已删除" || warn "镜像删除失败（可能被其他容器引用）"
    fi

    ok "卸载完成（compose.yaml 等安装文件保留在 ${INSTALL_DIR}，可手动删除）"
    exit 0
}

###############################################################################
# 6. 收集配置: 快速 / 自定义
###############################################################################
collect_quick() {
    WIZARD_LABEL="快速安装（其余全部使用默认配置）"
    TZ_VALUE="$DEFAULT_TZ"
    CRON_VALUE="$DEFAULT_CRON"
    RUN_ON_START="false"
    ACC_EMAILS=(); ACC_PASS=(); ACC_TOTP=()
    local email pass
    email="$(ask "微软账号邮箱（可留空，装完在管理台「账号管理」添加）" "")"
    email="$(printf '%s' "$email" | tr -d ' \r')"
    if [ -n "$email" ]; then
        pass="$(ask "  该账号密码（可留空）" "")"
        ACC_EMAILS+=("$email"); ACC_PASS+=("$pass"); ACC_TOTP+=("")
    fi
    API_MODE="true"
    API_HOST_PORT="$API_CONTAINER_PORT"
    API_BIND=""
    API_TOKEN_VALUE="$(gen_token)"
    LICENSE_VALUE=""
    PUSHPLUS_TOKEN_VALUE=""
}

collect_custom() {
    WIZARD_LABEL="自定义安装"
    TZ_VALUE="$DEFAULT_TZ"   # 时区固定默认值；需要改动时直接编辑 compose.yaml 的 TZ
    while :; do
        CRON_VALUE="$(ask "运行时间表 CRON_SCHEDULES（多个用英文分号 ; 分隔）" "$DEFAULT_CRON")"
        if is_valid_cron "$CRON_VALUE"; then break; fi
        _cron_tries=${_cron_tries:-0}
        _cron_tries=$((_cron_tries + 1))
        [ "$_cron_tries" -ge 50 ] && die "cron 表达式连续校验失败，退出。正确示例: 0 7 * * *;0 19 * * *"
        warn "格式不正确，每条 cron 需要 5 个字段，例如: 0 7 * * *;0 19 * * *"
    done

    if ask_yes "容器启动后立即执行一次任务 (RUN_ON_START)？" n; then
        RUN_ON_START="true"
    else
        RUN_ON_START="false"
    fi

    info "配置微软账号（密码可留空 = 走 token 登录；支持 TOTP）。"
    info "compose 只透传前 2 个账号，更多账号请在 Web 管理台「账号管理」里添加。"
    ACC_EMAILS=(); ACC_PASS=(); ACC_TOTP=()
    while :; do
        local n=${#ACC_EMAILS[@]}
        local slot=$((n + 1))
        local email
        if [ "$n" -eq 0 ]; then
            email="$(ask "  账号 ${slot} 邮箱（可留空，装完在管理台「账号管理」添加）" "")"
        else
            email="$(ask "  账号 ${slot} 邮箱（留空结束添加）" "")"
        fi
        email="$(printf '%s' "$email" | tr -d ' \r')"
        if [ -z "$email" ]; then
            if [ "$n" -eq 0 ]; then
                warn "未添加账号：装完请在 Web 管理台「账号管理」里添加并保存，否则任务无法运行。"
            fi
            break
        fi
        local pass totp
        pass="$(ask "  账号 ${slot} 密码（可留空）" "")"
        totp="$(ask "  账号 ${slot} TOTP 密钥（可留空）" "")"
        ACC_EMAILS+=("$email"); ACC_PASS+=("$pass"); ACC_TOTP+=("$totp")
        ok "  已添加账号 ${slot}: ${email}"
    done

    if ask_yes "启用 Web 管理台（浏览器管理运行/日志/账号）？" y; then
        API_MODE="true"
        while :; do
            API_HOST_PORT="$(ask "  管理台端口（宿主机）" "$API_CONTAINER_PORT")"
            is_valid_port "$API_HOST_PORT" && break
            warn "端口必须是 1-65535 的数字"
        done
        if check_port_free "$API_HOST_PORT"; then
            warn "端口 ${API_HOST_PORT} 已被占用"
            if ask_yes "  换一个端口？" y; then
                API_HOST_PORT=""
                while [ -z "$API_HOST_PORT" ]; do
                    API_HOST_PORT="$(ask "  管理台端口" "$API_CONTAINER_PORT")"
                    is_valid_port "$API_HOST_PORT" && ! check_port_free "$API_HOST_PORT" && break
                    warn "端口无效或仍被占用"
                    API_HOST_PORT=""
                done
            fi
        fi
        if ask_yes "  仅本机访问 (127.0.0.1)？远程服务器选否" n; then
            API_BIND="127.0.0.1:"
        else
            API_BIND=""
        fi
    else
        API_MODE="false"
        API_HOST_PORT=""
    fi

    info "API_TOKEN 是管理台的访问令牌（compose 必填项，即使关闭管理台也要有值）。"
    if ask_yes "自动生成 API_TOKEN？" y; then
        API_TOKEN_VALUE="$(gen_token)"
    else
        while [ -z "$API_TOKEN_VALUE" ]; do
            API_TOKEN_VALUE="$(ask "  请输入 API_TOKEN" "")"
            [ -n "$API_TOKEN_VALUE" ] || warn "API_TOKEN 不能为空"
        done
    fi

    echo ""
    info "授权: 首次启动自动开始 24 小时免费体验；有授权码可现在填入。"
    LICENSE_VALUE="$(ask "LICENSE_KEY 授权码（可留空，稍后在 .env 补填）" "")"

    PUSHPLUS_TOKEN_VALUE=""
    if ask_yes "配置 PushPlus 微信通知（任务完成推送运行摘要）？" n; then
        while [ -z "$PUSHPLUS_TOKEN_VALUE" ]; do
            PUSHPLUS_TOKEN_VALUE="$(ask "  PushPlus Token（pushplus.plus 微信登录获取）" "")"
            [ -n "$PUSHPLUS_TOKEN_VALUE" ] || warn "Token 不能为空"
        done
    fi
}

show_summary() {
    echo ""
    echo "──────────────────────── 配置确认 ────────────────────────"
    echo "  安装方式        : ${WIZARD_LABEL}"
    echo "  安装目录        : ${INSTALL_DIR}"
    echo "  时区            : ${TZ_VALUE}"
    echo "  运行时间表      : ${CRON_VALUE}"
    echo "  启动即跑一次    : ${RUN_ON_START}"
    local_n=${#ACC_EMAILS[@]}
    echo "  微软账号数量    : ${local_n}"
    i=0; while [ "$i" -lt "$local_n" ]; do
        masked=""
        [ -n "${ACC_PASS[$i]}" ] && masked="（密码已设置）"
        [ -n "${ACC_TOTP[$i]}" ] && masked="${masked}（TOTP 已设置）"
        echo "    账号 $((i + 1))        : ${ACC_EMAILS[$i]} ${masked}"
        i=$((i + 1))
    done
    echo "  Web 管理台      : ${API_MODE}"
    if [ "$API_MODE" = "true" ]; then
        echo "    访问地址      : http://${LAN_IP:-<服务器IP>}:${API_HOST_PORT}/"
        echo "    API_TOKEN     : ${API_TOKEN_VALUE}"
    fi
    echo "  授权码          : ${LICENSE_VALUE:-(空，使用 24 小时试用)}"
    if [ -n "$PUSHPLUS_TOKEN_VALUE" ]; then
        echo "  PushPlus 通知   : 已配置"
    else
        echo "  PushPlus 通知   : 未启用"
    fi
    echo "──────────────────────────────────────────────────────────"
    echo ""
    ask_yes "确认无误，开始安装？" y || { info "已取消，未做任何更改。"; exit 0; }
}

###############################################################################
# 7. 安装
###############################################################################
do_install() {
    # 安装目录
    if [ -n "$ARG_DIR" ]; then
        INSTALL_DIR="$ARG_DIR"
    else
        INSTALL_DIR="$(ask "安装目录（存放配置与数据）" "$DEFAULT_DIR")"
    fi
    INSTALL_DIR="${INSTALL_DIR%/}"
    [ -n "$INSTALL_DIR" ] || die "安装目录不能为空"
    mkdir -p "$INSTALL_DIR"
    INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"

    collect_"$WIZARD_KIND"
    check_container_conflict
    show_summary

    download_templates
    patch_compose

    if [ -f "$INSTALL_DIR/.env" ]; then
        cp -f "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.bak"
        info "已备份旧配置 → .env.bak"
    fi
    write_env_file
    write_config_preseed
    (cd "$INSTALL_DIR" && $SUDO $COMPOSE -f compose.yaml config -q) || die "compose.yaml 校验失败，请检查上方报错"
    ok "配置就绪: compose.yaml + .env（权限 600）"

    # 拉取镜像：全新安装且本地已有 → 跳过；同仓库其他标签（如 :latest）→ 询问标记复用；
    # 都没有 → 拉取（失败可继续用本地镜像）
    IMAGE_REF="$(grep -m1 -E '^[[:space:]]*image:' "$COMPOSE_FILE" | awk '{print $2}' | tr -d '"\r' || true)"
    REPO="${IMAGE_REF%%:*}"
    echo ""
    if $SUDO docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
        ok "本地已存在镜像 ${IMAGE_REF}，跳过拉取"
    else
        ALT_IMG="$($SUDO docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "^${REPO}:" | grep -vE "^${IMAGE_REF}\$" | head -1 || true)"
        if [ -n "$ALT_IMG" ] && ask_yes "本地已有 ${ALT_IMG}（compose 需要 ${IMAGE_REF}）。直接标记为 ${IMAGE_REF} 使用，不再联网拉取？" y; then
            $SUDO docker tag "$ALT_IMG" "$IMAGE_REF"
            ok "已标记 ${ALT_IMG} → ${IMAGE_REF}"
        else
            info "拉取镜像 ${IMAGE_REF}（可能需要几分钟；国内网络慢可配置镜像加速）..."
            if ! (cd "$INSTALL_DIR" && $SUDO $COMPOSE pull); then
                warn "镜像拉取失败。可配置 Docker Hub 镜像加速后重试，例如:"
                echo "  $SUDO tee /etc/docker/daemon.json <<'CFG'"
                echo "  { \"registry-mirrors\": [\"https://docker.1panel.live\", \"https://docker.m.daocloud.io\"] }"
                echo "  CFG"
                echo "  $SUDO systemctl restart docker && bash $0"
                die "已中止。按上方提示配置加速后重新运行即可（已完成的下载会续传）"
            fi
        fi
    fi

    info "启动容器 ..."
    (cd "$INSTALL_DIR" && $SUDO $COMPOSE up -d)

    echo ""
    sleep 3
    $SUDO docker ps --filter "name=${CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

    write_install_info
    show_final
}

write_install_info() {
    local f="$INSTALL_DIR/install-info.txt"
    umask 077
    {
        echo "MSRPilot CN 安装信息（$(date '+%Y-%m-%d %H:%M')）"
        echo "════════════════════════════════════════════"
        if [ "$API_MODE" = "true" ]; then
            echo "管理台   : http://${LAN_IP:-<服务器IP>}:${API_HOST_PORT}/"
            echo "API_TOKEN: ${API_TOKEN_VALUE}"
        else
            echo "管理台   : 未启用"
        fi
        echo "安装目录 : ${INSTALL_DIR}（config/ sessions/ diagnostics/ 为数据目录）"
        echo "主配置   : ${INSTALL_DIR}/.env（账号/授权码）+ config/config.json（行为配置，管理台改）"
        echo "定时     : ${CRON_VALUE}（时区 ${TZ_VALUE}）"
        echo "────────────────────────────────────────────"
        echo "常用命令（在 ${INSTALL_DIR} 下执行）:"
        echo "  docker compose logs -f        查看日志"
        echo "  docker compose restart        重启"
        echo "  docker compose pull && docker compose up -d   升级"
        echo "────────────────────────────────────────────"
        echo "提示:"
        echo "  · 账号在管理台「账号管理」里增删；行为配置在「脚本配置」里改，保存后下次运行生效"
        if [ -z "$LICENSE_VALUE" ]; then
            echo "  · 当前为 24 小时免费试用，到期前在 .env 填 LICENSE_KEY 后执行 docker compose up -d"
        fi
        echo "  · 本文件含 API_TOKEN，请妥善保管（权限 600）"
    } > "$f"
    umask 022
    chmod 600 "$f"
    ok "安装信息已保存: ${f}"
}

show_final() {
    echo ""
    ok "MSRPilot CN 安装完成！"
    echo ""
    echo "  下一步:"
    echo "  1. 浏览器打开管理台 → 输入 API_TOKEN"
    if [ "${#ACC_EMAILS[@]}" -eq 0 ]; then
        echo "  2. 在「账号管理」里添加微软账号并保存"
        echo "  3. 回到「数据概览」点「启动」"
    else
        echo "  2. 回到「数据概览」点「启动」，或等待定时自动运行"
    fi
    if [ "$API_MODE" = "true" ]; then
        echo ""
        echo "  管理台: http://${LAN_IP:-<服务器IP>}:${API_HOST_PORT}/"
    fi
    echo "  信息已存档: ${INSTALL_DIR}/install-info.txt"
    echo ""
}

###############################################################################
# 8. 主流程
###############################################################################
LAN_IP="$(detect_lan_ip)"
CONTAINER_NAME="msrpilot-cn"
INSTALL_DIR=""
MODE="${ARG_MODE:-}"

# 卸载：支持 --uninstall 或菜单
if [ "$MODE" = "uninstall" ]; then
    INSTALL_DIR="$ARG_DIR"
    do_uninstall
fi

# 已有安装检测（有 compose.yaml + .env 即视为已安装）
if [ -z "$MODE" ] && [ -n "$ARG_DIR" ] && [ -f "$ARG_DIR/compose.yaml" ] && [ -f "$ARG_DIR/.env" ]; then
    MODE="upgrade"
fi
if [ -z "$MODE" ] && [ -f "$DEFAULT_DIR/compose.yaml" ] && [ -f "$DEFAULT_DIR/.env" ] && [ -z "$ARG_DIR" ]; then
    MODE="upgrade"
    INSTALL_DIR="$DEFAULT_DIR"
fi
if [ "$MODE" = "upgrade" ] && [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="$ARG_DIR"
fi

if [ "$MODE" = "upgrade" ]; then
    echo "检测到已有安装: ${INSTALL_DIR:-$DEFAULT_DIR}"
    echo "  1) 升级镜像并重启（保留全部配置与数据）"
    echo "  2) 卸载"
    echo "  3) 退出"
    choice="$(ask "请选择" "1")"
    case "$choice" in
        1) : ;;
        2) INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"; do_uninstall ;;
        *) info "已退出。"; exit 0 ;;
    esac
    COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
    ENV_FILE="$INSTALL_DIR/.env"
    API_MODE="$(grep -E '^[[:space:]]*API_MODE:' "$COMPOSE_FILE" | head -1 | grep -oE 'true|false' || true)"
    API_MODE="${API_MODE:-true}"
    API_TOKEN_VALUE="$(grep -E '^API_TOKEN=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
    LICENSE_VALUE="$(grep -E '^LICENSE_KEY=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
    API_HOST_PORT="$(grep -oE '[0-9]+:3010' "$COMPOSE_FILE" | head -1 | cut -d: -f1 || true)"
    API_BIND=""
    CONTAINER_NAME="$(grep -m1 'container_name:' "$COMPOSE_FILE" | awk '{print $2}' | tr -d '"\r' || true)"
    CONTAINER_NAME="${CONTAINER_NAME:-msrpilot-cn}"
    echo ""
    echo "即将拉取新镜像并重建容器（.env / config.json / accounts.json 全部保留）。"
    ask_yes "确认升级？" y || { info "已取消。"; exit 0; }
    echo ""
    info "拉取新镜像 ..."
    if ! (cd "$INSTALL_DIR" && $SUDO $COMPOSE pull); then
        die "镜像拉取失败。可配置镜像加速（daemon.json registry-mirrors）后重试。"
    fi
    info "重建容器 ..."
    (cd "$INSTALL_DIR" && $SUDO $COMPOSE up -d)
    echo ""
    sleep 3
    $SUDO docker ps --filter "name=${CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Status}}'
    ok "升级完成。管理台: http://${LAN_IP:-<服务器IP>}:${API_HOST_PORT:-3010}/"
    exit 0
fi

# 全新安装：选择快速 / 自定义
if [ "$MODE" != "quick" ]; then
    echo ""
    echo "欢迎使用 MSRPilot CN（Docker 版）安装向导"
    echo ""
    echo "  请选择安装方式:"
    echo "    1) 快速安装（推荐 · 默认配置 · 只需填一次账号）"
    echo "    2) 自定义安装（定时 / 端口 / 通知 / 授权码逐步配置）"
    echo "    3) 退出"
    while :; do
        choice="$(ask "请选择" "1")"
        case "$choice" in
            1) MODE="quick"; break ;;
            2) MODE="custom"; break ;;
            3) info "已退出。"; exit 0 ;;
            *) warn "请输入 1 / 2 / 3" ;;
        esac
    done
fi
WIZARD_KIND="$MODE"   # quick | custom → collect_quick / collect_custom

do_install
