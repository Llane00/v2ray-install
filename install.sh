#!/usr/bin/env bash
#
# v2ray-install — 纯净版 V2Ray 安装脚本 (Debian/Ubuntu, VMess + TCP)
#
# 与常见一键脚本的区别:
#   - 二进制只从 v2fly 官方下载,并强制校验官方 SHA256,失败即终止
#   - 全程走正常 TLS(不使用 --no-check-certificate)
#   - 不关闭系统防火墙,只精确放行 V2Ray 用到的那一个端口
#   - 不上传任何配置到第三方
#
# 用法(推荐先下载再执行,便于审查内容、排查问题):
#   curl -fsSL -o install.sh https://你的域名/install.sh
#   bash install.sh             # 安装
#   bash install.sh uninstall   # 卸载
#
# 可选环境变量(非交互场景):
#   V2RAY_PORT=12345   指定端口,缺省随机 (20000-65535)
#                      (随机端口用 /dev/urandom 取值,覆盖整个区间)
#   V2RAY_UUID=...     指定 UUID,缺省自动生成
#   SSH_PORT=2222      指定新 SSH 端口,缺省保持 22
#   SSH_USER=alice     【必填】要创建的登录用户名,会自动建号并从 root 复制公钥
#                      (非交互模式必须提供;交互模式会提示输入)

set -euo pipefail

red='\033[91m'; green='\033[92m'; yellow='\033[93m'; cyan='\033[96m'; none='\033[0m'
msg()  { echo -e "${green}$*${none}"; }
warn() { echo -e "${yellow}$*${none}"; }
die()  { echo -e "\n${red}错误: $*${none}\n" >&2; exit 1; }

V2RAY_BIN_DIR="/usr/local/bin"
V2RAY_DATA_DIR="/usr/local/share/v2ray"
V2RAY_CONFIG_DIR="/usr/local/etc/v2ray"
V2RAY_CONFIG="${V2RAY_CONFIG_DIR}/config.json"
V2RAY_SERVICE="/etc/systemd/system/v2ray.service"
V2RAY_LOG_DIR="/var/log/v2ray"

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
        x86_64|amd64)   V2RAY_ARCH="64" ;;
        aarch64|arm64)  V2RAY_ARCH="arm64-v8a" ;;
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
    msg "[2/6] 查询 v2fly 官方最新版本..."
    local api="https://api.github.com/repos/v2fly/v2ray-core/releases/latest"
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

    local base="https://github.com/v2fly/v2ray-core/releases/download/${ver}"
    local zip_name="v2ray-linux-${V2RAY_ARCH}.zip"
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
    mkdir -p "$V2RAY_DATA_DIR" "$V2RAY_CONFIG_DIR" "$V2RAY_LOG_DIR"
    unzip -o "${tmp}/${zip_name}" -d "${tmp}/unzip" >/dev/null
    install -m 755 "${tmp}/unzip/v2ray" "${V2RAY_BIN_DIR}/v2ray"
    # geoip / geosite 数据(路由用,可选)
    if [[ -f "${tmp}/unzip/geoip.dat"   ]]; then install -m 644 "${tmp}/unzip/geoip.dat"   "${V2RAY_DATA_DIR}/"; fi
    if [[ -f "${tmp}/unzip/geosite.dat" ]]; then install -m 644 "${tmp}/unzip/geosite.dat" "${V2RAY_DATA_DIR}/"; fi

    V2RAY_VERSION="$ver"
}

# ---------------------------------------------------------------- 生成配置

# 生成 20000-65535 的随机端口。
# 注意:不能用 `RANDOM % 45535`,因为 $RANDOM 上限仅 32767,取模等于空操作,
# 实际只会落在 20000-52767。这里用 /dev/urandom 取 16 位无符号数覆盖整个区间。
rand_port() {
    local n
    n="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"   # 0-65535
    echo $(( n % 45536 + 20000 ))                      # 20000-65535
}

gen_config() {
    msg "[6/6] 生成配置、服务与防火墙规则..."

    UUID="${V2RAY_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
    if [[ -n "${V2RAY_PORT:-}" ]]; then
        PORT="$V2RAY_PORT"
    elif [[ -t 0 ]]; then
        local rnd; rnd="$(rand_port)"
        read -rp "$(echo -e "请输入 V2Ray 端口 [回车随机 ${cyan}${rnd}${none}]: ")" PORT
        PORT="${PORT:-$rnd}"
    else
        PORT="$(rand_port)"
    fi
    [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "端口非法: $PORT"

    cat > "$V2RAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${V2RAY_LOG_DIR}/access.log",
    "error": "${V2RAY_LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          { "id": "${UUID}", "alterId": 0 }
        ]
      },
      "streamSettings": { "network": "tcp" }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF
}

