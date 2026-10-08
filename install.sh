#!/usr/bin/env bash
###############################################################################
# MSRPilot CN（Docker 版）交互式一键安装脚本
#
# 用法:
#   bash install.sh                 # 全程交互式安装
#   bash install.sh --dir /opt/msrpilot-cn
#   bash install.sh --dir=/opt/msrpilot-cn
#
# compose.yaml 与 .env 模板均从 GitHub 仓库下载（脚本不内置任何副本）:
#   https://github.com/DemonRR/msrpilot-cn  (master 分支)
#   直连失败会自动通过 gh-proxy.com 加速重试；
#   可用环境变量自定义:
#     MSRPILOT_GH_PROXY=<加速前缀>      → 默认 https://gh-proxy.com/
#     MSRPILOT_COMPOSE_URL=<完整链接>    → compose.yaml（优先于上面规则）
#     MSRPILOT_ENV_URL=<完整链接>        → env.example（优先于上面规则）
#   下载失败会终止安装并给出解决办法。
#
# 脚本会:
#   1. 检查 / 安装 Docker 与 Docker Compose
#   2. 交互式收集配置（定时、账号、Web 管理台、授权码等）
#   3. 在安装目录生成 .env，并按你的选择对 compose.yaml 做最小修改
#   4. 拉取镜像并启动容器
###############################################################################

set -euo pipefail

