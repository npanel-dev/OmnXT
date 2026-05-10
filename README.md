# OmnXT Node Linux 安装与运维说明

本目录是 OmnXT Node 的 Linux 发布包目录，可直接把这里的脚本和压缩包上传到一个公开 GitHub 仓库的 Releases 中，供客户远程安装。

## 目录内容

```text
Bin/
  install.sh
  uninstall.sh
  omnxt-node-x86_64-unknown-linux-gnu.tar.gz
  omnxt-node-x86_64-unknown-linux-gnu.tar.gz.sha256
  omnxt-node-aarch64-unknown-linux-gnu.tar.gz
  omnxt-node-aarch64-unknown-linux-gnu.tar.gz.sha256
```

压缩包内包含：

```text
omnxt-node
omncli
bin/omnxt-node
bin/omncli
install.sh
uninstall.sh
DEPLOY.md
manifest.json
```

`install.sh` 当前会把程序安装到：

```text
/usr/local/omnxt
/usr/local/bin/omnxt-node
/usr/local/bin/omncli
/etc/omnxt/bootstrap.toml
/var/lib/omnxt/state.db
/var/log/omnxt
```

## 支持系统和架构

支持 64 位 Linux：

| CPU | Release 文件 |
| --- | --- |
| x86_64 / amd64 | `omnxt-node-x86_64-unknown-linux-gnu.tar.gz` |
| ARM64 / aarch64 | `omnxt-node-aarch64-unknown-linux-gnu.tar.gz` |

安装脚本会自动识别 CPU 架构，并下载对应包。

支持的服务管理器：

| 系统服务 | 说明 |
| --- | --- |
| systemd | Ubuntu、Debian、CentOS 等常见发行版 |
| OpenRC | Alpine Linux |

## 推荐发布方式

建议新建一个公开仓库，例如：

```text
OWNER/omnxt-node-release
```

仓库主分支放：

```text
install.sh
uninstall.sh
README.md
```

GitHub Releases 上传：

```text
omnxt-node-x86_64-unknown-linux-gnu.tar.gz
omnxt-node-x86_64-unknown-linux-gnu.tar.gz.sha256
omnxt-node-aarch64-unknown-linux-gnu.tar.gz
omnxt-node-aarch64-unknown-linux-gnu.tar.gz.sha256
```

正式给客户使用时建议打 tag，例如 `v1.0.0`。这样客户安装、回滚、排查问题时可以明确版本。

## 一键安装

把下面命令里的 `OWNER/REPO` 换成你的公开仓库。

安装最新正式 Release：

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sudo bash
```

安装指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sudo bash -s -- 1.0.0
```

安装 beta：

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sudo bash -s -- --beta
```

非交互安装并接入 NPanel：

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sudo bash -s -- \
  --panel-type=ppanel \
  --panel-url=https://panel.example.com \
  --server-id=7 \
  --secret-key=replace-with-panel-secret
```

支持的面板类型：

| 参数 | 面板 |
| --- | --- |
| `ppanel` | PPanel / PPanel-Pro / NPanel 的 PPanel 兼容接口 |
| `v2board` | V2Board |
| `xboard` | XBoard |
| `sspanel` | SSPanel-UIM |
| `standalone` | 独立模式，不接面板 |

> NPanel 兼容说明：节点端当前使用 PPanel adapter 对接 NPanel。NPanel 后端需要提供与 PPanel 相同的节点配置接口、用户接口、在线上报接口和字段名；安装和 `omncli panel set` 时仍填写 `--type ppanel` / `--panel-type=ppanel`。

## 卸载

只卸载程序和系统服务，保留配置、数据和日志：

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/uninstall.sh | sudo bash
```

完整清理配置、数据和日志：

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/uninstall.sh | sudo bash -s -- --purge -y
```

本机已有脚本时也可以执行：

```bash
sudo /usr/local/omnxt/uninstall.sh
```

如果 `/usr/local/omnxt/uninstall.sh` 不存在，可以用安装包中的 `uninstall.sh`。

## 服务管理

systemd 系统：

```bash
sudo systemctl status omnxt-node
sudo systemctl restart omnxt-node
sudo systemctl stop omnxt-node
sudo systemctl start omnxt-node
sudo journalctl -u omnxt-node -f --no-pager
```

OpenRC 系统：

```bash
sudo rc-service omnxt status
sudo rc-service omnxt restart
sudo rc-service omnxt stop
sudo rc-service omnxt start
sudo tail -f /var/log/omnxt/omnxt.log
```

也可以用 `omncli`：

```bash
omncli status
omncli restart
omncli log --lines 200
omncli log -f
```

## 常用配置文件

主配置文件：

```text
/etc/omnxt/bootstrap.toml
```

修改配置后重启：

```bash
sudo systemctl restart omnxt-node
```

或：

```bash
sudo omncli restart
```