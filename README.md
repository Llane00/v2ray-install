# v2ray-install

一个**纯净、可审计**的代理一键安装脚本,面向 **Debian / Ubuntu**,内核为 **Xray-core**,传输协议为 **VLESS + Reality + Vision**。

> 仓库名沿用 `v2ray-install`,但脚本已从 V2Ray(VMess + TCP)升级为 **Xray(VLESS + Reality)**,原因见下。

适用场景:在一台**已经配置好 SSH 公钥登录**的全新云服务器上,一条命令完成代理安装 + 服务器基础加固。

---

## 为什么用 VLESS + Reality

裸 VMess / VLESS over TCP 没有 TLS 伪装,流量特征明显,**IP 跑一段时间(常见 1-3 周)就会被 GFW 识别并封锁**——表现为服务端一切正常、但国内突然连不上。

**Reality** 借用一个真实大站(默认 `www.microsoft.com`)的 TLS 握手来伪装:

- **无需自己的域名和证书**,也不依赖 CDN;
- 对**主动探测**有抵抗力(探测者只会看到那个真实大站的响应);
- 配合 `xtls-rprx-vision` 流控,是目前(2025-2026)国内抗封锁综合表现最好、维护成本最低的方案之一。

---

## 两种模式:直连 Reality(默认)/ 套 Cloudflare CDN

脚本支持两种安装模式:

| | `reality`(默认) | `cdn` |
|---|---|---|
| 协议 | VLESS + Reality + Vision(直连) | VLESS + WS + TLS(经 Cloudflare) |
| 需要域名 | 否 | **是**(需已托管在 Cloudflare) |
| 暴露源站 IP | 是(客户端直连你的 VPS) | **否**(GFW 只看到 Cloudflare 的 IP) |
| 适合 | IP 干净、追求低延迟 | **IP 已被降权 / 限速,又不想换 IP** |

**什么时候上 CDN 模式**:Reality 抗识别很强,但藏不住「你在往一个固定境外 IP 持续灌大流量」这件事——当 IP 被 GFW 按行为 / 信誉**降权限速**时(典型表现:时好时坏、SSH 正常但代理抽风、流量也没超),换协议救不了,换 IP 最直接。如果**不想换 IP**,就用 CDN 模式把源站 IP 藏到 Cloudflare 后面,GFW 只看得到 CF 的 IP。

> **CDN 模式的取舍**:它换来的是**可用性 / 抗封**(CF 的 IP 池极大,几乎封不死),但**不保证更快**——Cloudflare 免费版回国线路质量飘忽,高峰可能比直连还慢。可在客户端用 **Cloudflare 优选 IP** 改善(方法见下方「使用方式 → CDN 模式延迟优化」一节)。

---

## 特性