# 启动前自检:校验二进制可执行 + 配置文件合法
verify_config() {
    msg "    自检: 校验二进制与配置..."
    local ver_out
    # 不用 `... | head -1`:v2ray version 逐行输出,head 读完首行就关管道,
    # set -o pipefail 下 v2ray 写后续行会收到 SIGPIPE(退出 141),被误判为"二进制无法执行"。
    # 先整体捕获(无管道),再用 bash 参数展开取首行。
    ver_out="$("${V2RAY_BIN_DIR}/v2ray" version 2>/dev/null)" \
        || die "二进制无法执行,安装可能损坏"
    ver_out="${ver_out%%$'\n'*}"
    msg "    二进制: ${cyan}${ver_out}${none}"

    # v5: `v2ray test -config`  /  v4: `v2ray -test -config`
    if ! V2RAY_LOCATION_ASSET="$V2RAY_DATA_DIR" "${V2RAY_BIN_DIR}/v2ray" test -config "$V2RAY_CONFIG" >/dev/null 2>&1 \
       && ! V2RAY_LOCATION_ASSET="$V2RAY_DATA_DIR" "${V2RAY_BIN_DIR}/v2ray" -test -config "$V2RAY_CONFIG" >/dev/null 2>&1; then
        echo -e "${red}    配置校验输出:${none}" >&2
        V2RAY_LOCATION_ASSET="$V2RAY_DATA_DIR" "${V2RAY_BIN_DIR}/v2ray" test -config "$V2RAY_CONFIG" >&2 2>&1 || true
        die "配置文件未通过 V2Ray 自检,已终止(未启动服务)"
    fi
    msg "    配置合法 ✓"
}

install_service() {
    cat > "$V2RAY_SERVICE" <<EOF
[Unit]
Description=V2Ray Service
Documentation=https://www.v2fly.org/
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
Environment=V2RAY_LOCATION_ASSET=${V2RAY_DATA_DIR}
ExecStart=${V2RAY_BIN_DIR}/v2ray run -config ${V2RAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable v2ray >/dev/null 2>&1
    systemctl restart v2ray
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
    # 触发外层 do_install 的 set -e 静默退出(脚本会停在这里,v2ray 已起但不再继续)。
    if [[ "$SSH_PORT" == "$PORT" ]]; then
        die "SSH 端口不能与 V2Ray 端口 ($PORT) 相同"
    fi
}

# 配置 ufw:默认拒绝入站、放行出站,只开放 SSH 与 V2Ray 端口
setup_ufw() {
    msg "[防火墙] 配置 ufw (默认拒绝入站,仅放行 SSH ${SSH_PORT}/tcp 与 V2Ray ${PORT}/tcp)..."
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
    local conf_block="# Managed by v2ray-install — 请勿手动编辑
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
        local dropin="${dropin_dir}/00-v2ray-hardening.conf"
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

print_result() {
    local ip; ip="$(get_ip)"
    local vmess_json
    vmess_json="$(cat <<EOF
{"v":"2","ps":"v2ray-${ip}","add":"${ip}","port":"${PORT}","id":"${UUID}","aid":"0","net":"tcp","type":"none","host":"","path":"","tls":""}
EOF
)"
    local link="vmess://$(echo -n "$vmess_json" | base64 -w 0)"

    echo
    echo "================= 安装完成 ================="
    echo -e "  版本     : ${cyan}${V2RAY_VERSION}${none}"
    echo -e "  地址     : ${cyan}${ip}${none}"
    echo -e "  端口     : ${cyan}${PORT}${none}"
    echo -e "  UUID     : ${cyan}${UUID}${none}"
    echo -e "  alterId  : ${cyan}0${none}"
    echo -e "  传输     : ${cyan}VMess + TCP${none}"
    echo
    echo -e "  导入链接 : ${green}${link}${none}"
    echo
    echo "  管理命令 : systemctl {status|restart|stop} v2ray"
    echo "  配置文件 : ${V2RAY_CONFIG}"
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

# ---------------------------------------------------------------- 卸载

uninstall() {
    precheck
    warn "正在卸载 V2Ray..."
    systemctl disable --now v2ray >/dev/null 2>&1 || true
    rm -f "$V2RAY_SERVICE"
    systemctl daemon-reload
    rm -f "${V2RAY_BIN_DIR}/v2ray"
    rm -rf "$V2RAY_DATA_DIR" "$V2RAY_CONFIG_DIR" "$V2RAY_LOG_DIR"
    msg "卸载完成。"
    warn "注意: 之前放行的防火墙端口规则未自动移除,如需清理请手动操作。"
}

# ---------------------------------------------------------------- 主流程

# 注意:函数名不能叫 install,否则会覆盖 /usr/bin/install 命令,
# 导致 download_and_verify 里的 `install -m 755 ...` 递归调用本函数而死循环。
do_install() {
    precheck
    install_deps
    download_and_verify
    gen_config
    verify_config
    install_service
    prompt_ssh_port
    create_login_user
    setup_ufw
    harden_ssh
    sleep 1
    systemctl is-active --quiet v2ray || die "V2Ray 启动失败,请运行: journalctl -u v2ray -n 50"
    print_result
}

case "${1:-install}" in
    install)   do_install ;;
    uninstall) uninstall ;;
    *) die "未知参数: $1 (可用: install | uninstall)" ;;
esac