# ── 默认值（可用环境变量覆盖）────────────────────────────────────────────
# 环境变量里可能混入粘贴带来的空格/回车符（curl 会报 URL malformed），统一剥掉
COMPOSE_URL="$(printf '%s' "${MSRPILOT_COMPOSE_URL:-https://raw.githubusercontent.com/DemonRR/msrpilot-cn/master/compose.yaml}" | tr -d ' \r')"
ENV_URL="$(printf '%s' "${MSRPILOT_ENV_URL:-https://raw.githubusercontent.com/DemonRR/msrpilot-cn/master/env.example}" | tr -d ' \r')"
# GitHub 直连失败时的自动加速前缀（结尾自动补 /）
GH_PROXY="${MSRPILOT_GH_PROXY:-https://gh-proxy.com/}"
GH_PROXY="${GH_PROXY%/}/"
DEFAULT_TZ="Asia/Shanghai"
DEFAULT_CRON="30 7 * * *;30 15 * * *"
API_CONTAINER_PORT="3010"

# ── 输出样式 ────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;36m'; C_0='\033[0m'
else
    C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi
info()  { printf "${C_B}[INFO]${C_0} %s\n" "$*"; }
ok()    { printf "${C_G}[ OK ]${C_0} %s\n" "$*"; }
warn()  { printf "${C_Y}[WARN]${C_0} %s\n" "$*"; }
err()   { printf "${C_R}[FAIL]${C_0} %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ── 执行方式保护 ────────────────────────────────────────────────────────
# 本脚本是交互式的：`curl ... | bash` 会让 read 把脚本正文当成用户输入。
# 检测到脚本本身来自 stdin 时立即终止并给出正确用法。
case "$0" in
    bash|sh|dash)
        if [ ! -t 0 ]; then
            err "脚本正通过 stdin 执行（如 curl ... | bash），交互式输入会失效。"
            err "正确用法:  bash <(curl -fsSL <脚本地址>)"
            err "或者:      curl -fsSL <脚本地址> -o install.sh && bash install.sh"
            exit 1
        fi
        ;;
esac
# 用 sh 启动时自动切到 bash（脚本依赖 bash 特性）
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

# ── 交互输入辅助 ────────────────────────────────────────────────────────
# ask "提示" "默认值"  →  输入为空时返回默认值；EOF 时同样回落默认值
ask() {
    local ans=""
    read -r -p "$1 [$2]: " ans || ans=""
    printf '%s' "${ans:-$2}"
}

# ask_yes "提示" y|n  →  返回 0 表示是，1 表示否
ask_yes() {
    local ans
    while :; do
        read -r -p "$1 [$2]: " ans || ans=""
        ans="${ans:-$2}"
        case "$ans" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
        esac
        warn "请输入 y 或 n"
    done
}

# 简单校验: cron 表达式（分号分隔多段，每段 5 个字段）
# 注意: 必须用 read -a 分词，arr=($seg) 会让 '*' 触发文件名展开
is_valid_cron() {
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
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

gen_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# ── 参数解析 ────────────────────────────────────────────────────────────
ARG_DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir)    [ -n "${2:-}" ] || die "--dir 需要一个路径参数"; ARG_DIR="$2"; shift 2 ;;
        --dir=*)  ARG_DIR="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（用法见 $0 --help）" ;;
    esac
done

###############################################################################
# 1. 环境检查: Docker / Compose
###############################################################################
# 仅在当前用户直连 daemon 失败时才借助 sudo（root / docker 组用户无需 sudo）
SUDO=""
if ! docker info >/dev/null 2>&1 \
    && [ "$(id -u)" -ne 0 ] \
    && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

ensure_docker() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        ok "Docker 已安装并可用了: $(docker --version | head -1)"
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        if [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
            ok "通过 sudo 使用 Docker: $(docker --version | head -1)"
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

###############################################################################
# 2. 安装目录 & 已有安装检测
###############################################################################
DEFAULT_DIR="${HOME}/msrpilot-cn"
if [ -n "$ARG_DIR" ]; then
    INSTALL_DIR="$ARG_DIR"
else
    INSTALL_DIR="$(ask "安装目录（存放 .env 与 compose.yaml，数据也在这里）" "$DEFAULT_DIR")"
fi
INSTALL_DIR="${INSTALL_DIR%/}"
[ -n "$INSTALL_DIR" ] || die "安装目录不能为空"
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"

MODE="install"   # install | upgrade
if [ -f "$INSTALL_DIR/compose.yaml" ] && [ -f "$INSTALL_DIR/.env" ]; then
    warn "检测到已有安装: $INSTALL_DIR"
    echo "  1) 升级镜像并重启容器（保留现有 .env 与 compose.yaml）"
    echo "  2) 重新配置安装（旧 .env / compose.yaml 将备份为 *.bak）"
    echo "  3) 退出"
    while :; do
        choice="$(ask "请选择" "1")"
        case "$choice" in
            1) MODE="upgrade"; break ;;
            2) MODE="install"; break ;;
            3) info "已退出，未做任何更改。"; exit 0 ;;
            *) warn "请输入 1 / 2 / 3" ;;
        esac
    done
fi

###############################################################################
# 3. 收集配置
###############################################################################
if [ "$MODE" = "upgrade" ]; then
    info "升级模式: 直接拉取新镜像并重建容器，配置保持不变。"
    # 从现有配置解析摘要所需字段（set -u 需要全部有值）
    ENV_FILE="$INSTALL_DIR/.env"
    COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
    API_MODE="$(grep -E '^[[:space:]]*API_MODE:' "$COMPOSE_FILE" | head -1 | grep -oE 'true|false' || true)"
    API_MODE="${API_MODE:-true}"
    API_TOKEN_VALUE="$(grep -E '^API_TOKEN=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
    LICENSE_VALUE="$(grep -E '^LICENSE_KEY=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
    API_HOST_PORT="$(grep -oE '[0-9]+:3010' "$COMPOSE_FILE" | head -1 | cut -d: -f1 || true)"
    API_BIND=""
    CONTAINER_NAME="$(grep -m1 'container_name:' "$COMPOSE_FILE" | awk '{print $2}' | tr -d '"' || true)"
    CONTAINER_NAME="${CONTAINER_NAME:-ms-rewards-cn}"
    echo ""
    echo "即将拉取镜像: $($SUDO $COMPOSE -f "$COMPOSE_FILE" config 2>/dev/null | grep -m1 'image:' | awk '{print $2}')"
    ask_yes "确认升级？" y || { info "已取消。"; exit 0; }