- **二进制只从 [XTLS/Xray-core 官方仓库](https://github.com/XTLS/Xray-core/releases) 下载**,并**强制校验官方 SHA256**,校验不通过立即终止。
- 下载全程走正常 TLS(不使用 `--no-check-certificate`),并强制 `--proto =https --tlsv1.2`。
- **不关闭防火墙**,而是用 `ufw` 做「默认拒绝入站 + 只放行必要端口」。
- 安装时自动生成 **Reality x25519 密钥对**与随机 shortId;公钥另存一份到 `reality.keys` 备份(客户端连接需要)。
- 安装前做**配置自检**(`xray` 自带的 test),不合法就不启动服务。
- 开启 **BBR + fq**(内核不支持则只告警跳过,不中断)。
- **SSH 加固**:禁用密码登录、**禁用 root 登录**、仅允许公钥、可自定义 SSH 端口;自动创建专用 sudo 用户作为唯一登录入口。
- **不上传任何配置到第三方**,只在本地打印 `vless://` 导入链接(并附一份完整的 Mihomo 配置,可作为「本地配置」直接导入)。
- 单文件、无外部子脚本依赖。

---

## 客户端要求

必须使用**支持 Reality + `xtls-rprx-vision`** 的客户端:

- ✅ v2rayN / v2rayNG、NekoBox / sing-box、Shadowrocket(小火箭)、Clash Verge Rev(Mihomo 内核)等较新版本
- ❌ **原版 Clash 不支持 VLESS / Reality**,Clash 用户必须用 **Mihomo 内核**(如 Clash Verge Rev)

---

## 使用方式

> GitHub 网页地址(`/blob/`)不能直接执行,必须用 **raw** 地址。

> 推荐**先下载到本地再执行**:可以先 `cat install.sh` 审查内容,执行时也保留了正常的标准输入(交互式输入正常),出问题更好排查。

### 安装(交互式)

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/Llane00/v2ray-install/main/install.sh
bash install.sh
```

会依次提示输入:Xray 端口(回车默认 443)、SSH 端口、要创建的登录用户名。

### 安装(全自动,不交互)

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/Llane00/v2ray-install/main/install.sh
SSH_PORT=2222 SSH_USER=你的登录用户名 bash install.sh
```

> 端口缺省即 443(Reality 伪装成 HTTPS,落在 443 最自然);如需指定可加 `XRAY_PORT=...`。
> 伪装站缺省 `www.microsoft.com`,如需更换可加 `REALITY_SNI=...`(要求:真实、支持 TLS1.3、国内可正常访问的大站)。

### 安装(CDN 模式:套 Cloudflare,隐藏源站 IP)

前提:你有一个**已经把 DNS 托管到 Cloudflare** 的域名。

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/Llane00/v2ray-install/main/install.sh
CDN_DOMAIN=cdn.你的域名 SSH_USER=你的登录用户名 bash install.sh cdn
```

装完后,**必须再去 Cloudflare 后台做两步**(脚本结束时也会打印):

1. **DNS** 加一条 A 记录:`cdn.你的域名` → 你的 VPS IP,**橙色云(Proxied)开启**。
2. **SSL/TLS → 概览**,加密模式设为 **Full**(不是 Flexible,也不是 Full strict)。

设完等几分钟,让 Cloudflare 的边缘证书变 Active,再用客户端连。源站用**自签证书**(CF「Full」模式不校验它),所以脚本零额外依赖、不需要 CF API token。

> CDN 模式客户端走 **VLESS + WS + TLS**(不需要 Reality / Vision),兼容的客户端更多;但 Clash 仍需 Mihomo 内核(Clash Verge Rev)。

### CDN 模式延迟优化:Cloudflare 优选 IP

CDN 模式比直连多绕一层,且 **Cloudflare 免费版回国线路经常不优**(客户端可能被分到很远/很挤的 CF 节点),延迟会明显高于直连。解法是 **优选 IP**:让客户端连一个「从你这个网络实测延迟最低、速度又好」的 Cloudflare IP,而 **SNI / Host 仍保持你的域名**——CF 照样凭域名回源到你的 VPS,证书也照常受信。

1. 下载 **[XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest/releases)**(选对应平台:macOS `cfst_darwin_amd64`、Linux `cfst_linux_amd64`、Windows `cfst_windows_amd64`)。

2. **在你常用的设备 / 网络(国内)上跑**——结果按地点 / 运营商而定,必须本地测:

   ```bash
   cd <解压目录>
   # macOS 首次运行被 Gatekeeper 拦的话,先解除隔离:
   xattr -dr com.apple.quarantine .
   chmod +x ./cfst && ./cfst
   ```

   结果写到 `result.csv`,表头:`IP, 发送, 接收, 丢包率, 平均延迟(ms), 下载速度(MB/s), 地区码`。

3. **挑延迟低、下载速度也高的那个**——别只看延迟:很多低延迟 IP 速度只有 0.1 MB/s,刷视频会卡,要两者都好。地区码 `NRT`(东京)/ `HKG`(香港)/ `SIN`(新加坡)离国内近,通常更优。

4. **改客户端**(只改连接地址,域名相关全保持)。Clash Meta:

   ```yaml
     - name: "CDN-cdn.你的域名"
       server: 108.162.198.201          # ← 换成你测出的优选 IP(示例)
       port: 443
       servername: cdn.你的域名          # ← 保持域名(SNI)
       network: ws
       ws-opts:
         path: /你的路径
         headers:
           Host: cdn.你的域名            # ← 保持域名(Host)
   ```

   `vless://` 链接则把 `@cdn.你的域名:443` 改成 `@优选IP:443`,链接里的 `sni=` / `host=` 仍保持域名。

> 优选 IP 不是永久的,CF 节点状态会变,过段时间可重跑 `./cfst` 再选。延迟下限仍受 VPS 物理位置约束——机房离国内越近越低,优选也救不回一台远在美国的机器到「东京档」的延迟。

### 重新获取连接信息(已经装过的机器)

想再次拿到 `vless://` 链接或 Clash 配置时,**不要重跑安装**——重装会生成新的 UUID / 端口 / 密钥,等于换了节点,现有客户端会全部失效。直接在服务器上执行:

```bash
bash install.sh info
```

会从现有 `/usr/local/etc/xray/config.json` 与 `reality.keys` 读出全部参数,重新打印 `vless://` 链接和**完整 Mihomo 配置**。**纯只读,不改动任何配置或服务。**

### 卸载

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/Llane00/v2ray-install/main/install.sh
bash install.sh uninstall
```

> 不建议用 `bash <(curl ...)` 或 `curl | bash` 直接执行:脚本中途出错难以排查,且管道/进程替换在某些情况下会干扰脚本对标准输入的读取。
>
> `raw.githubusercontent.com` 有约 5 分钟 CDN 缓存。刚 push 完想立刻拉到新版,可在 URL 末尾加时间戳绕过缓存:
> ```bash
> curl -fsSL -o install.sh "https://raw.githubusercontent.com/Llane00/v2ray-install/main/install.sh?cb=$(date +%s)"
> ```

---

## 环境变量

| 变量 | 说明 | 缺省 |
|------|------|------|
| `SSH_USER`    | **【必填】** 要创建的登录用户名,脚本会自动建号、加 sudo、生成随机密码并从 root 复制公钥 | 交互模式会提示输入;非交互模式必须提供 |
| `SSH_PORT`    | 新的 SSH 端口 | 保持 `22` |
| `XRAY_PORT`   | Xray 监听端口 | `443` |
| `XRAY_UUID`   | VLESS UUID | 自动生成 |
| `REALITY_SNI` | [reality] Reality 伪装目标站(同时用作 SNI 与中转 dest) | `www.microsoft.com` |
| `MODE`        | 安装模式:`reality`(默认)或 `cdn`(套 Cloudflare) | `reality` |
| `CDN_DOMAIN`  | **【cdn 模式必填】** 已托管在 Cloudflare 的域名/子域(如 `cdn.example.com`) | 交互模式会提示输入 |

> 用户名规则:`^[a-z_][a-z0-9_-]*$`(小写字母/数字/下划线/连字符,**不能以数字开头**)。例如 `llane`、`user1` 可以,`123` 不行。

---

## 脚本做了什么

1. **前置检查**:必须 root、仅 Debian/Ubuntu(apt + systemd)、CPU 为 amd64 或 arm64。
2. **安装依赖**:`curl wget unzip ca-certificates ufw openssl sudo`。
3. **下载并校验**:取 XTLS/Xray-core 最新版本 → 下载 `.zip` 与 `.zip.dgst` → 校验 SHA256。
4. **安装文件**:
   - 二进制 → `/usr/local/bin/xray`
   - 数据(geoip/geosite)→ `/usr/local/share/xray/`
   - 配置 → `/usr/local/etc/xray/config.json`
   - 密钥备份 → `/usr/local/etc/xray/reality.keys`(私钥 + 公钥;公钥客户端要用)
   - 服务 → `/etc/systemd/system/xray.service`
   - 日志 → `/var/log/xray/`
5. **生成配置**:随机 UUID、Reality x25519 密钥对、随机 shortId,写入 VLESS + Reality + Vision 配置。
6. **配置自检**:`xray version` + 配置 test,不通过则不启动服务。
7. **BBR**:写 `/etc/sysctl.d/99-bbr.conf` 开启 BBR + fq 并验证生效(不支持只告警)。
8. **防火墙(ufw)**:默认拒绝入站、放行出站,只放行 SSH 端口与 Xray 端口;若改了端口则移除旧的 22 放行规则。
9. **创建登录用户**(必填用户名):自动建号 → **加入 sudo 组** → **生成 16 位随机密码并设置**(用于 sudo / 控制台,安装结束后打印一次)→ 从 `/root/.ssh/authorized_keys` 复制公钥到新用户(逐行去重、不破坏其原有 key)。若 root 无可用公钥则终止以防锁死。
10. **SSH 加固**:校验新用户已有可用公钥(否则终止)→ 写入 `PasswordAuthentication no` / `PubkeyAuthentication yes` / `PermitRootLogin no` / 自定义 `Port` → `sshd -t` 校验通过后重启。**禁用 root 登录后,唯一入口是上一步创建的新用户。**

---

## ⚠️ 重要安全提示

本脚本会**禁用密码登录、禁用 root 登录、并(可选)修改 SSH 端口**。禁用 root 后,**唯一登录入口就是新建的用户 + 公钥 + 新端口**,操作不当极易把自己锁在服务器外。请务必:

1. **运行前确认 root 已配置好 SSH 公钥**(`/root/.ssh/authorized_keys`)——这是复制给新用户的来源,**root 无可用公钥时脚本会拒绝执行**。脚本会创建 `SSH_USER` 指定的用户、加入 sudo 组、生成随机密码(用于 sudo / 控制台,**安装结束只打印一次,请务必保存**),并把 root 公钥复制过去。**加固后 root 登录被完全禁用(`PermitRootLogin no`),今后只能用新用户登录。**
   > 注意:SSH 仅允许公钥登录;生成的随机密码用于该用户执行 `sudo` 或从云厂商控制台登录,不用于 SSH。
2. **改了 SSH 端口后,先去云厂商控制台的「安全组 / 防火墙」放行新端口**——这是脚本管不到的外层防火墙,也是最常见的锁死原因。
3. 安装完成后,**保持当前 SSH 会话不要断开**,另开一个新窗口用新端口 + 公钥验证能登录成功,再关闭旧会话:
   ```bash
   ssh -p <新端口> <用户>@<服务器IP>
   ```
4. 提前了解你的云厂商 **VNC / 串口控制台**救援入口,以防万一。

---

## 系统要求

- Debian 9+ / Ubuntu 16.04+(使用 `apt` 与 `systemd`)
- 架构:x86_64 (amd64) 或 aarch64 (arm64)
- root 权限
- 已配置 SSH 公钥登录

---

## 安装完成后

脚本会一次性打印:

- **节点信息**:地址、端口、UUID、SNI、公钥(pbk)、shortId、流控,以及可直接导入客户端的 `vless://` 链接,和一份完整的 Mihomo 配置
- **服务器登录**:新用户名、随机密码(用于 sudo / 控制台)、SSH 端口

> **Clash 用户怎么导入**:打印出来的是一份**完整 Mihomo 配置**(原版 Clash 不支持 Reality,需用 Clash Verge Rev 等 Mihomo 内核)。Clash 加订阅通常是填 URL,但本脚本不托管订阅、不传第三方,所以走「本地配置」:点「新建」→ 类型选 **Local(本地)** → 把整份粘进去 → 保存启用即可。已有配置的话,只取其中 `proxies:` 那段加进去。

登录服务器(root 已禁用,只能用新用户 + 公钥):

```bash
ssh -p <SSH端口> <新用户名>@<服务器IP>
```

Xray 管理命令:

```bash
systemctl status  xray
systemctl restart xray
systemctl stop    xray
```

> 想再次查看连接信息(`vless://` 链接 + Mihomo 配置),在服务器上运行 `bash install.sh info`(只读,不改动配置)。

---

## 从旧版(VMess)升级注意

- 这是**换节点而非改参数**:UUID、端口、密钥全部重新生成,**旧的 VMess 客户端配置会全部失效**,需用新打印的 `vless://` 链接重新导入。
- 若原服务器是因 IP 被封而迁移:换协议**不一定能救回已被整段封禁的 IP**。先确认是「端口被封」还是「整 IP 被封」(可用国内多地 TCP 探测,如对另一端口/443 做连通性测试),整 IP 被封时需更换 IP。

---

## 免责声明

本脚本仅供学习与合法用途。请遵守你所在国家/地区以及服务器提供商的相关法律法规与服务条款,使用产生的一切后果由使用者自行承担。
