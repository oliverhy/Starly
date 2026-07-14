# Starly

Starly 是一套“鸿蒙手机语音输入 → Windows 当前输入框”的局域网输入工具。

在手机上按住说话，应用会持续把中文语音转换为可编辑文字；松手后可以保留文字、滑向左上角直接发送，或滑向右上角进入编辑。电脑端接收文字后，将其输入到当前获得焦点的输入框，并根据手机上的单选设置执行 `Ctrl + Enter` 或 `Enter`。

> 本仓库只包含源代码和无敏感信息的配置示例，不包含签名证书、签名口令、配对密钥、HAP、EXE 或本机 SDK 路径。

## 主要功能

- HarmonyOS 原生 ArkTS / ArkUI 应用。
- 基于 HarmonyOS 6.1（API 23）的沉浸光感标题栏与液态玻璃界面。
- 按住持续语音识别，松手停止。
- 左上滑“发送”、右上滑“编辑”的手势操作。
- 长按时显示跟随手指的中性玻璃点光源；滑向“发送”或“编辑”时，目标按钮呈现白色边缘泛光和高光扩散效果。
- 识别结果可在手机端继续修改或清空。
- 两种互斥发送方式：`Ctrl + Enter`、`Enter`。
- 支持单独遥控一次回车。
- Scan Kit 扫描二维码配对，也可以手动填写电脑地址、端口和密钥。
- 手机和电脑通过局域网 WebSocket 通信。
- 电脑执行成功后返回确认，手机收到确认才清空输入框。
- Windows 客户端支持托盘运行、开机启动和更换配对密钥。
- 限制为私有局域网、回环或链路本地地址，并使用随机配对密钥。

## 工作方式

```text
鸿蒙手机麦克风
    ↓
Core Speech Kit 中文识别
    ↓
手机端编辑 / 选择发送快捷键
    ↓  WebSocket（局域网 + 配对密钥）
Windows StarlyBridge
    ↓
SendInput 输入当前焦点窗口
    ↓
回执返回手机并清空已发送文字
```

Starly 不会读取电脑输入框、屏幕或剪贴板，也不会主动切换电脑窗口。发送前需要先在电脑上点中目标输入框。

## 项目结构

```text
Starly/
├─ AppScope/                  # HarmonyOS 应用级配置和图标
├─ entry/                     # HarmonyOS 主 HAP 模块
│  └─ src/main/ets/
│     ├─ entryability/        # Stage 模型入口
│     ├─ model/               # 配对信息模型
│     ├─ pages/               # ArkUI 主页面
│     └─ service/             # 语音、WebSocket、持久化服务
├─ pc/
│  ├─ starly_bridge.py        # Windows 客户端主程序
│  ├─ test_bridge.py          # 协议与安全边界测试
│  ├─ integration_probe.py    # 已运行客户端握手检查
│  ├─ requirements.txt        # Python 构建依赖
│  └─ build.ps1               # Windows 单文件 EXE 构建脚本
├─ build-profile.example.json5 # 不含签名信息的项目配置示例
├─ build_all.ps1              # 两端构建与交付文件汇总
└─ PLAN.md                    # 当前交付状态
```

## 运行要求

### 手机端

- HarmonyOS 6.1（API 23）或兼容版本。
- 带麦克风的鸿蒙手机或平板。
- DevEco Studio 与对应 HarmonyOS SDK，用于源码构建。

### 电脑端

- Windows 10 或 Windows 11。
- 源码运行/构建需要 Python 3.14。
- 安装 `pc/requirements.txt` 中的依赖。
- 手机和电脑处于同一可信局域网。

## 首次配置

仓库不会提交真实的 `build-profile.json5`，因为 DevEco Studio 自动签名会在其中写入本机证书路径和口令。

克隆后先复制示例：

```powershell
Copy-Item .\build-profile.example.json5 .\build-profile.json5
```

然后用 DevEco Studio 打开项目，在项目签名设置中开启自动签名。请勿把生成后的 `build-profile.json5`、证书或口令提交到 Git。

## 构建鸿蒙应用

