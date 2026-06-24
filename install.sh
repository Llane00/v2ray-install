#!/usr/bin/env bash
#
# xray-install — 纯净版 Xray 安装脚本 (Debian/Ubuntu, VLESS + Reality + Vision)
#
# 为什么用 VLESS + Reality:
#   - 裸 VMess/VLESS over TCP 没有 TLS 伪装,流量特征明显,IP 跑一段时间就会被 GFW 封
#   - Reality 借用一个真实大站的 TLS 握手来伪装,无需自己的域名/证书,能扛主动探测
#   - 目前(2025-2026)国内抗封锁综合表现最好、维护成本最低的方案之一
#
# 与常见一键脚本的区别:
#   - 二进制只从 XTLS 官方下载,并强制校验官方 SHA256,失败即终止
#   - 全程走正常 TLS(不使用 --no-check-certificate)
#   - 不关闭系统防火墙,只精确放行用到的那一个端口
#   - 不上传任何配置到第三方
#
# 客户端要求(必须支持 Reality + xtls-rprx-vision):
#   v2rayN / NekoBox / sing-box / Shadowrocket / Clash.Meta(Mihomo)等较新版本均可
#   注意:原版 Clash 不支持 VLESS/Reality,必须用 Mihomo 内核(Clash Verge Rev)
#
# 用法(推荐先下载再执行,便于审查内容、排查问题):
#   curl -fsSL -o install.sh https://你的域名/install.sh
#   bash install.sh             # 安装(默认 Reality 直连)
#   bash install.sh cdn         # 安装 CDN 模式 (VLESS+WS+TLS over Cloudflare, 需已托管在 CF 的域名)
#   bash install.sh info        # 重新打印连接信息(vless 链接 + Clash 配置),只读
#   bash install.sh uninstall   # 卸载
#
# 两种模式怎么选:
#   reality(默认)— 直连 + Reality 伪装,无需域名;适合 IP 干净、追求低延迟
#   cdn           — 套 Cloudflare,把源站 IP 藏到 CF 后面;适合 IP 已被降权/限速、
#                   换 IP 也不想换时(GFW 只看到 Cloudflare 的 IP)。需要一个托管在 CF 的域名。
#
# 可选环境变量(非交互场景):
#   XRAY_PORT=443      指定端口,缺省 443 (Reality 伪装成 HTTPS,落在 443 最自然)
#   XRAY_UUID=...      指定 UUID,缺省自动生成
#   REALITY_SNI=...    [reality] 指定伪装目标站(SNI),缺省 www.microsoft.com
#                      要求:真实、支持 TLS1.3、且国内可正常访问的大站
#   MODE=cdn           安装模式改为 CDN(套 Cloudflare);缺省 reality
#   CDN_DOMAIN=...     [cdn 必填] 已托管在 Cloudflare 的域名/子域(如 cdn.example.com)
#   SSH_PORT=2222      指定新 SSH 端口,缺省保持 22
#   SSH_USER=alice     【必填】要创建的登录用户名,会自动建号并从 root 复制公钥
#                      (非交互模式必须提供;交互模式会提示输入)

set -euo pipefail

red='\033[91m'; green='\033[92m'; yellow='\033[93m'; cyan='\033[96m'; none='\033[0m'
msg()  { echo -e "${green}$*${none}"; }
warn() { echo -e "${yellow}$*${none}"; }
die()  { echo -e "\n${red}错误: $*${none}\n" >&2; exit 1; }

XRAY_BIN_DIR="/usr/local/bin"
XRAY_BIN="${XRAY_BIN_DIR}/xray"
XRAY_DATA_DIR="/usr/local/share/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_KEYS="${XRAY_CONFIG_DIR}/reality.keys"   # 备份 Reality 公私钥(公钥客户端要用)
XRAY_CERT_DIR="${XRAY_CONFIG_DIR}/self-cert"  # CDN 模式自签证书目录(cert.pem/key.pem)
XRAY_SERVICE="/etc/systemd/system/xray.service"
XRAY_LOG_DIR="/var/log/xray"

# 安装模式:reality(默认,直连 + Reality 伪装)| cdn(套 Cloudflare,VLESS+WS+TLS)。
# 影响 gen_config / print_node_info 的分派;info / uninstall 会从已装配置自动识别,无需指定。
MODE="${MODE:-reality}"

# 临时目录用全局 EXIT trap 统一清理。
# 不要在函数内用 `trap ... RETURN`:set -u 下它会泄漏到外层函数(do_install)返回时
# 再次触发,而那时局部 $tmp 已不存在 → "tmp: unbound variable";且 RETURN trap 在
# die(exit)时根本不触发,本就漏清理。EXIT trap 只触发一次,正常/异常退出都能清理。
TMP_DIR=""
cleanup() { [[ -n "${TMP_DIR:-}" ]] && rm -rf "${TMP_DIR}"; return 0; }
trap cleanup EXIT

# ---------------------------------------------------------------- 前置检查

precheck() {
    [[ $(id -u) == 0 ]] || die "请使用 root 用户运行"
    command -v apt-get >/dev/null || die "本脚本仅支持 Debian/Ubuntu (apt)"
    command -v systemctl >/dev/null || die "本脚本依赖 systemd"

    case "$(uname -m)" in
        x86_64|amd64)   XRAY_ARCH="64" ;;
        aarch64|arm64)  XRAY_ARCH="arm64-v8a" ;;
        *) die "不支持的 CPU 架构: $(uname -m)" ;;
    esac
}