else
    echo ""
    info "开始收集配置，直接回车即使用 [方括号] 中的默认值。"
    echo ""

    TZ_VALUE="$DEFAULT_TZ"   # 时区固定用默认值；需要改动时直接编辑 compose.yaml 里的 TZ

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

    # ── 账号 ──
    info "配置微软账号（密码可留空 = 走 token 登录；支持 TOTP 两步验证）。"
    info "compose 只透传前 2 个账号，第 3 个及以后的账号请在 Web 管理台\"账号管理\"里添加。"
    ACC_EMAILS=(); ACC_PASS=(); ACC_TOTP=()
    while :; do
        n=${#ACC_EMAILS[@]}
        slot=$((n + 1))
        email="$(ask "  账号 ${slot} 邮箱（留空结束添加）" "")"
        if [ -z "$email" ]; then
            if [ "$n" -eq 0 ]; then
                warn "至少需要 1 个账号，否则任务无法运行。"
                continue
            fi
            break
        fi
        pass="$(ask "  账号 ${slot} 密码（可留空）" "")"
        totp="$(ask "  账号 ${slot} TOTP 密钥（可留空）" "")"
        ACC_EMAILS+=("$email"); ACC_PASS+=("$pass"); ACC_TOTP+=("$totp")
        ok "  已添加账号 ${slot}: ${email}"
    done

    # ── Web 管理台 ──
    API_MODE="true"; API_HOST_PORT=""; API_BIND=""; API_TOKEN_VALUE=""
    if ask_yes "启用 Web 管理台 (API_MODE，浏览器管理运行/日志/账号)？" y; then
        while :; do
            API_HOST_PORT="$(ask "  管理台端口（宿主机）" "$API_CONTAINER_PORT")"
            is_valid_port "$API_HOST_PORT" && break
            warn "端口必须是 1-65535 的数字"
        done
        if ask_yes "  仅本机访问 (127.0.0.1)？选否则监听所有网卡（远程服务器选否）" n; then
            API_BIND="127.0.0.1:"
        else
            API_BIND=""
        fi
    else
        API_MODE="false"
    fi
    # compose.yaml 中 API_TOKEN 为必填插值项（:?），无论是否开启管理台都要写入 .env
    if ask_yes "自动生成 API_TOKEN（管理台访问令牌）？" y; then
        API_TOKEN_VALUE="$(gen_token)"
    else
        while [ -z "$API_TOKEN_VALUE" ]; do
            API_TOKEN_VALUE="$(ask "  请输入 API_TOKEN" "")"
            [ -n "$API_TOKEN_VALUE" ] || warn "API_TOKEN 不能为空"
        done
    fi

    # ── 授权 ──
    echo ""
    info "授权: 首次启动自动开始 24 小时免费体验；有授权码可现在填入。"
    LICENSE_VALUE="$(ask "LICENSE_KEY 授权码（可留空，稍后在 .env 补填）" "")"

    # ── PushPlus 通知 ──
    PUSHPLUS_TOKEN_VALUE=""
    if ask_yes "配置 PushPlus 微信通知（任务完成推送运行摘要）？" n; then
        while [ -z "$PUSHPLUS_TOKEN_VALUE" ]; do
            PUSHPLUS_TOKEN_VALUE="$(ask "  PushPlus Token（pushplus.plus 微信登录获取）" "")"
            [ -n "$PUSHPLUS_TOKEN_VALUE" ] || warn "Token 不能为空"
        done
    fi

    # ── 汇总确认 ──
    echo ""
    echo "──────────────────────── 配置确认 ────────────────────────"
    echo "  安装目录        : ${INSTALL_DIR}"
    echo "  compose.yaml    : ${COMPOSE_URL}"
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
        echo "    访问地址      : http://<服务器IP>:${API_HOST_PORT}/"
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
fi

###############################################################################
# 4a. 从 GitHub 下载 compose.yaml 与 .env 模板（不再内置任何副本）
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

# 直连失败时自动走 gh-proxy.com 加速重试
gh_fetch_smart() { # $1=url $2=dest → 成功返回 0
    gh_fetch "$1" "$2" && return 0
    warn "GitHub 直连失败，尝试通过 ${GH_PROXY} 加速重试 ..."
    gh_fetch "${GH_PROXY}$1" "$2"
}

if [ "$MODE" = "install" ]; then
    if ! gh_fetch_smart "$COMPOSE_URL" "$INSTALL_DIR/compose.yaml" || ! grep -q '^services:' "$INSTALL_DIR/compose.yaml"; then
        rm -f "$INSTALL_DIR/compose.yaml"
        die "compose.yaml 下载失败（直连与 gh-proxy 加速均不可用）。
      解决办法（任选其一）后重新运行本脚本:
      1) 换其他加速前缀:   MSRPILOT_GH_PROXY=<加速前缀> bash $0
      2) 指定完整下载链接: MSRPILOT_COMPOSE_URL=<链接> bash $0
      3) 手动下载 compose.yaml 放入 ${INSTALL_DIR} 后重新运行"
    fi
    ok "已下载 compose.yaml"

    if ! gh_fetch_smart "$ENV_URL" "$INSTALL_DIR/.env.example" || ! grep -q '^API_TOKEN=' "$INSTALL_DIR/.env.example"; then
        rm -f "$INSTALL_DIR/.env.example"
        die ".env 模板下载失败（直连与 gh-proxy 加速均不可用）。
      解决办法（任选其一）后重新运行本脚本:
      1) 换其他加速前缀:   MSRPILOT_GH_PROXY=<加速前缀> bash $0
      2) 指定完整下载链接: MSRPILOT_ENV_URL=<链接> bash $0
      3) 手动下载 env.example 放入 ${INSTALL_DIR} 并改名为 .env.example 后重新运行"
    fi
    ok "已下载 .env 模板（.env.example）"
