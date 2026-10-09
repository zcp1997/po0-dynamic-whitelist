# PO0 Dynamic Whitelist v0.2.1 

专门扩展已有 `PO0_REGION_WHITELIST` 的 IPv4 动态白名单。公网 VPS 只部署 Nginx，内网 Debian 运行 Python 标准库 HTTP API。保留省白 CIDR 和 `inet port_forward` NAT。
## 目录

```
server/whitelist_api.py    Python 标准库 API，严格 FIFO、10 槽、JSON 持久化
server/config.json        监听、可信反代、Token、入站网卡列表
server/firewall.sh        backup/install/verify/repair/uninstall
server/install.sh         安装入口
server/uninstall.sh       精确卸载入口
server/restore.sh         仅修复本项目规则
nginx/whitelist.conf      公网反代模板
surge/whitelist.*         自动请求模块和 JS
```

## 部署前确认（只读）

```sh
ip -4 -br addr
ip -4 route
iptables-nft -S PO0_REGION_WHITELIST
iptables-nft -S FORWARD
ipset list po0_region_whitelist | head -10
nft -a list ruleset > /root/nft.rules.audit.txt
```

1. 编辑 `server/config.json`，将 `listen_host` 设为内网本机可到达 IPv4；`trusted_proxy_ip` 设为 Nginx 到内网时真正的**源 IPv4**；`ingress_interfaces` 为公网/外部流量进入此机器的接口名称（如 `eth0`，**不要照搬示例**）。`api_token` 使用 32+ 位随机值。`max_slots` 默认 10，可改 1-100。若没有适合网卡，本版不应部署。
2. 先 `sudo install -d -m 700 /etc/po0-dynamic-whitelist`，再 `sudo install -m 600 server/config.json /etc/po0-dynamic-whitelist/config.json`。
3. 单独备份：`sudo bash server/firewall.sh backup`。将打印快照路径，包含完整 nft、ipset 和 iptables(nft) / ip6tables(nft) 文本。
4. **在有带外控制台并备份已核对的前提下**：`sudo bash server/install.sh install`。
5. 执行 `sudo bash server/firewall.sh verify`，以及从省白 IP、动态 IP、非白名单 IP 进行新的 SSH 和真实 DNAT 连通性测试。检查 `iptables-nft -nvL PO0_REGION_WHITELIST`、`iptables-nft -nvL PO0_DYNAMIC_FWD`、`iptables-nft -nvL FORWARD` 计数。
6. 公网配置 `nginx/whitelist.conf`：替换域名、证书、内网地址，用 `nginx -t` 检查后再 reload；此配置只监听 IPv4 `443`。将 `surge/whitelist.js` 上传到你可访问的 HTTPS 静态资源路径（Nginx 模板不提供 `/static`），修改 Surge URL、Token 后测试。

### API

- `POST /add`：新增 `/32` IPv4；重复 IP 返回 `exists`，队列位置不变。满槽先进先出。
- `GET /status`：查询队列和规则检查结果。
- Bearer Token 必须传 `Authorization`；客户端 IP 取可信 Nginx 传的 `X-Real-IP`，非公开 IPv4 拒绝。**Nginx 必须直接面向客户端，不得经未知上游代理伪造源 IP。**
- HTTP 200 不一定足以证明网络可达。API 返回 `enabled` 和 `firewall.input/forward` 仅表明本机规则检查通过；无法替代真实外部连接测试。
- API 本机只接受可信 VPS 的源 IP；必须另外确认上游网络不可信时 HTTP 传输保密性。

## 准确卸载（首选）

```
sudo bash server/uninstall.sh
```

卸载通过专属 comment 标记定位，仅删除本项目插入的 INPUT/FORWARD 跳转规则、`PO0_DYNAMIC_FWD`、`po0_dynamic_whitelist` 和 systemd unit，**不修改** `po0_region_whitelist`、原 PO0 链、Docker 链、DNAT/NAT 表及 `/etc/nftables.conf`。如果项目集合被第三方引用，删除可能会拒绝，需要人工检查。不删除备份/持久队列，便于追踪。

若安装后其他进程修改了防火墙规则，**禁止用旧的 `iptables-restore` 快照覆盖整张表**。快照主要作为审计与有控制台时的人工灾难恢复资料。

### 故障排查

```
sudo bash server/firewall.sh verify
sudo systemctl status po0-dynamic-whitelist --no-pager
sudo journalctl -u po0-dynamic-whitelist -n 100 --no-pager
sudo ipset list po0_dynamic_whitelist
```

### 已知限制

- 每次调用会以子进程查询 iptables/ipset，适用于少量个人设备。
- 开机恢复依赖原省白链和 ipset **先于本服务** 可用；如果旧省白启动时间较晚，需要增设 `After=` 对应服务，并实测重启。
- 10 槽配置调小时，如已有队列超长，服务拒绝启动以避免无意淘汰，需先人工决定如何迁移。
- `ingress_interfaces` 变化后需重新安装来处理旧接口 hook；`repair` 只补齐当前需要的 hook，不主动移除旧的 hook。
- 目前不实现对未知 Docker 自定义 nftables base chain 低于 FORWARD 优先级的全局防绕过保证。
