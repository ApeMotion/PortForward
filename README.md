# VibeDesk Linux 端口转发

在能访问被控 Mac 的 Linux 主机或 NAS 上安装 TCP 转发。客户端在 VibeDesk 里输入 Linux 主机的地址，Linux 把连接转发到 Mac。被控 Mac 需要运行支持固定音频端口的 VibeDesk 版本。

| 用途 | Linux 监听 | 转发到 Mac |
| --- | --- | --- |
| 画面和远程控制 | TCP `9876` | TCP `9876` |
| 系统声音和麦克风 | TCP `9879` | TCP `9879` |

## 安装

### 从 GitHub 一行安装

如果目标 Linux 主机已安装 `curl` 且能访问 `raw.githubusercontent.com`，直接在该主机的终端复制并运行下面这一行。脚本下载完成后会提示输入被控 Mac 的 IPv4 地址。

```bash
(installer=$(mktemp) && trap 'rm -f -- "$installer"' EXIT && curl -fsSL -o "$installer" https://raw.githubusercontent.com/ApeMotion/PortForward/main/install.sh && sudo bash "$installer")
```

### 手动安装

如果目标主机无法从 GitHub 下载脚本，可以在另一台设备上下载 [install.sh](./install.sh) 或整个仓库，再复制到目标主机。在 `install.sh` 所在目录运行下面的命令，把示例 IP 换成被控 Mac 的 IPv4 地址。

```bash
sudo bash ./install.sh 192.168.31.183
```

也可以运行 `sudo bash ./install.sh`，按提示输入 Mac 的 IPv4 地址。两种安装方式使用同一个脚本，为每个端口安装独立的 systemd 服务，启动并设为开机自启。相同参数可以重复运行，正在正常转发的服务会继续运行。

### 安装选项

如果 Linux 已有可用的 `9876` 转发，并且它指向同一台 Mac，只安装音频服务即可。若原服务因为有两条 `ExecStart=` 而无法启动，先把它恢复为只转发 `9876`。

```bash
sudo bash ./install.sh --audio-only 192.168.31.183
```

默认监听 Linux 的所有 IPv4 接口。只想监听某个网卡地址时，传入 `--bind`，例如 `sudo bash ./install.sh --bind 192.168.31.50 192.168.31.183`。客户端需要能访问 Linux 上对应的 TCP 端口，路由器和防火墙规则由网络管理员管理。

### 安装要求

脚本需要 Linux、正在运行的 systemd 232 或更新版本、Bash 4.4 或更新版本、`flock`，以及 `socat`、`ip` 和 `ss`。缺少后三个命令时，脚本会尝试通过 APT、DNF、pacman 或 Zypper 安装依赖。其他发行版可以先通过自己的包管理器安装依赖。监听地址和端口已被占用，或同名服务已有不同配置时，脚本会退出并报告冲突。

## 验证与排查

安装后，从 VibeDesk 客户端断开并重连，再试一下系统声音和麦克风。Mac 在主连接授权成功后才开启 `9879` 监听，因此应在主连接建立后验证音频。

运行以下命令查看 Linux 代理的状态和日志。

```bash
sudo systemctl status vibedesk-proxy-9876.service vibedesk-proxy-9879.service
sudo journalctl -u vibedesk-proxy-9879.service -b
```

## 更换 Mac 地址或卸载

如需更换 Mac 地址或移除代理，在维护窗口停用并删除本脚本创建的服务。下面以音频服务为例。如果需要更改两条转发，对 `9876` 对应的服务也执行相同操作，然后用新地址重跑安装脚本。

```bash
sudo systemctl disable --now vibedesk-proxy-9879.service
sudo rm /etc/systemd/system/vibedesk-proxy-9879.service
sudo systemctl daemon-reload
```