fi

###############################################################################
# 4b. 按向导选择对 compose.yaml 做最小修改（安装模式）
###############################################################################
# 把 environment 里 KEY: "..." 形式的值替换为 value
patch_env_kv() { # $1=file $2=key $3=value
    sed -i -E "s|^([[:space:]]*$2:).*$|\1 \"$3\"|" "$1"
}

if [ "$MODE" = "install" ]; then
    COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
    cp -f "$COMPOSE_FILE" "$INSTALL_DIR/compose.yaml.orig"

    patch_env_kv "$COMPOSE_FILE" "TZ" "$TZ_VALUE"
    patch_env_kv "$COMPOSE_FILE" "CRON_SCHEDULES" "$CRON_VALUE"
    patch_env_kv "$COMPOSE_FILE" "RUN_ON_START" "$RUN_ON_START"

    if [ "$API_MODE" = "true" ]; then
        if [ "$API_HOST_PORT" != "$API_CONTAINER_PORT" ] || [ -n "$API_BIND" ]; then
            sed -i -E "s|^([[:space:]]*)- \"[0-9]+:${API_CONTAINER_PORT}\"|\1- \"${API_BIND}${API_HOST_PORT}:${API_CONTAINER_PORT}\"|" "$COMPOSE_FILE"
        fi
    else
        patch_env_kv "$COMPOSE_FILE" "API_MODE" "false"
        # 管理台未启用时注释掉端口映射
        sed -i -E "s|^([[:space:]]*)- \"[0-9]+:${API_CONTAINER_PORT}\"|\1# - \"${API_CONTAINER_PORT}:${API_CONTAINER_PORT}\"|" "$COMPOSE_FILE"
    fi

    # 无实际变化则不保留 .orig
    cmp -s "$COMPOSE_FILE" "$INSTALL_DIR/compose.yaml.orig" && rm -f "$INSTALL_DIR/compose.yaml.orig"

    CONTAINER_NAME="$(grep -m1 'container_name:' "$COMPOSE_FILE" | awk '{print $2}' | tr -d '"' || true)"
    CONTAINER_NAME="${CONTAINER_NAME:-ms-rewards-cn}"