推荐直接使用 DevEco Studio 选择 `entry` 模块构建 HAP。

也可以使用项目脚本，同时构建手机端和电脑端：

```powershell
.\build_all.ps1 -DevEcoRoot "你的 DevEco Studio 安装目录"
```

或者提前设置环境变量：

```powershell
$env:DEVECO_STUDIO_HOME = "你的 DevEco Studio 安装目录"
.\build_all.ps1
```

构建成功后，本地 `release/` 目录会包含：

- `Starly.hap`
- `StarlyBridge.exe`
- `使用说明.md`

`release/` 已被 Git 忽略，不会上传到仓库。

## 构建 Windows 客户端

```powershell
python -m pip install -r .\pc\requirements.txt
powershell -ExecutionPolicy Bypass -File .\pc\build.ps1
```

生成的单文件程序位于：

```text
pc/dist/StarlyBridge.exe
```

电脑端首次启动时，Windows 防火墙可能询问网络权限。只建议允许“专用网络”。

## 使用步骤

1. 在电脑上运行 `StarlyBridge.exe`。
2. 在手机上安装并打开 Starly，允许麦克风权限。
3. 手机点击“扫码配对”，扫描电脑端二维码。
4. 在电脑上点击需要输入文字的目标输入框，然后把 Starly 电脑端最小化到托盘。
5. 在手机上选择 `Ctrl + 回车` 或 `回车`。
6. 按住“按住说话”开始识别：
   - 原地松手：停止识别并保留文字。
   - 向左上滑后松手：识别完成后直接发送。
   - 向右上滑后松手：识别完成后聚焦文字编辑框。
7. 也可以手动编辑文字后点击“发送文字”。

## 通信协议概览

手机连接电脑端显示的 WebSocket 地址，并通过查询参数携带随机配对密钥。主要消息如下：

```json
{
  "type": "input",
  "id": "消息编号",
  "text": "需要输入的文字",
  "submitMode": "ctrl_enter"
}
```

`submitMode` 支持：

- `ctrl_enter`：输入文字后按 Ctrl + Enter。
- `enter`：输入文字后按 Enter。

电脑端成功时返回 `ack`，失败时返回 `error`。电脑端还兼容旧版手机使用的布尔型 `submit` 字段。

## 测试

运行 Windows 协议测试：

```powershell
python -m unittest -v pc.test_bridge
```

电脑端已经运行时，可以检查打包程序的握手与 Ping：

```powershell
python .\pc\integration_probe.py
```

鸿蒙端单元测试位于 `entry/src/test/`，可以在 DevEco Studio 中运行。

## 安全说明

- 电脑端只接受私有局域网、回环或链路本地来源。
- 配对密钥由电脑端随机生成，可随时更换。
- 单次文字最大长度为 8000 个字符，并带有操作频率限制。
- 当前传输为带随机密钥的普通 WebSocket，适用于家庭或办公可信网络，不建议用于公共 Wi-Fi。
- 普通权限程序无法向“以管理员身份运行”的窗口模拟输入；两者应使用相同权限级别。
- 密码框、远程桌面、游戏及部分安全软件可能拒绝 Windows 模拟输入。
- 正式发布前需要替换为发布账号的正式 HarmonyOS 签名；Windows EXE 可按需要增加代码签名。

## 隐私与仓库规则

以下内容禁止提交：

- `build-profile.json5` 中的真实签名配置。
- `local.properties` 和任何本机 SDK 路径。
- `.cer`、`.p7b`、`.p12`、`.pem`、`.key` 等证书或私钥。
- 电脑端 `%APPDATA%/StarlyBridge/config.json` 中的配对密钥。
- `release/`、HAP、EXE、构建缓存和 Python 缓存。

如果签名口令曾经进入公开仓库，应立即撤销旧证书并更换全部相关口令，仅删除历史文件并不足够。

## 当前状态

项目目前已完成手机端语音识别、手势发送、两种回车模式、扫码配对、Windows 输入桥接、托盘运行和本地交付构建。AppGallery 正式发布签名仍需由发布账号配置。