install_deps() {
    msg "[1/6] 安装依赖 (curl wget unzip ca-certificates ufw openssl sudo)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    # 极简 Debian 镜像可能没有 sudo(连 sudo 组都不存在),后面 usermod -aG sudo 会失败,故一并安装
    apt-get install -y curl wget unzip ca-certificates ufw openssl sudo >/dev/null
}

# ---------------------------------------------------------------- 下载 + 校验

download_and_verify() {
    msg "[2/6] 查询 XTLS/Xray-core 官方最新版本..."
    local api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    local resp ver=""
    # 先把响应完整缓存到变量,避免 `curl | grep -m1` 中 grep 提前关管道
    # 导致 curl 报 "(23) Failure writing output to destination"
    resp="$(curl -fsSL --connect-timeout 15 --max-time 60 "$api")" \
        || die "获取最新版本失败,请检查服务器到 api.github.com 的网络/DNS"
    # 纯 Bash 正则提取,避免 `printf | grep -m1` 在 set -o pipefail 下因 SIGPIPE
    # (大 JSON 写不进 64KB 管道缓冲、grep -m1 提前关管道)导致脚本静默中止
    if [[ "$resp" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        ver="${BASH_REMATCH[1]}"
    fi
    [[ -n "$ver" ]] || die "解析最新版本失败(GitHub API 可能限流,请稍后重试)"
    msg "    最新版本: ${cyan}${ver}${none}"

    local base="https://github.com/XTLS/Xray-core/releases/download/${ver}"
    local zip_name="Xray-linux-${XRAY_ARCH}.zip"
    TMP_DIR="$(mktemp -d)"; local tmp="$TMP_DIR"   # 由顶部的 EXIT trap 统一清理

    msg "[3/6] 下载二进制及校验文件 (正常 TLS 校验)..."
    # 不使用 --no-check-certificate:保证传输层不被中间人篡改
    # --connect-timeout 限制连接阶段(避免网络不通时无限挂起);不限制总时长,允许慢速大文件下载
    curl -fL --connect-timeout 15 --proto '=https' --tlsv1.2 -o "${tmp}/${zip_name}" "${base}/${zip_name}" \
        || die "下载 ${zip_name} 失败(检查服务器到 github.com 的网络)"
    curl -fL --connect-timeout 15 --proto '=https' --tlsv1.2 -o "${tmp}/${zip_name}.dgst" "${base}/${zip_name}.dgst" \
        || die "下载校验文件 .dgst 失败"

    msg "[4/6] 校验官方 SHA256..."
    local actual
    actual="$(sha256sum "${tmp}/${zip_name}" | awk '{print $1}')"
    # 官方 .dgst 文件里包含该 zip 的多种哈希;只要本地算出的 SHA256 出现在其中即视为通过
    if ! grep -iq "$actual" "${tmp}/${zip_name}.dgst"; then
        echo -e "${red}    本地计算: ${actual}${none}" >&2
        echo -e "${red}    官方 dgst:${none}" >&2
        cat "${tmp}/${zip_name}.dgst" >&2
        die "SHA256 校验不通过,文件可能被篡改或损坏,已终止安装"
    fi
    msg "    校验通过: ${cyan}${actual}${none}"

    msg "[5/6] 安装文件到系统目录..."
    mkdir -p "$XRAY_DATA_DIR" "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR"
    unzip -o "${tmp}/${zip_name}" -d "${tmp}/unzip" >/dev/null
    install -m 755 "${tmp}/unzip/xray" "${XRAY_BIN}"
    # geoip / geosite 数据(路由用,可选)
    if [[ -f "${tmp}/unzip/geoip.dat"   ]]; then install -m 644 "${tmp}/unzip/geoip.dat"   "${XRAY_DATA_DIR}/"; fi
    if [[ -f "${tmp}/unzip/geosite.dat" ]]; then install -m 644 "${tmp}/unzip/geosite.dat" "${XRAY_DATA_DIR}/"; fi

    XRAY_VERSION="$ver"
}

# ---------------------------------------------------------------- 生成密钥/配置

# 解析 `xray x25519` 的输出,结果写入全局 PRIVATE_KEY / PUBLIC_KEY(找不到则留空)。
# 必须兼容多版本不同的标签格式,逐行解析、靠关键字 + 长度判断,而非紧挨着的「标签: 值」正则:
#   旧版:        "Private key: xxx"    / "Public key: yyy"
#   中间版:      "PrivateKey: xxx"     / "Password: yyy"
#   新版(v26+): "PrivateKey: xxx"     / "Password (PublicKey): yyy" / 末尾还多一行 "Hash32: zzz"
# x25519 公私钥是 43 位 base64url;Hash32 也是 43 位,但它那行不含 private/public/password,故靠标签排除。
_parse_x25519_keys() {
    local out="$1" line val
    PRIVATE_KEY=""; PUBLIC_KEY=""
    while IFS= read -r line; do
        val="${line##*:}"                 # 取最后一个冒号之后(避开 "Password (PublicKey):" 这种带括号的标签)
        val="${val//[^A-Za-z0-9_-]/}"     # 只留 base64url 字符,顺带去掉空白/括号残留
        [[ ${#val} -ge 40 ]] || continue  # 太短的不是 key(如空行、纯标签)
        case "$line" in
            *[Pp]rivate*)              if [[ -z "$PRIVATE_KEY" ]]; then PRIVATE_KEY="$val"; fi ;;
            *[Pp]ublic*|*[Pp]assword*) if [[ -z "$PUBLIC_KEY"  ]]; then PUBLIC_KEY="$val";  fi ;;
        esac
    done <<< "$out"
}

# 生成 Reality x25519 密钥对。需要已安装的 xray 二进制(在 download_and_verify 之后调用)。
gen_reality_keys() {
    [[ -x "$XRAY_BIN" ]] || die "未找到可执行的 xray,无法生成 Reality 密钥"
    local out
    out="$("$XRAY_BIN" x25519 2>/dev/null)" || die "生成 Reality 密钥对失败 (xray x25519)"
    _parse_x25519_keys "$out"
    [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] \
        || die "解析 Reality 密钥失败,xray x25519 输出异常:
${out}"
}

# 生成配置:按 MODE 分派(reality 直连伪装 / cdn 套 Cloudflare WS+TLS)
gen_config() {
    case "$MODE" in
        reality) gen_config_reality ;;
        cdn)     gen_config_cdn ;;
        *) die "未知 MODE: $MODE" ;;
    esac
}

