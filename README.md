# Starly

Starly 是一套自建的 HarmonyOS → Windows 远程输入与 Codex Remote 方案。它由三个独立组件组成：

| 组件 | 目录 | 作用 |
| --- | --- | --- |
| HarmonyOS 客户端 | `entry/` | 语音输入、Codex 任务、审批、设备和连接管理 |
| Windows PC Bridge | `pc/` | 接收手机请求、控制桌面输入框、连接本机 Codex |
| Starly Gateway | `gateway/` | 提供公网 WSS、设备配对、在线状态和密文转发 |

手机和 PC 可以在局域网内直连，也可以同时连接自建 Gateway。双通道模式会优先使用局域网，局域网不可用时自动回退到公网中继；家庭网络不需要开放入站端口。

> 仓库只包含源码和无敏感信息的示例配置，不包含 HAP、EXE、证书、签名口令、设备密钥、配对凭证、服务器数据库或本机 SDK 路径。

当前最新测试版本为 [v2.1.0](https://github.com/oliverhy/Starly/releases/tag/v2.1.0)，可直接下载 [HarmonyOS HAP](https://github.com/oliverhy/Starly/releases/download/v2.1.0/Starly.hap)、[Windows Bridge](https://github.com/oliverhy/Starly/releases/download/v2.1.0/StarlyBridge.exe) 和 [使用说明](https://github.com/oliverhy/Starly/releases/download/v2.1.0/Starly-README.md)。该版本用于真机调试，不代表 AppGallery 正式发布版本。

## 主要功能

### HarmonyOS 客户端

- ArkTS / ArkUI 原生应用，支持手机、平板和 2in1 设备。
- Core Speech Kit 中文语音识别，支持按住说话、松手保留、滑动发送和滑动编辑。
- 文字和图片发送，发送成功回执到达后再清空输入框。
- Remote 首页显示电脑在线状态、项目、最近任务、执行状态和相对更新时间。
- 查看 Codex 对话、任务活动、模型、推理强度、速度、权限和账户额度。
- 任务发送队列：同一任务按顺序执行，不同任务可并行；显示排队位置、运行状态、失败原因并支持取消排队。
- 显示 Codex 目标条：同步目标正文、目标状态和累计耗时，点击可展开完整目标内容。
- 查看 Codex 工具读取的图片和生成图片；PC 会先生成适合公网传输的缩略图。
- 新建任务、继续任务、停止任务、搜索、置顶、未读、重命名、归档和恢复。
- 将 Codex 命令、文件修改和权限审批转发到手机，高风险操作要求二次确认。
- 任务完成、失败和等待审批通知。
- 任务列表和最近对话按电脑缓存，冷启动先展示缓存，再在后台校准。
- HarmonyOS HUKS 保护公网设备身份和长期凭证。

### Windows PC Bridge

- 托盘运行、开机启动、局域网自动发现、二维码和配对码。
- 公网安全配对：一次性短码、双方核对码和 PC 明确允许。
- 可自定义 Gateway 地址、Pairing ID 和首次接入 Token。
- 普通输入模式通过 Windows `SendInput` 向当前焦点输入框发送文字。
- Codex 支持两种发送方式：
  - 后台任务模式：通过本机 Codex App Server 发送和读取任务。
  - 桌面输入框模式：定位 Codex 桌面端的真实输入框，可选择 Enter 或 Ctrl+Enter。
- 监听 Codex 本地任务事件，主动推送开始、回复、审批和完成状态；完整快照仅用于校准。
- Windows DPAPI 保护局域网密钥、公网凭证、会话令牌和设备私钥。
- 持久化 Codex 发送队列，Bridge 重启后恢复排队状态，避免同一请求重复执行。
- PC 运行日志可在界面中直接打开所在目录。

### Starly Gateway

- 独立于 RustDesk `hbbs` / `hbbr`，可以部署在同一台 VPS，但应使用独立进程、端口和域名。
- 手机和 PC 均只建立出站 WSS 连接。
- 设备注册、一次性公网配对、在线状态、消息序号、确认、去重和断线补发。
- 短期离线密文缓存和多电脑路由。
- Gateway 只转发端到端密文，不能读取任务、图片、审批正文或 Codex 回复。
- 提供 Ubuntu、Debian、CentOS/RHEL 系的一键安装脚本。
- 支持域名证书和公网 IPv4 证书，并安装自动续期任务。

## 架构

```text
局域网优先：

HarmonyOS ── WebSocket + 局域网配对密钥 ──▶ PC Bridge

公网兜底：

HarmonyOS ── WSS + 端到端密文 ──▶ Starly Gateway ──▶ PC Bridge
                                                │
                                                └─ 只保存路由元数据和短期密文

PC 本地：

PC Bridge ── stdio JSONL ──▶ Codex App Server
         └─ UI Automation ─▶ Codex 桌面输入框
```

公网模式使用 X25519 设备密钥协商和 AES-256-GCM 消息加密。Gateway 无法解密业务正文。局域网兼容模式仍使用普通 WebSocket，因此只应在可信家庭或办公网络中使用。

## 项目结构

```text
Starly/
├─ AppScope/                       # HarmonyOS 应用级配置和图标
├─ entry/                          # HarmonyOS 主 HAP 模块
│  └─ src/main/ets/
│     ├─ entryability/             # Stage 模型入口
│     ├─ model/                    # Codex 与配对数据模型
│     ├─ pages/                    # ArkUI 页面
│     └─ service/                  # 通信、加密、缓存、语音和通知
├─ pc/
│  ├─ starly_bridge.py             # Windows Bridge 主程序
│  ├─ codex_client.py              # Codex App Server 与任务记录适配
│  ├─ gateway_client.py            # Gateway 长连接
│  ├─ gateway_crypto.py            # PC 端端到端加密
│  ├─ secret_store.py              # Windows DPAPI 存储
│  ├─ build.ps1                    # Windows EXE 构建脚本
│  └─ test_*.py                    # PC、协议和安全测试
├─ gateway/
│  ├─ starly_gateway.py            # WSS 中继服务
│  ├─ install.sh                   # 通用一键安装器
│  ├─ install-domain.sh            # 域名证书入口
│  ├─ install-ip.sh                # 公网 IP 证书入口
│  ├─ Dockerfile                   # 容器镜像
│  └─ test_gateway.py              # Gateway 测试
├─ build-profile.example.json5     # 无签名信息的 HarmonyOS 配置示例
├─ build_all.ps1                   # 手机端与 PC 端本地构建
└─ PLAN.md                         # 功能交付状态
```

## 环境要求

### 手机端

- HarmonyOS 6.1（API 23）或兼容版本。
- DevEco Studio 和对应 HarmonyOS SDK。
- 真机需要启用开发者模式和 USB 调试。

### PC Bridge

- Windows 10 或 Windows 11。
- Python 3.11 或更高版本（推荐使用项目当前开发版本）。
- 使用 Codex Remote 功能时，需要安装并登录 Codex 桌面端。

### Gateway

- Ubuntu 22.04+、Debian 12+、CentOS Stream 9 或兼容 RHEL/Rocky/AlmaLinux。
- 公网 IPv4，TCP 80 和 443 可访问。
- 域名模式需要提前把 A 记录指向服务器。

## 构建 HarmonyOS 客户端

真实的 `build-profile.json5` 可能包含本机证书路径和签名口令，因此不会提交。首次克隆后先复制示例：

```powershell
Copy-Item .\build-profile.example.json5 .\build-profile.json5
```

随后使用 DevEco Studio 配置自动签名，并选择 `entry` 模块构建 HAP。

也可以使用项目脚本同时构建 HAP 和 Windows Bridge：

```powershell
.\build_all.ps1 -DevEcoRoot "你的 DevEco Studio 安装目录"
```

构建产物只保存在本地 `release/`，不会进入 Git。

## 运行和构建 PC Bridge

源码运行：

```powershell
python -m pip install -r .\pc\requirements.txt
python -m pc.starly_bridge
```

构建单文件 EXE：

```powershell
powershell -ExecutionPolicy Bypass -File .\pc\build.ps1
```

生成文件位于 `pc/dist/StarlyBridge.exe`。Windows 防火墙首次询问时，只建议允许专用网络。

## 配对与连接

### 局域网配对

1. 启动 PC Bridge。
2. 手机打开 Starly 的配对页。
3. 使用自动发现选择电脑，或扫描 PC 二维码。
4. 手机和 PC 确认配对码。

局域网模式不经过 Gateway，适合可信网络内的低延迟使用。

### 公网安全配对

1. 在 PC Bridge 中配置 Gateway URL、Pairing ID 和服务器首次接入 Token。
2. PC 成功登记后生成一次性公网二维码或 8 位短码。
3. 手机扫码或输入短码。
4. 手机和 PC 核对相同的 6 位验证码。
5. 仅在 PC 点击“允许”后，Gateway 才签发该手机的设备凭证。

短码只能使用一次并会过期，二维码不包含长期服务器 Token。

## 一键部署 Gateway

完整说明见 [gateway/INSTALL.md](gateway/INSTALL.md)。

域名证书版：

```bash
cd gateway
sudo bash install-domain.sh starly.example.com admin@example.com
```

公网 IPv4 证书版：

```bash
cd gateway
sudo bash install-ip.sh 203.0.113.10 admin@example.com
```

安装器会配置：

- `starly-gateway.service`
- Nginx WSS 反向代理
- TLS 证书及自动续期定时器
- `/var/lib/starly-gateway` 持久化数据库
- root 专用的首次 Pairing ID 和 Token 文件

公网只应开放 80/443；Gateway 应只在 `127.0.0.1:8780` 监听，不要把明文 WebSocket 端口直接暴露到互联网。

## Codex Remote 使用说明

- Remote 首页任务按最近更新时间排序，置顶任务除外。
- “正在执行”来自 PC 任务事件；手机会在后台使用完整快照修正漏失状态。
- 手机显示的模型、推理强度、速度和额度来自当前 PC 的 Codex 接口，不是手机内置固定列表。
- 桌面输入框模式依赖可见的 Codex 窗口和 Windows UI Automation。
- 后台任务模式不要求 Codex 输入框获得焦点。
- Starly 不提供任意远程 Shell。Codex 发起的命令或高权限操作仍需经过 Codex 权限体系和手机审批。
- 手机与 Codex 桌面端同时操作同一任务时，以 PC 的最新任务事件和持久化记录为准。

## 测试

PC 与 Gateway 完整回归测试：

```powershell
python -m unittest discover -s pc -p "test_*.py"
python -m unittest discover -s gateway -p "test_*.py"
```

语法检查：

```powershell
python -m py_compile .\pc\starly_bridge.py .\pc\codex_client.py .\gateway\starly_gateway.py
```

HarmonyOS 客户端可以在 DevEco Studio 中构建，并使用 `hdc install -r` 安装签名后的 Debug HAP 到真机。

## 安全边界

- 公网只允许 `wss://`；只有回环地址可以在本地测试时使用 `ws://`。
- 公网任务、回复、图片和审批正文进入 Gateway 前已经端到端加密。
- Gateway 日志不应记录 Token、任务正文或 Codex 回复。
- PC 使用 DPAPI，HarmonyOS 使用 HUKS 保护长期秘密。
- 设备凭证绑定设备 ID、角色和公钥；被撤销设备不能重新使用旧凭证。
- 每个方向都使用持久化计数器和认证元数据防止重复、篡改和重放。
- 连接、配对和消息发送均有限速。
- Codex App Server 只在 PC 本机通过标准输入输出通信，不直接开放到局域网或公网。
- 普通权限 Bridge 无法向以管理员身份运行的窗口模拟输入，两者需要处于相同权限级别。

## 禁止提交的内容

- 真实 `build-profile.json5`、HarmonyOS 证书和签名口令。
- `%APPDATA%/StarlyBridge/config.json`。
- Gateway 的 `data/`、SQLite 数据库、Pairing ID、Token 和设备凭证。
- `.cer`、`.p7b`、`.p12`、`.pem`、`.key` 等证书或私钥。
- HAP、APP、EXE、构建缓存、运行日志、调试截图和本机生成文件。

如果任何真实密钥曾进入 Git 历史，应立即撤销并轮换；仅删除当前文件不足以消除泄露风险。

## 当前状态

手机端、PC Bridge 和 Gateway 源码均位于本仓库。项目已完成局域网和公网真机联调，并发布了用于测试的 v2.1.0 Release；当前仍处于开发测试阶段，尚未发布 AppGallery 正式版本。