fi

###############################################################################
# 4c. 基于下载的 .env 模板填充配置（compose.yaml 通过 ${VAR} 插值读取）
###############################################################################
# 向模板写入 KEY=VALUE：兼容模板里被注释的行（取消注释并赋值）；
# 值中的 \ | & 会做 sed 转义，模板中没有的键则追加到文件末尾
set_env_kv() { # $1=file $2=key $3=value
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
    for email in "${ACC_EMAILS[@]}"; do
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

# 把 PushPlus 配置直接预置进 config/config.json（行为配置以 config.json 为唯一真源；
# 容器首次启动时 ConfigSync 只会补充缺失键，不会覆盖这里写入的值）
write_config_preseed() {
    [ -n "$PUSHPLUS_TOKEN_VALUE" ] || return 0
    mkdir -p "$INSTALL_DIR/config"
    local f="$INSTALL_DIR/config/config.json"
    if [ -f "$f" ]; then
        info "config/config.json 已存在，跳过预置（PushPlus 可在管理台「脚本配置」里开启）"
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

if [ "$MODE" = "install" ]; then
    if [ -f "$INSTALL_DIR/.env" ]; then
        cp -f "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.bak"
        info "已备份旧配置 → .env.bak"
    fi
    write_env_file
    write_config_preseed
    (cd "$INSTALL_DIR" && $SUDO $COMPOSE -f compose.yaml config -q) || die "compose.yaml 校验失败（含 .env 插值检查），请检查上方报错"
    ok "配置就绪: ${INSTALL_DIR}/compose.yaml + .env（权限 600，模板来自 GitHub）"
fi

###############################################################################
# 5. 拉取镜像并启动
###############################################################################
echo ""
info "拉取镜像（国内网络较慢属正常，重试会续传已完成的层）..."
if ! (cd "$INSTALL_DIR" && $SUDO $COMPOSE pull); then
    warn "镜像拉取失败——若你已通过加速站预拉取镜像（docker pull + tag 回原名），将直接使用本地镜像继续。"
fi

info "启动容器 ..."
(cd "$INSTALL_DIR" && $SUDO $COMPOSE up -d)

echo ""
sleep 3
$SUDO docker ps --filter "name=${CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

###############################################################################
# 6. 完成摘要
###############################################################################
echo ""
ok "MSRPilot CN 安装完成！"
echo ""
echo "  安装目录   : ${INSTALL_DIR}（config/ sessions/ diagnostics/ 数据目录也在这里）"
echo "  主配置文件 : ${INSTALL_DIR}/.env（账号/授权/通知都在这里改）"
if [ -f "$INSTALL_DIR/compose.yaml.orig" ]; then
    echo "  原始模板   : ${INSTALL_DIR}/compose.yaml.orig（按你选择调整过的文件为 compose.yaml）"
fi
echo "  查看日志   : (cd ${INSTALL_DIR} && ${COMPOSE} logs -f)"
if [ "$API_MODE" = "true" ]; then
    echo "  管理台     : http://<服务器IP>:${API_HOST_PORT}/"
    echo "  API_TOKEN  : ${API_TOKEN_VALUE}  （打开页面后按提示输入，仅存浏览器本地）"
fi
if [ -z "$LICENSE_VALUE" ]; then
    echo "  授权       : 首次启动自动开始 24 小时试用；之后在 .env 填 LICENSE_KEY 后执行:"
    echo "               (cd ${INSTALL_DIR} && ${COMPOSE} up -d)"
fi
echo "  常用命令   : ${COMPOSE} restart | stop | down | pull && ${COMPOSE} up -d（升级）"
echo ""