gen_config_reality() {
    msg "[6/6] 生成密钥、配置、服务与防火墙规则 (Reality)..."

    UUID="${XRAY_UUID:-$(cat /proc/sys/kernel/random/uuid)}"

    # 端口:默认 443(Reality 伪装成 HTTPS,落在 443 最自然、最不打眼)
    if [[ -n "${XRAY_PORT:-}" ]]; then
        PORT="$XRAY_PORT"
    elif [[ -t 0 ]]; then
        read -rp "$(echo -e "请输入 Xray 端口 [回车默认 ${cyan}443${none}]: ")" PORT
        PORT="${PORT:-443}"
    else
        PORT=443
    fi
    [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "端口非法: $PORT"

    # 伪装目标站(SNI):客户端用它做 SNI,服务端用它的 :443 中转真实 TLS 握手
    SNI="${REALITY_SNI:-www.microsoft.com}"
    [[ "$SNI" =~ ^[A-Za-z0-9.-]+$ ]] || die "SNI 非法: $SNI"

    # 生成 Reality 密钥对(需要已安装的 xray 二进制)
    gen_reality_keys

    # shortId:8 字节随机 hex(客户端需带相同值;不放空串,等于强制校验)
    SHORT_ID="$(openssl rand -hex 8)"
    [[ "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || die "生成 shortId 失败,请确认 openssl 可用"

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

    # config.json 里只有私钥;公钥客户端连接时要用(pbk),另存一份便于 info 重打印 / 备份
    cat > "$XRAY_KEYS" <<EOF
PrivateKey: ${PRIVATE_KEY}
PublicKey: ${PUBLIC_KEY}
EOF
    chmod 600 "$XRAY_KEYS"
}

# CDN 模式:VLESS + WebSocket + TLS,套在 Cloudflare 后面。
# 客户端连「域名」(解析到 CF)→ CF 回源到本机 443 → Xray 处理 WS+TLS。
# 源站用自签证书,Cloudflare SSL/TLS 模式需设为「Full」(CF 不校验源站证书)。
gen_config_cdn() {
    msg "[6/6] 生成证书、配置、服务与防火墙规则 (CDN: VLESS+WS+TLS)..."

    UUID="${XRAY_UUID:-$(cat /proc/sys/kernel/random/uuid)}"

    # 端口:Cloudflare 免费版回源走 443(HTTPS),所以源站固定监听 443
    if [[ -n "${XRAY_PORT:-}" ]]; then
        PORT="$XRAY_PORT"
        [[ "$PORT" == 443 ]] || warn "    注意:你指定了非 443 端口 ($PORT);Cloudflare 免费版回源默认走 443,非 443 需额外配 Origin Rules,否则连不上"
    else
        PORT=443
    fi
    [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "端口非法: $PORT"

    # 域名(必填):客户端连它(它解析到 Cloudflare),CF 再回源到本机
    if [[ -z "${CDN_DOMAIN:-}" ]]; then
        if [[ -t 0 ]]; then
            while [[ -z "${CDN_DOMAIN:-}" ]]; do
                read -rp "$(echo -e "请输入已托管在 Cloudflare 的域名/子域 (如 ${cyan}cdn.example.com${none}, ${red}必填${none}): ")" CDN_DOMAIN
            done
        else
            die "CDN 模式必须通过 CDN_DOMAIN=<你的域名> 指定(需已托管在 Cloudflare)"
        fi
    fi
    [[ "$CDN_DOMAIN" =~ ^[A-Za-z0-9.-]+$ && "$CDN_DOMAIN" == *.* ]] || die "域名非法: $CDN_DOMAIN"

    # WS 路径:随机密钥路径(客户端要带相同值;等于一道弱口令,挡掉无脑扫描)
    WS_PATH="/$(openssl rand -hex 8)"

    # 自签证书(仅 CF↔源站这段加密;CF 设 Full 模式不校验它)
    gen_self_signed_cert

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${CDN_DOMAIN}",
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "${XRAY_CERT_DIR}/cert.pem",
              "keyFile": "${XRAY_CERT_DIR}/key.pem"
            }
          ]
        },
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF
}

# 生成自签 TLS 证书到 XRAY_CERT_DIR(EC P-256,CN=域名,10 年有效)。
# 仅用于 Cloudflare「Full」模式下 CF↔源站的加密——CF 不校验该证书,故无需受信任 CA。
gen_self_signed_cert() {
    mkdir -p "$XRAY_CERT_DIR"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${XRAY_CERT_DIR}/key.pem" -out "${XRAY_CERT_DIR}/cert.pem" \
        -days 3650 -nodes -subj "/CN=${CDN_DOMAIN}" >/dev/null 2>&1 \
        || die "生成自签证书失败,请确认 openssl 可用"
    chmod 600 "${XRAY_CERT_DIR}/key.pem"
    chmod 644 "${XRAY_CERT_DIR}/cert.pem"
}

# 启动前自检:校验二进制可执行 + 配置文件合法
verify_config() {
    msg "    自检: 校验二进制与配置..."
    local ver_out
    # 不用 `... | head -1`:xray version 逐行输出,head 读完首行就关管道,
    # set -o pipefail 下 xray 写后续行会收到 SIGPIPE(退出 141),被误判为"二进制无法执行"。
    # 先整体捕获(无管道),再用 bash 参数展开取首行。
    ver_out="$("$XRAY_BIN" version 2>/dev/null)" \
        || die "二进制无法执行,安装可能损坏"
    ver_out="${ver_out%%$'\n'*}"
    msg "    二进制: ${cyan}${ver_out}${none}"

    if ! _xray_test_config; then
        echo -e "${red}    配置校验输出:${none}" >&2
        XRAY_LOCATION_ASSET="$XRAY_DATA_DIR" "$XRAY_BIN" run -test -c "$XRAY_CONFIG" >&2 2>&1 || true
        die "配置文件未通过 Xray 自检,已终止(未启动服务)"
    fi
    msg "    配置合法 ✓"
}

# 仅做配置校验(不启动服务)。不同 Xray 版本的 test 子命令/旗标写法不同,逐个尝试。
# 这几种写法都带 test 语义,即使旗标不支持也只会快速报错退出,不会真的把服务跑起来挂住。
_xray_test_config() {
    XRAY_LOCATION_ASSET="$XRAY_DATA_DIR" "$XRAY_BIN" run -test -c "$XRAY_CONFIG"  >/dev/null 2>&1 && return 0
    XRAY_LOCATION_ASSET="$XRAY_DATA_DIR" "$XRAY_BIN" test -c "$XRAY_CONFIG"       >/dev/null 2>&1 && return 0
    XRAY_LOCATION_ASSET="$XRAY_DATA_DIR" "$XRAY_BIN" -test -config "$XRAY_CONFIG" >/dev/null 2>&1 && return 0
    return 1
}

install_service() {
    cat > "$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
Environment=XRAY_LOCATION_ASSET=${XRAY_DATA_DIR}
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
}

# ---------------------------------------------------------------- BBR 加速

# 开启 BBR 拥塞控制 + fq 队列(提升跨境/丢包链路的吞吐)。
# 幂等:写独立 drop-in 文件,重复运行直接覆盖,不污染 /etc/sysctl.conf。
# 内核不支持时只 warn 跳过,不中断安装。
setup_bbr() {
    msg "[BBR] 开启 BBR 拥塞控制 + fq 队列..."
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    modprobe tcp_bbr 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true

    # 验证是否真生效(老内核会静默回退到原算法)
    local cc qd
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [[ "$cc" == "bbr" ]]; then
        msg "    已启用 BBR (qdisc=${qd:-未知})"
    else
        warn "    当前内核未启用 BBR (拥塞控制=${cc:-未知});可能内核过旧不支持,已跳过(不影响其余安装)"
    fi
}

# ---------------------------------------------------------------- 防火墙

# 确定 SSH 端口(用户自定义,默认保持 22)
prompt_ssh_port() {
    if [[ -n "${SSH_PORT:-}" ]]; then
        :
    elif [[ -t 0 ]]; then
        read -rp "$(echo -e "请输入新的 SSH 端口 [回车保持默认 ${cyan}22${none}]: ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-22}"
    else
        SSH_PORT=22
    fi
    [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) \
        || die "SSH 端口非法: $SSH_PORT"
    # 用 if 而非 `[[ ]] && die`:后者作为函数最后一行,正常情况(端口不等)会返回 1,
    # 触发外层 do_install 的 set -e 静默退出(脚本会停在这里,xray 已起但不再继续)。
    if [[ "$SSH_PORT" == "$PORT" ]]; then
        die "SSH 端口不能与 Xray 端口 ($PORT) 相同"
    fi
}

