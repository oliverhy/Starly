# Starly Gateway

> CentOS、Debian、Ubuntu 的域名/IP 证书一键部署方式见 [INSTALL.md](INSTALL.md)。

Gateway 是独立于 RustDesk `hbbs`/`hbbr` 的 Starly 消息中继。手机和 PC 都只建立出站 WebSocket 连接；公网部署必须由反向代理提供 WSS。

## 本机联调

```powershell
python -m pip install -r .\gateway\requirements.txt
python .\gateway\create_pairing.py
$env:STARLY_GATEWAY_PAIRINGS = "$PWD\gateway\data\pairings.json"
$env:STARLY_GATEWAY_DATA = "$PWD\gateway\data"
python -m gateway.starly_gateway
```

本机监听地址为 `ws://127.0.0.1:8780/ws`。只有回环地址允许在测试时使用明文 `ws://`。

## VPS 部署

1. 在本机生成 `gateway/data/pairings.json`，安全复制到 VPS，禁止提交 Git。
2. 在 VPS 的 `gateway` 目录执行 `docker compose -f compose.example.yml up -d --build`。
3. 给 Gateway 配置独立域名，例如 `starly.example.com`。
4. 使用 Caddy、Nginx 或其他反向代理把 `https://starly.example.com/ws` 转发到 `http://127.0.0.1:8780/ws`。

Nginx 核心配置示例：

```nginx
location /ws {
    proxy_pass http://127.0.0.1:8780;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;
}
```

公网只开放反向代理的 `443`，不要直接开放 `8780`。Gateway 数据库和配对文件位于挂载的 `/data`。

## PC 配置

先启动一次 StarlyBridge，让它生成 `%APPDATA%\StarlyBridge\config.json`。关闭程序后加入：

```json
{
  "gateway_url": "wss://starly.example.com/ws",
  "gateway_pairing_id": "create_pairing.py 输出的 Pairing ID"
}
```

使用生成脚本输出的 Token 首次配置 PC。Gateway 配置只保存 Token 的 SHA-256 校验值，不保存原始 Token。可用环境变量导入地址、配对编号和 Token：

```powershell
$env:STARLY_GATEWAY_URL = "wss://starly.example.com/ws"
$env:STARLY_GATEWAY_PAIRING_ID = "你的 Pairing ID"
$env:STARLY_GATEWAY_TOKEN = "create_pairing.py 输出的 Token"
python -m pc.starly_bridge
```

`STARLY_GATEWAY_TOKEN` 只用于公网 Gateway。PC Bridge 会把它作为
`gateway_token_protected` 通过 Windows DPAPI 单独保存；局域网直连继续使用独立的
`token_protected`，更换任意一侧凭证不会再使另一种连接方式失效。

首次成功启动后，Token 会通过 Windows DPAPI 加密写入配置；之后可以清除环境变量。旧版本配置中的明文 `token` 会在启动时自动迁移并删除。

当前版本也可以直接在 PC Bridge 的“配置服务器”窗口填写 WSS 地址、Pairing ID 和
首次接入 Token。服务器 Token 只用于第一台 PC 的首次登记，成功后签发与 PC 设备 ID、
角色和公钥绑定的独立设备凭据；手机不能使用服务器 Token 登记，只能通过一次性公网短码、
双方校验码和 PC 明确允许完成配对。

手机设置页现在提供两种独立配对方式：

- **局域网配对**：保留原有自动发现、选择电脑和 6 位验证码，不经过公网 Gateway。
- **公网配对**：PC Bridge 生成一次性二维码和 8 位短码，有效期 2 分钟。手机扫码或输入短码后，手机和 PC 同时显示 6 位核对码；只有 PC 明确允许后，Gateway 才会签发该手机专属的设备凭据。

公网配对连接复用现有 WSS 地址 `wss://starly.example.com/ws?pair=1`，无需为反向代理增加新的路径规则。二维码只包含一次性会话、随机秘密和过期时间，不包含长期 Token。短码仅可使用一次，连续错误尝试会被限速。

## 当前安全边界

- 令牌通过 WebSocket 建连后的第一条消息发送，不进入 URL或反向代理访问日志。
- Gateway 数据库提供递增序号、确认进度、24 小时密文缓存和断线补发。
- `create_pairing.py` 默认只在 Gateway 配置中保存 Token 哈希。
- 手机和 PC 各自生成 X25519 设备身份，通过共享密钥派生 AES-256-GCM 会话密钥；任务、回复、图片和审批正文进入 Gateway 前已经加密，Gateway 只能看到密文和路由元数据。
- 每个方向都有持久化计数器、认证元数据和 48 小时离线窗口，重复、篡改或过期密文会被拒绝。
- Gateway 会把设备 ID 与首次登记的公钥绑定，之后拒绝同 ID 偷换公钥；已配对电脑可在手机端命名和撤销。
- 旧版长期 Token 仅用于 PC 首次接入和已登记设备迁移，不能继续登记任意新手机；迁移成功后 Gateway 会签发与设备 ID、角色绑定的独立长期设备凭据。
- 自动重连优先使用 1 小时短期会话令牌，失效后使用设备专属凭据重新认证；撤销设备时会同时撤销该设备凭据。
- PC 的配对 Token、设备凭据、X25519 私钥和短期会话令牌由 Windows DPAPI 加密保存；鸿蒙端对应秘密由 HUKS 中不可导出的 AES-256-GCM 密钥封装。
- 连接认证、配对和消息发送均有限速；业务日志不记录 Token、任务正文或 Codex 回复。

## 真机测试补充

- 鸿蒙端首次读取旧配置时会自动迁移，并删除 Preferences 里的旧明文 Token。
- “新任务”使用当前选中任务的工作区。若要允许从未在 Codex 中出现过的目录，请在启动 PC Bridge 前设置 `STARLY_WORKSPACE_ROOTS`；Windows 下多个根目录用分号分隔。
- Codex 命令、文件修改和权限请求会转发到手机审批；高风险命令在手机上要求二次点击确认。关闭手机不会自动批准请求。
- 若升级前的 Gateway 数据库中已有同名设备但没有公钥，首次连接会自动绑定新公钥；绑定后若删除手机应用并重装，应先在设备管理中撤销旧设备或换用新的设备 ID。
- 手机端可选择、命名和撤销电脑；多台电脑共用一个 Pairing ID 时，每条任务都只会路由到当前选中的电脑，不会广播重复执行。

```powershell
$env:STARLY_WORKSPACE_ROOTS = "C:\Users\YIN\DevEcoStudioProjects;C:\work"
python -m pc.starly_bridge
```

本阶段只需在 DevEco Studio 中运行 debug HAP 到真机，不需要构建或发布 release。
