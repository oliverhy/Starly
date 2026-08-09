# Starly Gateway 一键安装

安装器支持以下系统：

- Ubuntu 22.04 及更新版本
- Debian 12 及更新版本
- CentOS Stream 9，以及兼容的 RHEL/Rocky Linux/AlmaLinux

服务器需要具有公网 IPv4，并允许互联网访问 TCP `80` 和 `443`。Gateway 本身只监听
`127.0.0.1:8780`，不会把明文 WebSocket 端口暴露到公网。

## 域名证书版本

先把域名 A 记录解析到服务器公网 IP，然后把整个 `gateway` 目录上传到服务器并运行：

```bash
cd gateway
sudo bash install-domain.sh starly.example.com admin@example.com
```

安装完成后的地址为：

```text
wss://starly.example.com/ws
```

## 公网 IP 证书版本

公网 IP 必须直接属于当前服务器，不能是内网地址或仅做端口转发的地址：

```bash
cd gateway
sudo bash install-ip.sh 203.0.113.10 admin@example.com
```

安装完成后的地址为：

```text
wss://203.0.113.10/ws
```

IP 证书使用 Let's Encrypt 的 `shortlived` 配置，有效期约 6 天。安装器使用 Certbot
5.4 或更高版本，并配置每 6 小时检查一次续期。域名证书也复用同一个续期任务。

首次测试可在命令末尾加 `--staging`，但测试证书不会被手机或浏览器信任：

```bash
sudo bash install-domain.sh starly.example.com admin@example.com --staging
```

## 安装内容

- `/opt/starly-gateway`：Gateway 程序及 Python 虚拟环境
- `/var/lib/starly-gateway`：配对文件和 SQLite 数据库，重复安装时保留
- `/opt/starly-acme`：独立的 Certbot 5.x 虚拟环境
- `/etc/nginx/conf.d/starly-gateway.conf`：TLS 与 WSS 反向代理
- `starly-gateway.service`：Gateway 常驻服务
- `starly-cert-renew.timer`：证书自动续期定时器
- `/root/starly-gateway-credentials.txt`：首次生成的 Pairing ID 和 Token，仅 root 可读

在 PC Bridge 的“公网安全配对 → 配置服务器”中填写该文件里的 Gateway URL、
Pairing ID 和 Token。Token 只允许第一台 PC 完成首次登记；服务器签发设备专属凭据后，
后续连接使用该凭据，Token 不能被拿去添加陌生手机或另一台 PC。PC 端的 Token、设备凭据、
会话令牌和 X25519 私钥均通过 Windows DPAPI 加密保存。

常用检查命令：

```bash
systemctl status starly-gateway nginx --no-pager
systemctl list-timers starly-cert-renew.timer
journalctl -u starly-gateway -n 100 --no-pager
curl https://starly.example.com/health
```

手动验证续期流程：

```bash
sudo /opt/starly-acme/bin/certbot renew --dry-run
```