# 配置 ufw:默认拒绝入站、放行出站,只开放 SSH 与 Xray 端口
setup_ufw() {
    msg "[防火墙] 配置 ufw (默认拒绝入站,仅放行 SSH ${SSH_PORT}/tcp 与 Xray ${PORT}/tcp)..."
    ufw default deny incoming  >/dev/null
    ufw default allow outgoing >/dev/null
    # 先放行 SSH 新端口再启用,避免把自己关在门外
    ufw allow "${SSH_PORT}/tcp" >/dev/null
    ufw allow "${PORT}/tcp"     >/dev/null
    # ufw 默认放行 RELATED,ESTABLISHED,启用不会断开当前会话
    ufw --force enable >/dev/null
    # 改了端口就顺手移除旧的 22 放行规则(可能来自之前的 ufw 配置)
    if [[ "$SSH_PORT" != "22" ]]; then
        ufw delete allow 22/tcp >/dev/null 2>&1 || true
        ufw delete allow 22     >/dev/null 2>&1 || true
        warn "    已移除旧 SSH 端口 22 的放行规则"
    fi
    msg "    ufw 已启用"
}

# 强制创建登录用户,并从 root 复制公钥(用户名必填)
create_login_user() {
    # 确定用户名(强制,必须提供)
    if [[ -z "${SSH_USER:-}" ]]; then
        if [[ -t 0 ]]; then
            while [[ -z "${SSH_USER:-}" ]]; do
                read -rp "$(echo -e "请输入要创建的登录用户名 (${red}必填${none}): ")" SSH_USER
            done
        else
            die "必须通过 SSH_USER=<用户名> 指定要创建的登录用户"
        fi
    fi
    [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "用户名不合法: ${SSH_USER}(仅限小写字母/数字/下划线/连字符,且不以数字开头)"
    [[ "$SSH_USER" == "root" ]] && die "登录用户不能是 root,请另选用户名"

    msg "[用户] 创建登录用户 ${cyan}${SSH_USER}${none} 并复制 root 公钥..."

    # 源:root 必须有可用公钥,否则复制后会锁死
    local root_ak="/root/.ssh/authorized_keys"
    if [[ ! -s "$root_ak" ]] || ! grep -qE '^[[:space:]]*(ssh-(rsa|ed25519|dss)|ecdsa-|sk-)' "$root_ak"; then
        die "/root/.ssh/authorized_keys 中没有有效公钥,无法复制。
为防止锁死已终止,请先为 root 配置好 SSH 公钥后重试。"
    fi

    # 创建用户(若不存在);已存在则复用,不破坏其原有 key
    if id "$SSH_USER" >/dev/null 2>&1; then
        warn "    用户 ${SSH_USER} 已存在,将复用(原有公钥会保留,密码会被重置)"
    else
        useradd -m -s /bin/bash "$SSH_USER"
        msg "    已创建用户 ${SSH_USER}"
    fi

    # 赋予 sudo 权限
    usermod -aG sudo "$SSH_USER"
    msg "    已加入 sudo 组"

    # 生成随机密码(用于 sudo / 控制台登录;SSH 仍为仅公钥)
    local raw
    raw="$(openssl rand -base64 24 2>/dev/null || true)"
    raw="${raw//[^A-Za-z0-9]/}"
    GEN_PASSWORD="${raw:0:16}"
    [[ ${#GEN_PASSWORD} -ge 12 ]] || die "生成随机密码失败,请确认 openssl 可用"
    printf '%s:%s\n' "$SSH_USER" "$GEN_PASSWORD" | chpasswd
    msg "    已设置随机密码(安装结束后会打印)"

    local home grp ak
    home="$(getent passwd "$SSH_USER" | cut -d: -f6)"
    [[ -n "$home" ]] || die "无法获取用户 ${SSH_USER} 的家目录"
    grp="$(id -gn "$SSH_USER")"
    ak="${home}/.ssh/authorized_keys"

    mkdir -p "${home}/.ssh"
    touch "$ak"
    # 追加 root 的公钥(逐行去重,不覆盖该用户已有的 key)
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        grep -qxF "$line" "$ak" || printf '%s\n' "$line" >> "$ak"
    done < "$root_ak"

    chmod 700 "${home}/.ssh"
    chmod 600 "$ak"
    chown -R "${SSH_USER}:${grp}" "${home}/.ssh"
    msg "    已将 root 公钥复制到 ${ak}"
}

# SSH 加固:禁用密码登录,仅允许公钥;可改默认端口
harden_ssh() {
    msg "[SSH 加固] 校验公钥并禁用密码登录..."

    # 防呆:root 登录将被禁用,唯一入口是新用户,故必须确认新用户有可用公钥(否则锁死)
    local home akf
    home="$(getent passwd "$SSH_USER" | cut -d: -f6)"
    akf="${home}/.ssh/authorized_keys"
    if [[ ! -s "$akf" ]] || ! grep -qE '^[[:space:]]*(ssh-(rsa|ed25519|dss)|ecdsa-|sk-)' "$akf"; then
        die "用户 ${SSH_USER} 没有可用公钥;禁用 root 登录后将无法登录,已终止以防锁死。"
    fi
    msg "    确认登录入口公钥: ${akf} (用户 ${SSH_USER})"

    local sshd_main="/etc/ssh/sshd_config"
    local dropin_dir="/etc/ssh/sshd_config.d"
    local conf_block="# Managed by xray-install — 请勿手动编辑
Port ${SSH_PORT}
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
UsePAM yes"
    local applied=""

    # 优先用 drop-in:命名 00- 使其先于 cloud-init 的 50- 生效(sshd 取首个匹配值)
    if [[ -d "$dropin_dir" ]] && grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$sshd_main"; then
        local dropin="${dropin_dir}/00-xray-hardening.conf"
        printf '%s\n' "$conf_block" > "$dropin"
        if ! sshd -t 2>/dev/null; then
            rm -f "$dropin"
            sshd -t || true
            die "sshd 配置校验失败,已回滚,未改动 SSH"
        fi
        applied="drop-in: $dropin"
    else
        # 回退:备份并改主配置(先删除已有同名指令,再追加,确保我们的值生效)
        cp -f "$sshd_main" "${sshd_main}.bak.$(date +%s)"
        sed -i -E '/^[[:space:]]*#?[[:space:]]*(Port|PasswordAuthentication|PubkeyAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin)\b/d' "$sshd_main"
        printf '\n%s\n' "$conf_block" >> "$sshd_main"
        if ! sshd -t 2>/dev/null; then
            sshd -t || true
            die "sshd 配置校验失败,请检查 ${sshd_main}(已留有 .bak 备份)"
        fi
        applied="主配置: $sshd_main (已备份 .bak)"
    fi
    msg "    sshd 配置已写入并通过校验 (${applied})"

    # Ubuntu 24.04+ 使用 ssh.socket 套接字激活,sshd_config 的 Port 会被忽略,需覆盖 socket
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        warn "    检测到 ssh.socket 套接字激活,改用 socket 覆盖端口"
        mkdir -p /etc/systemd/system/ssh.socket.d
        printf '[Socket]\nListenStream=\nListenStream=%s\n' "$SSH_PORT" \
            > /etc/systemd/system/ssh.socket.d/override.conf
        systemctl daemon-reload
        systemctl restart ssh.socket
    fi
    # 重启 sshd 应用(已建立的当前会话不受影响)
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    msg "    SSH 已重启:密码登录已禁用,仅允许公钥;端口 = ${cyan}${SSH_PORT}${none}"
}

# ---------------------------------------------------------------- 输出信息

get_ip() {
    local ip
    ip="$(curl -fsSL --connect-timeout 5 --max-time 10 --proto '=https' https://api.ipify.org 2>/dev/null)" \
        || ip="$(curl -fsSL --connect-timeout 5 --max-time 10 https://api.ip.sb/ip 2>/dev/null)" \
        || ip="你的服务器IP"
    echo "$ip"
}

# 渲染节点连接信息:按 MODE 分派。安装结束(print_result)与 `info` 子命令共用。
print_node_info() {
    case "$MODE" in
        reality) print_node_info_reality ;;
        cdn)     print_node_info_cdn ;;
    esac
}

# Reality 直连:VLESS 参数 + vless:// 链接 + Clash(Mihomo)YAML。
# 依赖全局 PORT / UUID / SNI / PUBLIC_KEY / SHORT_ID / XRAY_VERSION。
print_node_info_reality() {
    local ip; ip="$(get_ip)"
    local name="Reality-${ip}"
    # vless://UUID@IP:PORT?参数#备注  —— 主流客户端可直接扫码/粘贴导入
    local link="vless://${UUID}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F&type=tcp#${name}"

    echo -e "  版本     : ${cyan}${XRAY_VERSION}${none}"
    echo -e "  地址     : ${cyan}${ip}${none}"
    echo -e "  端口     : ${cyan}${PORT}${none}"
    echo -e "  UUID     : ${cyan}${UUID}${none}"
    echo -e "  传输     : ${cyan}VLESS + Reality (TCP)${none}"
    echo -e "  流控flow : ${cyan}xtls-rprx-vision${none}"
    echo -e "  SNI/伪装 : ${cyan}${SNI}${none}"
    echo -e "  公钥 pbk : ${cyan}${PUBLIC_KEY}${none}"
    echo -e "  shortId  : ${cyan}${SHORT_ID}${none}"
    echo -e "  指纹 fp  : ${cyan}chrome${none}"
    echo
    echo -e "  导入链接 : ${green}${link}${none}"
    echo
    echo -e "  ${cyan}Clash.Meta / Mihomo${none}(原版 Clash 不支持 VLESS/Reality,必须用 Mihomo 内核):"
    echo -e "  ${yellow}Clash Verge Rev:新建配置 → 类型选「Local / 本地」→ 粘贴整份 → 保存启用${none}"
    echo -e "  ${yellow}已有 Clash 配置:只取下面 proxies: 那一段,加进你现有配置即可${none}"
    echo
    # 故意顶格输出(不跟随上面的缩进框):Clash 配置的顶层键必须在 YAML 第 0 列,
    # 顶格才能整份直接粘贴。内部不加颜色,避免 ANSI 码混进 YAML 破坏复制。
    # 这是一份「完整可跑」的最小配置(proxies + proxy-groups + rules),
    # 因为独立的本地配置必须含路由规则才能真正分流;只有 proxies 段 Clash 起不来。
    cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: "${name}"
    type: vless
    server: ${ip}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: chrome
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "${name}"
      - DIRECT
rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
}

# CDN 套 Cloudflare:VLESS + WS + TLS。客户端连「域名」(经 Cloudflare 回源),
# 依赖全局 PORT / UUID / CDN_DOMAIN / WS_PATH / XRAY_VERSION。
print_node_info_cdn() {
    local ip; ip="$(get_ip)"
    local name="CDN-${CDN_DOMAIN}"
    local path_enc="%2F${WS_PATH#/}"   # 分享链接里路径的前导 / 需 url 编码
    local link="vless://${UUID}@${CDN_DOMAIN}:443?encryption=none&security=tls&sni=${CDN_DOMAIN}&fp=chrome&type=ws&host=${CDN_DOMAIN}&path=${path_enc}#${name}"

    echo -e "  版本     : ${cyan}${XRAY_VERSION}${none}"
    echo -e "  连接域名 : ${cyan}${CDN_DOMAIN}${none}  (客户端连它, 走 Cloudflare)"
    echo -e "  源站 IP  : ${cyan}${ip}${none}  (填到 Cloudflare 的 A 记录)"
    echo -e "  端口     : ${cyan}443${none}"
    echo -e "  UUID     : ${cyan}${UUID}${none}"
    echo -e "  传输     : ${cyan}VLESS + WS + TLS (经 Cloudflare CDN)${none}"
    echo -e "  WS 路径  : ${cyan}${WS_PATH}${none}"
    echo -e "  SNI/Host : ${cyan}${CDN_DOMAIN}${none}"
    echo -e "  指纹 fp  : ${cyan}chrome${none}"
    echo
    echo -e "  导入链接 : ${green}${link}${none}"
    echo
    echo -e "  ${cyan}Clash.Meta / Mihomo${none}(原版 Clash 不支持 VLESS,必须用 Mihomo 内核):"
    echo -e "  ${yellow}Clash Verge Rev:新建配置 → 类型选「Local / 本地」→ 粘贴整份 → 保存启用${none}"
    echo
    cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: "${name}"
    type: vless
    server: ${CDN_DOMAIN}
    port: 443
    uuid: ${UUID}
    udp: true
    tls: true
    servername: ${CDN_DOMAIN}
    network: ws
    client-fingerprint: chrome
    ws-opts:
      path: ${WS_PATH}
      headers:
        Host: ${CDN_DOMAIN}
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "${name}"
      - DIRECT
rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
    echo
    echo -e "  ${cyan}!! Cloudflare 必须配好这两步, 否则连不上 !!${none}"
    echo -e "  ${yellow}1) DNS 加 A 记录: ${CDN_DOMAIN} → ${ip}, 橙色云(Proxied)必须开启${none}"
    echo -e "  ${yellow}2) SSL/TLS 加密模式设为 Full(不是 Flexible, 也不是 Full strict)${none}"
    echo -e "  ${yellow}   设完等几分钟让 CF 边缘证书变 Active, 再用客户端连${none}"
}

print_result() {
    echo
    echo "================= 安装完成 ================="
    print_node_info
    echo
    echo "  管理命令 : systemctl {status|restart|stop} xray"
    echo "  配置文件 : ${XRAY_CONFIG}"
    if [[ "$MODE" == reality ]]; then
        echo "  密钥备份 : ${XRAY_KEYS}"
    else
        echo "  证书目录 : ${XRAY_CERT_DIR}"
    fi
    echo "--------------------------------------------"
    echo -e "  SSH 端口 : ${cyan}${SSH_PORT}${none}"
    echo -e "  登录用户 : ${cyan}${SSH_USER}${none} (已复制 root 公钥, 已加 sudo)"
    echo -e "  用户密码 : ${cyan}${GEN_PASSWORD}${none}  (用于 sudo / 控制台, 非 SSH 登录)"
    echo -e "  root登录 : ${cyan}已禁用${none}"
    echo -e "  SSH 登录 : ${cyan}已禁用密码, 仅允许公钥${none}"
    echo "============================================"
    echo
    warn "重要:root 登录已禁用!以后只能用新用户 + 公钥 + 新端口登录:"
    warn "      ssh -p ${SSH_PORT} ${SSH_USER}@${ip}"
    warn "请务必保持当前会话不要断开,先开新窗口用上面命令验证登录成功,再关闭当前会话!"
    if [[ "$SSH_PORT" != "22" ]]; then
        warn "另外:云厂商控制台的安全组/防火墙也要放行 TCP ${SSH_PORT},否则会连不上。"
    fi
    echo
    warn "请立刻保存上面的【用户密码】,它不会再次显示;sudo 与控制台登录都需要它。"
    echo
}

# ---------------------------------------------------------------- info 子命令

# `info` 子命令:从已安装的 config.json + reality.keys 读取参数,重新打印节点连接信息
# (vless:// 链接 + Clash YAML)。纯只读,不改动任何配置或服务。
# 用途:之前装过、想再次拿到连接信息时,无需(也不应)重跑安装——重装会生成
# 新的 UUID/端口/密钥,等于换了节点,现有客户端全部失效。
show_info() {
    [[ -f "$XRAY_CONFIG" ]] || die "未找到 ${XRAY_CONFIG},请确认已用本脚本安装过 Xray"
    [[ -r "$XRAY_CONFIG" ]] || die "无权读取 ${XRAY_CONFIG},请用 root 运行: sudo bash $0 info"

    # 解析:沿用脚本一贯的「整体捕获 + bash 正则」写法,不经 grep|head 管道,
    # 避免在 set -o pipefail 下因 SIGPIPE 误伤(理由同 verify_config)。
    local content; content="$(cat "$XRAY_CONFIG")"

    # 自动识别安装模式(Reality 直连 / CDN 套 WS),据此决定怎么解析与打印
    if [[ "$content" == *realitySettings* ]]; then
        MODE=reality
    elif [[ "$content" == *wsSettings* ]]; then
        MODE=cdn
    else
        die "无法识别配置类型(既非 Reality 也非 WS/CDN),${XRAY_CONFIG} 可能被改过"
    fi

    # 公共字段:端口 + UUID
    PORT=""; UUID=""
    if [[ "$content" =~ \"port\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then PORT="${BASH_REMATCH[1]}"; fi
    if [[ "$content" =~ ([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}) ]]; then UUID="${BASH_REMATCH[1]}"; fi
    [[ -n "$PORT" && -n "$UUID" ]] || die "无法从 ${XRAY_CONFIG} 解析端口/UUID(配置可能被手动改过)"

    if [[ "$MODE" == reality ]]; then
        SNI=""; SHORT_ID=""
        if [[ "$content" =~ \"serverNames\"[[:space:]]*:[[:space:]]*\[[[:space:]]*\"([^\"]+)\" ]]; then SNI="${BASH_REMATCH[1]}"; fi
        if [[ "$content" =~ \"shortIds\"[[:space:]]*:[[:space:]]*\[[[:space:]]*\"([^\"]*)\" ]]; then SHORT_ID="${BASH_REMATCH[1]}"; fi
        [[ -n "$SNI" ]] || die "无法从 ${XRAY_CONFIG} 解析 SNI(配置可能被手动改过)"

        # 公钥:优先读备份文件,其次用 config 里的私钥反推(老/新版 xray 旗标可能不同,失败则标未知)
        PUBLIC_KEY=""
        if [[ -f "$XRAY_KEYS" ]]; then
            local kc; kc="$(cat "$XRAY_KEYS")"
            if [[ "$kc" =~ [Pp]ublic[Kk]ey:[[:space:]]*([A-Za-z0-9_-]+) ]]; then PUBLIC_KEY="${BASH_REMATCH[1]}"; fi
        fi
        if [[ -z "$PUBLIC_KEY" ]]; then
            local priv=""
            if [[ "$content" =~ \"privateKey\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]]; then priv="${BASH_REMATCH[1]}"; fi
            if [[ -n "$priv" && -x "$XRAY_BIN" ]]; then
                # 新版 xray 用 `xray x25519 -i <私钥>` 反推公钥;输出格式同 gen,交给同一解析器
                local d; d="$("$XRAY_BIN" x25519 -i "$priv" 2>/dev/null || true)"
                _parse_x25519_keys "$d"   # 设置 PUBLIC_KEY(也会动全局 PRIVATE_KEY,info 不使用,无影响)
            fi
        fi
        [[ -n "$PUBLIC_KEY" ]] || PUBLIC_KEY="(未知,请查看 ${XRAY_KEYS})"
    else
        # CDN:从 tlsSettings.serverName 取域名、wsSettings.path 取路径
        CDN_DOMAIN=""; WS_PATH=""
        if [[ "$content" =~ \"serverName\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then CDN_DOMAIN="${BASH_REMATCH[1]}"; fi
        if [[ "$content" =~ \"path\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then WS_PATH="${BASH_REMATCH[1]}"; fi
        [[ -n "$CDN_DOMAIN" && -n "$WS_PATH" ]] || die "无法从 ${XRAY_CONFIG} 解析域名/WS 路径(配置可能被手动改过)"
    fi

    # 版本:整体捕获二进制输出取首行(不用 head,理由同 verify_config);取不到则标「未知」
    local vraw=""
    if [[ -x "$XRAY_BIN" ]]; then
        vraw="$("$XRAY_BIN" version 2>/dev/null || true)"
    fi
    XRAY_VERSION="${vraw%%$'\n'*}"
    XRAY_VERSION="${XRAY_VERSION:-未知}"

    echo
    echo "================ 节点连接信息 ================"
    print_node_info
    echo "============================================="
    echo
}

# ---------------------------------------------------------------- 卸载

uninstall() {
    precheck
    warn "正在卸载 Xray..."
    systemctl disable --now xray >/dev/null 2>&1 || true
    rm -f "$XRAY_SERVICE"
    systemctl daemon-reload
    rm -f "${XRAY_BIN}"
    rm -rf "$XRAY_DATA_DIR" "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR"
    msg "卸载完成。"
    warn "注意: 之前放行的防火墙端口规则未自动移除,如需清理请手动操作。"
}

# ---------------------------------------------------------------- 主流程

# 注意:函数名不能叫 install,否则会覆盖 /usr/bin/install 命令,
# 导致 download_and_verify 里的 `install -m 755 ...` 递归调用本函数而死循环。
do_install() {
    [[ "$MODE" =~ ^(reality|cdn)$ ]] || die "未知 MODE: $MODE (可用: reality | cdn)"
    precheck
    install_deps
    download_and_verify
    gen_config
    verify_config
    install_service
    setup_bbr
    prompt_ssh_port
    create_login_user
    setup_ufw
    harden_ssh
    sleep 1
    systemctl is-active --quiet xray || die "Xray 启动失败,请运行: journalctl -u xray -n 50"
    print_result
}

case "${1:-install}" in
    install)   do_install ;;
    cdn)       MODE=cdn; do_install ;;
    uninstall) uninstall ;;
    info)      show_info ;;
    *) die "未知参数: $1 (可用: install | cdn | uninstall | info)" ;;
esac
