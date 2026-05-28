# v2ray-install

一个**纯净、可审计**的 V2Ray 一键安装脚本,面向 **Debian / Ubuntu**,传输协议为 **VMess + TCP**。

适用场景:在一台**已经配置好 SSH 公钥登录**的全新云服务器上,一条命令完成 V2Ray 安装 + 服务器基础加固。

---

## 特性

- **二进制只从 [v2fly 官方仓库](https://github.com/v2fly/v2ray-core/releases) 下载**,并**强制校验官方 SHA256**,校验不通过立即终止。
- 下载全程走正常 TLS(不使用 `--no-check-certificate`),并强制 `--proto =https --tlsv1.2`。
- **不关闭防火墙**,而是用 `ufw` 做「默认拒绝入站 + 只放行必要端口」。
- 安装前做**配置自检**(`v2ray test -config`),不合法就不启动服务。
- **SSH 加固**:禁用密码登录、**禁用 root 登录**、仅允许公钥、可自定义 SSH 端口;自动创建专用 sudo 用户作为唯一登录入口。
- **不上传任何配置到第三方**,只在本地打印 `vmess://` 导入链接。
- 单文件、无外部子脚本依赖。

---

## 使用方式

> GitHub 网页地址(`/blob/`)不能直接执行,必须用 **raw** 地址。

### 安装(交互式)

```bash
bash <(curl -s -L https://raw.githubusercontent.com/Llane00/v2ray-install/main/install.sh)
```

会依次提示输入:V2Ray 端口、SSH 端口、要创建的登录用户名。

### 安装(全自动,不交互)

```bash
SSH_PORT=2222 V2RAY_PORT=31535 SSH_USER=你的登录用户名 \
  bash <(curl -s -L https://raw.githubusercontent.com/Llane00/v2ray-install/main/install.sh)
```

### 卸载

```bash
bash <(curl -s -L https://raw.githubusercontent.com/Llane00/v2ray-install/main/install.sh) uninstall
```

> 用 `bash <(...)` 而非 `curl | bash`:前者保留了标准输入,交互式输入才能正常工作。

---

## 环境变量

| 变量 | 说明 | 缺省 |
|------|------|------|
| `SSH_USER`   | **【必填】** 要创建的登录用户名,脚本会自动建号、加 sudo、生成随机密码并从 root 复制公钥 | 交互模式会提示输入;非交互模式必须提供 |
| `SSH_PORT`   | 新的 SSH 端口 | 保持 `22` |
| `V2RAY_PORT` | V2Ray 监听端口 | 随机 20000–65535 |
| `V2RAY_UUID` | VMess UUID | 自动生成 |

> 用户名规则:`^[a-z_][a-z0-9_-]*$`(小写字母/数字/下划线/连字符,**不能以数字开头**)。例如 `llane`、`user1` 可以,`123` 不行。

---

## 脚本做了什么

1. **前置检查**:必须 root、仅 Debian/Ubuntu(apt + systemd)、CPU 为 amd64 或 arm64。
2. **安装依赖**:`curl wget unzip ca-certificates ufw openssl sudo`。
3. **下载并校验**:取 v2fly 最新版本 → 下载 `.zip` 与 `.zip.dgst` → 校验 SHA256。
4. **安装文件**:
   - 二进制 → `/usr/local/bin/v2ray`
   - 数据(geoip/geosite)→ `/usr/local/share/v2ray/`
   - 配置 → `/usr/local/etc/v2ray/config.json`
   - 服务 → `/etc/systemd/system/v2ray.service`
   - 日志 → `/var/log/v2ray/`
5. **配置自检**:`v2ray version` + `v2ray test -config`。
6. **防火墙(ufw)**:默认拒绝入站、放行出站,只放行 SSH 端口与 V2Ray 端口;若改了端口则移除旧的 22 放行规则。
7. **创建登录用户**(必填用户名):自动建号 → **加入 sudo 组** → **生成 16 位随机密码并设置**(用于 sudo / 控制台,安装结束后打印一次)→ 从 `/root/.ssh/authorized_keys` 复制公钥到新用户(逐行去重、不破坏其原有 key)。若 root 无可用公钥则终止以防锁死。
8. **SSH 加固**:校验新用户已有可用公钥(否则终止)→ 写入 `PasswordAuthentication no` / `PubkeyAuthentication yes` / `PermitRootLogin no` / 自定义 `Port` → `sshd -t` 校验通过后重启。**禁用 root 登录后,唯一入口是上一步创建的新用户。**

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

- **V2Ray**:地址、端口、UUID,以及可直接导入客户端的 `vmess://` 链接
- **服务器登录**:新用户名、随机密码(用于 sudo / 控制台)、SSH 端口

登录服务器(root 已禁用,只能用新用户 + 公钥):

```bash
ssh -p <SSH端口> <新用户名>@<服务器IP>
```

V2Ray 管理命令:

```bash
systemctl status  v2ray
systemctl restart v2ray
systemctl stop    v2ray
```

---

## 免责声明

本脚本仅供学习与合法用途。请遵守你所在国家/地区以及服务器提供商的相关法律法规与服务条款,使用产生的一切后果由使用者自行承担。
