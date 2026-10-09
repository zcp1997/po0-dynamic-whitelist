# PO0 Dynamic Whitelist

自建的 PO0 IPv4 动态白名单（v0.3.0）。在已有省白 `PO0_REGION_WHITELIST` 的基础上，把客户端当前公网 IP 动态加进白名单，保留省白 CIDR 和 `inet port_forward` NAT 不动。

- **服务端**：公网 VPS 只跑 Nginx；内网 Debian 跑一个 Python 标准库 HTTP API，写 ipset + iptables-nft 规则。
- **客户端**：Surge / Loon / Stash / Quantumult X / Shadowrocket / Egern 六个代理客户端模块，Linux / macOS / Android Termux 命令行，OpenWrt / Kwrt 软路由。网络切换时即时加白，每 10 分钟兜底一次。

> 参考 [w0ven/po0fw](https://github.com/w0ven/po0fw) 的客户端设计。区别在于：po0fw 调用 po0 官方 API（`/24` 网段），本项目对接自建 API（`/32` 单 IP，Bearer Token 鉴权，FIFO 槽位）。

**目录**

- [工作原理](#工作原理)
- [目录结构](#目录结构)
- [一、服务端部署](#一服务端部署)
- [二、客户端接入](#二客户端接入)
  - [代理客户端模块（iOS / macOS）](#代理客户端模块ios--macos)
  - [Linux / macOS / Android Termux](#linux--macos--android-termux)
  - [OpenWrt / Kwrt 软路由](#openwrt--kwrt-软路由)
- [API 参考](#api-参考)
- [FAQ](#faq)
- [开发与测试](#开发与测试)

---

## 工作原理

```
客户端（手机 / 电脑 / 路由器）
  │  POST https://fw.example.com/add      Authorization: Bearer <token>
  │  ⚠️ 必须直连，否则加白的是代理出口 IP
  ▼
公网 VPS · Nginx :443（只监听 IPv4）
  │  把 TCP 源 IP 写进 X-Real-IP，转发到 http://内网IP:8765
  ▼
内网 Debian · whitelist_api.py
  │  只信任 trusted_proxy_ip 传来的 X-Real-IP，校验 Token 和公网 IPv4
  │  ipset add po0_dynamic_whitelist <IP>
  ▼
INPUT   → PO0_REGION_WHITELIST ：动态白名单 → 省白 → REJECT
FORWARD → PO0_DYNAMIC_FWD（仅 DNAT 新连接）：动态白名单 → 省白 → REJECT
```

槽位规则：

- 一个 IP 占一个槽（`/32`），默认 10 槽，可配 1–100。
- 严格 FIFO：IP 已在队列中返回 `exists`，**不占新槽、不改变顺序**；满槽时淘汰最早写入的 IP。
- 客户端反复请求是安全的。被淘汰的设备会在下一次定时或网络切换时自动补回（最迟 10 分钟）。

## 目录结构

```
server/
  whitelist_api.py         API：严格 FIFO、JSON 持久化、规则自检
  config.json              配置模板：监听地址、可信反代、Token、入站网卡
  firewall.sh              backup / install / verify / repair / uninstall
  install.sh               安装入口
  uninstall.sh             精确卸载入口
  restore.sh               只修复本项目规则
nginx/
  whitelist.conf           公网反代模板
clients/
  scripts/whitelist.js     共享脚本：Surge / Loon / Stash / QX / Shadowrocket
  surge/whitelist.sgmodule
  loon/whitelist.plugin
  stash/whitelist.stoverride
  quantumultx/whitelist.snippet
  shadowrocket/whitelist.srmodule
  egern/whitelist.yaml     Egern 模块
  egern/whitelist.js       Egern 专用脚本（ESM）
  shell/po0dw.sh           命令行客户端（POSIX sh + curl）
  shell/install.sh         一键安装：Linux / macOS / Termux / OpenWrt / Kwrt
tests/                     服务端、JS 客户端、Shell 客户端测试
```

---

## 一、服务端部署

### 1. 部署前只读检查

```sh
ip -4 -br addr
ip -4 route
iptables-nft -S PO0_REGION_WHITELIST
iptables-nft -S FORWARD
ipset list po0_region_whitelist | head -10
nft -a list ruleset > /root/nft.rules.audit.txt
```

### 2. 填写配置

编辑 `server/config.json`：

| 字段 | 说明 |
|---|---|
| `listen_host` | API 监听的内网 IPv4，需本机可达 |
| `listen_port` | API 端口，默认 `8765` |
| `trusted_proxy_ip` | Nginx 访问内网 API 时真正的**源 IPv4**。API 只信任这个地址传来的 `X-Real-IP` |
| `max_slots` | 槽位数，默认 10，可改 1–100 |
| `api_token` | 32 位以上随机值，建议 `openssl rand -hex 32`（只用字母数字，方便放进客户端参数） |
| `ingress_interfaces` | 公网 / 外部流量进入本机的网卡名，如 `eth0`。**不要照搬示例**；找不到合适网卡就不要部署 |

然后放到系统目录：

```sh
sudo install -d -m 700 /etc/po0-dynamic-whitelist
sudo install -m 600 server/config.json /etc/po0-dynamic-whitelist/config.json
```

### 3. 备份并安装

```sh
sudo bash server/firewall.sh backup     # 打印快照路径：完整 nft、ipset、iptables(nft) / ip6tables(nft)
sudo bash server/install.sh             # 务必在有带外控制台、已核对备份的前提下执行
```

### 4. 验证

```sh
sudo bash server/firewall.sh verify
iptables-nft -nvL PO0_REGION_WHITELIST
iptables-nft -nvL PO0_DYNAMIC_FWD
iptables-nft -nvL FORWARD
```

再分别从**省白 IP、动态白名单 IP、非白名单 IP** 做一次新的 SSH 和真实 DNAT 连通性测试，确认计数符合预期。

### 5. 公网 Nginx

按 `nginx/whitelist.conf` 替换域名、证书路径和内网地址，`nginx -t` 通过后再 reload。

- 只监听 IPv4 `443`，DNS **只配 A 记录**，不要加 AAAA。
- Nginx 必须直接面向客户端，前面不能再套 CDN 或其他会改写源 IP 的代理。
- Nginx 到内网这段是明文 HTTP，若这段链路不可信，需要另外保证其保密性。

### 卸载

```sh
sudo bash server/uninstall.sh
```

卸载通过专属 comment 标记定位，只删除本项目插入的 INPUT / FORWARD 跳转规则、`PO0_DYNAMIC_FWD`、`po0_dynamic_whitelist` 和 systemd unit；**不改动** `po0_region_whitelist`、原 PO0 链、Docker 链、DNAT / NAT 表和 `/etc/nftables.conf`。项目集合被第三方引用时会拒绝删除，需要人工检查。备份和持久化队列会保留，便于追溯。

> ⚠️ 安装后如果其他程序改过防火墙，**禁止用旧的 `iptables-restore` 快照覆盖整张表**。快照只用于审计，以及有控制台时的人工灾难恢复。

### 修复与排障

```sh
sudo bash server/restore.sh                                   # 只补齐本项目规则
sudo bash server/firewall.sh verify
sudo systemctl status po0-dynamic-whitelist --no-pager
sudo journalctl -u po0-dynamic-whitelist -n 100 --no-pager
sudo ipset list po0_dynamic_whitelist
```

### 已知限制

- 每次请求都会起子进程查询 iptables / ipset，适合少量个人设备。
- 开机恢复依赖原省白链和 ipset **先于本服务**就绪；如果省白启动较晚，需要给 unit 加对应的 `After=` 并实测重启。
- 调小 `max_slots` 时若现有队列超长，服务会拒绝启动以免误淘汰，需要先人工决定如何迁移。
- `ingress_interfaces` 变更后需要重新安装来清理旧网卡的 hook；`repair` 只补齐当前需要的 hook，不会移除旧的。
- 不保证防住优先级低于 FORWARD 的未知 Docker 自定义 nftables base chain 绕过。

---

## 二、客户端接入

### 通用说明

所有客户端只需要两个参数：

| 参数 | 示例 | 说明 |
|---|---|---|
| `api_host` | `fw.example.com` | 公网 Nginx 域名，不带 `https://`（命令行里叫 `PO0DW_URL`，也可以带 `https://`） |
| `token` | `openssl rand -hex 32` 的输出 | 与服务端 `api_token` 一致，**等同于加白凭证，不要公开** |

几条共同行为：

- **请求必须直连**。各模块都内置了 `DOMAIN,<api_host>,DIRECT` 规则，脚本请求还会显式指定 `DIRECT` 策略（Loon 用 `node`，QX 用 `opts.policy`）。如果你另外开了 TUN / 透明代理，记得自己再加一条直连规则。
- 只接受 `https://`，拒绝明文 http，避免 Token 泄露。
- 网络错误或 5xx 自动重试 3 次；401 / 400 / 403 这类确定性错误不重试，并给出中文原因。
- 通知只在**出口 IP 或加白状态发生变化**时弹出，例行定时任务保持安静；Surge 面板手动刷新不弹通知。
- 共享脚本托管在本仓库 GitHub。脚本本身不含 Token，想自托管的话把模块里的脚本地址换成你自己的 HTTPS 地址即可（Surge 直接改 `script_url` 参数）。

### 代理客户端模块（iOS / macOS）

| 客户端 | 模块文件 | 网络切换 | 每 10 分钟 | 面板 | 填参数方式 |
|---|---|:-:|:-:|:-:|---|
| Surge | `clients/surge/whitelist.sgmodule` | ✓ | ✓ | 面板 | 模块参数 |
| Loon | `clients/loon/whitelist.plugin` | ✓ | ✓ | — | 插件参数 |
| Stash | `clients/stash/whitelist.stoverride` | — | ✓ | 磁贴 | 手动改文本 |
| Quantumult X | `clients/quantumultx/whitelist.snippet` | ✓ | ✓ | — | 手动改文本 |
| Shadowrocket | `clients/shadowrocket/whitelist.srmodule` | ✓ | ✓ | — | 手动改文本 |
| Egern | `clients/egern/whitelist.yaml` | ✓ | ✓ | — | 模块参数 |

安装地址（复制后在客户端里「从 URL 安装」）：

```
https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main/clients/surge/whitelist.sgmodule
https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main/clients/loon/whitelist.plugin
https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main/clients/stash/whitelist.stoverride
https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main/clients/quantumultx/whitelist.snippet
https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main/clients/shadowrocket/whitelist.srmodule
https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main/clients/egern/whitelist.yaml
```

#### Surge

1. 模块 → 安装新模块 → 粘贴 Surge 地址。
2. 编辑模块参数：`api_host`、`token`；`script_url` 默认用本仓库脚本，可改为自托管地址。
3. 首页会出现「PO0 动态白名单」面板，点一下即手动加白并显示结果。

#### Loon

1. 配置 → 插件 → 添加，粘贴 Loon 地址。
2. 在插件设置里填写「API 域名」和「API Token」。

> Loon 的 `network-changed` 脚本在所有插件里**只执行第一条**。如果别的插件也注册了网络切换脚本，本插件可能只剩每 10 分钟的定时触发。

#### Stash

Stash 覆写不支持参数，需要改文本：

1. 打开 Stash 地址，复制全文，在 Stash 里新建**本地覆写**粘贴（远程覆写更新时会冲掉你的修改）。
2. 把文中 **3 处** `fw.example.com` 换成你的域名，**2 处** `REPLACE_WITH_TOKEN` 换成 Token。
3. Stash 没有网络切换事件，只有每 10 分钟定时 + 首页磁贴手动刷新。

#### Quantumult X

QX 的定时任务只能写在本地配置里：

1. 打开 QX 地址，把 `[task_local]` 的两行加到你配置的 `[task_local]` 段，`[filter_local]` 那行加到 `[filter_local]` 段。
2. 把 **3 处** `fw.example.com` 换成你的域名，**2 处** `REPLACE_WITH_TOKEN` 换成 Token。

参数写在脚本 URL 的 `#` 后面（`…/whitelist.js#api_host=…&token=…`），这部分只在本地解析，不会发给 GitHub。`event-network` 那行负责网络切换即时加白，需要 QX 隧道处于运行状态。

#### Shadowrocket

Shadowrocket 不支持 Surge 的参数模板，需要改文本：

1. 配置 → 模块 → 添加模块，粘贴 Shadowrocket 地址。
2. 长按模块 → 编辑纯文本，把 **3 处** `fw.example.com` 和 **2 处** `REPLACE_WITH_TOKEN` 换成你的值。也可以直接新建本地模块粘贴改好的内容，避免远程更新覆盖。

#### Egern

1. 模块 → 添加模块，粘贴 Egern 地址。
2. 在模块参数里填写 `api_host`、`token`。

Egern 的脚本运行模型和其他客户端不同（`export default async function (ctx)`），所以用独立的 `clients/egern/whitelist.js`，逻辑与共享脚本保持一致。

#### 进阶：用持久化存储代替明文参数

共享脚本读取参数的优先级是：模块参数 / QX 的 `#` 参数 → 持久化存储 `po0dw_api_host`、`po0dw_token` → 脚本开头的 `INLINE_API_HOST`、`INLINE_TOKEN`。用 BoxJs 之类的工具写入这两个键后，模块里的参数可以留空。

---

### Linux / macOS / Android Termux

一行安装（会下载 `po0dw` 到本机、写配置、注册定时任务，并立即执行一次）：

```sh
curl -fsSL https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main/clients/shell/install.sh \
  | PO0DW_URL=fw.example.com PO0DW_TOKEN=你的Token sh
```

不想把 Token 留在 shell 历史里，可以先下载脚本再运行，不带环境变量时会在终端提示输入（Token 不回显）：

```sh
curl -fsSLo install.sh https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main/clients/shell/install.sh
sh install.sh
```

安装脚本自动识别平台：

| 平台 | 触发方式 | 程序 / 配置 / 日志 |
|---|---|---|
| Linux（root + systemd） | `po0dw.timer` 每 10 分钟；装了 NetworkManager / networkd-dispatcher 时网络切换即时触发 | `/usr/local/bin/po0dw` · `/etc/po0dw.conf` · `journalctl -u po0dw` |
| Linux（非 root 或无 systemd） | crontab 每 10 分钟 | `~/.local/bin/po0dw` · `~/.config/po0dw.conf` · `~/.cache/po0dw.log`（root 为 `/usr/local/bin`、`/etc`、`/var/log`） |
| macOS | launchd：每 10 分钟 + 网络配置变化即时触发 | `~/.local/bin/po0dw` · `~/.config/po0dw.conf` · `~/Library/Logs/po0dw.log` |
| Android Termux | cronie 每 10 分钟 | `$PREFIX/bin/po0dw` · `$PREFIX/etc/po0dw.conf` · `$PREFIX/var/log/po0dw.log` |

Termux 额外说明：

- 安装脚本会自动装 `curl`、`cronie`、`termux-services`。首次安装后需**重开一次 Termux**，再执行 `sv-enable crond`。
- 建议执行 `termux-wake-lock`，并在系统设置里关闭 Termux 的电池优化，否则后台定时可能被杀。

电脑上如果开了 Clash Verge 等工具的 **TUN 模式**，请在代理规则里加 `DOMAIN,fw.example.com,DIRECT`。`po0dw` 已经用 `--noproxy '*'` 忽略 `http_proxy` 之类的环境变量，但 TUN 会在系统层面接管流量。

升级：重新运行安装命令即可，会沿用已有配置。卸载：

```sh
curl -fsSL https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main/clients/shell/install.sh | sh -s uninstall
```

### OpenWrt / Kwrt 软路由

```sh
uclient-fetch -qO /tmp/po0dw-install.sh https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main/clients/shell/install.sh
PO0DW_URL=fw.example.com PO0DW_TOKEN=你的Token sh /tmp/po0dw-install.sh
```

- 缺 `curl` 或 `ca-bundle` 时自动用 `opkg` / `apk` 安装。
- `/etc/crontabs/root` 每 10 分钟兜底；`/etc/hotplug.d/iface/99-po0dw` 在 WAN 口 `ifup` / `ifupdate` 时 5 秒后触发，PPPoE 重拨后几秒内即可加白。WAN 口按 `network_find_wan` 自动识别，同时兼容 `wan`、`wwan`、`pppoe-*`、`modem` / `lte` 等常见命名。
- 程序、配置和 hotplug 脚本会写入 `/etc/sysupgrade.conf`，升级固件后保留。
- 日志：`/tmp/po0dw.log`（每次运行覆盖，不占闪存）。
- 路由器上跑了 OpenClash / PassWall / SSR Plus 等插件时，要把 `fw.example.com` 加进**直连列表**，否则路由器自身的请求可能被代理。
- 访问 GitHub 困难时，可用 `PO0DW_RAW` 指定镜像前缀（替换 `https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main`）。

卸载：`sh /tmp/po0dw-install.sh uninstall`。

### 命令行用法

```sh
po0dw            # 把当前出口 IP 加入白名单（幂等，可反复执行）
po0dw status     # 只查询白名单和规则状态，不加白
po0dw version
```

```
$ po0dw
[po0dw] ✅ 203.0.113.7 已在白名单（新增，槽位 3/10，防火墙 INPUT ✓ FORWARD ✓）

$ po0dw status
[po0dw] 当前出口 203.0.113.7
[po0dw]     1. 198.51.100.1
[po0dw]     2. 192.0.2.44
[po0dw]   → 3. 203.0.113.7
[po0dw] 槽位 3/10 · 防火墙 INPUT ✓ FORWARD ✓ · 规则生效
[po0dw] ✅ 当前出口已在白名单
```

配置文件格式（安装脚本自动生成，权限 600）：

```sh
PO0DW_URL="fw.example.com"
PO0DW_TOKEN="你的Token"
```

| 变量 | 说明 |
|---|---|
| `PO0DW_URL` / `PO0DW_TOKEN` | 优先级高于配置文件 |
| `PO0DW_CONF` | 指定配置文件；默认依次找 `/etc/po0dw.conf`、`$PREFIX/etc/po0dw.conf`、`~/.config/po0dw.conf` |
| `PO0DW_RETRY` / `PO0DW_TIMEOUT` | 重试次数（默认 3）/ 单次超时秒数（默认 15） |
| `PO0DW_RAW` | 仅安装脚本使用：下载源前缀 |
| `PO0DW_PLATFORM` | 仅安装脚本使用：强制平台（`systemd` / `cron` / `macos` / `termux` / `openwrt`） |

退出码：`0` 成功，`1` 加白或查询失败，`2` 配置错误。Token 通过 `curl -K -` 从标准输入传给 curl，不会出现在进程列表里。

---

## API 参考

两个接口都要求 `Authorization: Bearer <api_token>`，客户端 IP 取自可信 Nginx 传来的 `X-Real-IP`，必须是公网 IPv4。

| 接口 | 说明 |
|---|---|
| `POST /add` | 把当前 IP 加入白名单。已存在返回 `exists`，满槽按 FIFO 淘汰最早 IP |
| `GET /status` | 只查询队列和规则检查结果 |

响应示例：

```json
{
  "enabled": true,
  "whitelist": [{"ip": "198.51.100.1", "slot": null}, {"ip": "203.0.113.7", "slot": null}],
  "limit": 10,
  "currentIp": "203.0.113.7",
  "action": "added",
  "evicted": null,
  "firewall": {"input": true, "forward": true}
}
```

- `action`：`added` 新增 / `exists` 已存在 / `evicted` 新增并淘汰了 `evicted` 字段里的 IP。
- `enabled`：INPUT、FORWARD 规则自检通过，且队列与 ipset 一致。客户端以「`enabled` 为真且 `currentIp` 在 `whitelist` 中」判定加白成功。
- HTTP 200 只说明本机规则检查通过，**不能替代真实的外部连通性测试**。

错误响应：

| HTTP | `error` | 含义 |
|---|---|---|
| 401 | `unauthorized` | Token 错误 |
| 403 | `untrusted peer` | 请求不是来自 `trusted_proxy_ip` |
| 400 | `invalid public IPv4` | `X-Real-IP` 不是公网 IPv4（常见原因：走了代理、IPv6、Nginx 没传头） |
| 503 | `INPUT/FORWARD guard not verified` | 防火墙规则自检失败，执行 `firewall.sh verify` |
| 503 | `queue / ipset mismatch; manual repair required` | 持久化队列与 ipset 不一致，需人工 repair |
| 503 | `failed to apply whitelist` / `firewall unavailable` | 写 ipset 失败或防火墙不可用 |
| 404 / 405 | `not found` / `method not allowed` | 路径或方法不对 |

手动测试：

```sh
curl -4 --noproxy '*' -X POST -H "Authorization: Bearer $TOKEN" https://fw.example.com/add
curl -4 --noproxy '*' -H "Authorization: Bearer $TOKEN" https://fw.example.com/status
```

---

## FAQ

**为什么一定要直连？**
服务端把「Nginx 看到的 TCP 源 IP」加进白名单。请求如果经过代理，加进去的是代理出口 IP，你本机真实 IP 仍然被拦。

**白名单满了会怎样？**
最早写入的 IP 被淘汰。那台设备在下一次定时或网络切换时会自动补回，同时把当时最早的 IP 挤出去。设备多于槽位时，适当调大 `max_slots`。

**支持 IPv6 吗？**
不支持。Nginx 只监听 IPv4，域名只配 A 记录，客户端自然走 IPv4；命令行客户端还额外加了 `curl -4`。

**同一个出口 IP 下有多台设备？**
同一 IP 只占一个槽，任意一台设备加白后，同一出口下的其他设备也能连。家里有软路由的话，直接在路由器上装即可覆盖所有设备，手机只在蜂窝网络下才需要自己加白。

**提示「服务端没拿到公网 IPv4」？**
通常是请求走了代理或 IPv6，或 Nginx 没正确传 `X-Real-IP`。检查直连规则、DNS 是否只有 A 记录，以及 `nginx/whitelist.conf` 是否原样配置。

**不放心从 GitHub 加载脚本？**
把 `clients/scripts/whitelist.js`（Egern 为 `clients/egern/whitelist.js`）放到你自己的 HTTPS 静态地址，再替换模块里的脚本地址即可。

---

## 开发与测试

```sh
python3 tests/test_api.py          # 服务端 API：FIFO、回滚、鉴权、IPv4 校验
node --test tests/clients.test.js  # JS 客户端：模拟六个客户端运行时
sh tests/test_shell.sh             # po0dw / install.sh：mock curl，覆盖 dash / busybox / bash --posix
```

Shell 客户端另外用 `shellcheck -s sh clients/shell/*.sh` 做静态检查。

## 致谢

客户端模块的结构与多客户端兼容处理参考了 [w0ven/po0fw](https://github.com/w0ven/po0fw)（模块部分源自 [reallinzc/po0fw](https://github.com/reallinzc/po0fw)），感谢原作者。
