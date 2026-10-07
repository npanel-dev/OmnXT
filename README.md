# OmnXT Node Linux 安装与运维说明

本仓库提供 OmnXT Node 的 Linux 发布包与安装脚本。发布地址为 [npanel-dev/OmnXT Releases](https://github.com/npanel-dev/OmnXT/releases)。

本次版本为 **v0.1.66**，Node 与 CLI 的程序版本均为 `0.1.66`。修复内容、源码版本、验证结果与验收边界见 [发布说明](releases/v0.1.66.md)；产物校验值见 [发布清单](releases/v0.1.66.json)。

本轮 SimNet 修复包含服务端逻辑，需要升级 Node。客户端消费返窗修复还需要应用对应的新 SDK；仅升级 Node 不代表全部客户端改动已生效。

## Linux 发布文件

```text
install.sh
uninstall.sh
omnxt-node                       # 本地交付的 x86_64 Node
omncli                           # 本地交付的 x86_64 CLI
Bin/                             # 最新 Linux 包，其他已有文件保留
  omnxt-node-x86_64-unknown-linux-gnu.tar.gz
  omnxt-node-x86_64-unknown-linux-gnu.tar.gz.sha256
  omnxt-node-aarch64-unknown-linux-gnu.tar.gz
  omnxt-node-aarch64-unknown-linux-gnu.tar.gz.sha256
dist/v0.1.66/                    # 本地版本归档与两架构解包目录
```

压缩包内包含：

```text
omnxt-node-{target}/
  bin/omnxt-node
  bin/omncli
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

发布包面向 glibc 2.28 或更新版本的 64 位 Linux：

| CPU | Release 文件 |
| --- | --- |
| x86_64 / amd64 | `omnxt-node-x86_64-unknown-linux-gnu.tar.gz` |
| ARM64 / aarch64 | `omnxt-node-aarch64-unknown-linux-gnu.tar.gz` |

安装脚本会自动识别 CPU 架构，并下载对应包。

支持的服务管理器：

| 系统服务 | 说明 |
| --- | --- |
| systemd | Ubuntu、Debian、CentOS 等常见发行版 |
| OpenRC | 使用 glibc 的 OpenRC 环境 |

本次没有发布 musl 产物，默认使用 musl 的 Alpine 不属于这两个 GNU 包的直接支持范围。

## 推荐发布方式

当前公开发布仓库为：

```text
npanel-dev/OmnXT
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

正式版本使用 tag，例如 `v0.1.66`。`manifest.json` 保存实际 Rust 源码提交，发布清单保存归档与二进制 SHA256。

## 一键安装

安装最新正式 Release：

```bash
curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/install.sh | sudo bash
```

安装指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/install.sh | sudo bash -s -- 0.1.66
```

安装 beta：

```bash
curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/install.sh | sudo bash -s -- --beta
```

非交互安装并接入 NPanel：

```bash
curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/install.sh | sudo bash -s -- \
  --panel-type=ppanel \
  --panel-url=https://panel.example.com \
  --server-id=7 \
  --secret-key=replace-with-panel-secret
```

安装器可识别的面板类型与当前接入状态：

| 参数 | 面板与状态 |
| --- | --- |
| `ppanel` | PPanel / PPanel-Pro / NPanel 的 PPanel 兼容接口 |
| `v2board` | 可识别配置类型，专用线上 adapter 尚未实现 |
| `xboard` | 可识别配置类型，专用线上 adapter 尚未实现 |
| `sspanel` | 可识别配置类型，专用线上 adapter 尚未实现 |
| `standalone` | 独立模式，不接面板 |

> NPanel 兼容说明：节点端当前使用 PPanel adapter 对接 NPanel。NPanel 后端需要提供与 PPanel 相同的节点配置接口、用户接口、在线上报接口和字段名；安装和 `omncli panel set` 时仍填写 `--type ppanel` / `--panel-type=ppanel`。

## 卸载

只卸载程序和系统服务，保留配置、数据和日志：

```bash
curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/uninstall.sh | sudo bash
```

完整清理配置、数据和日志：

```bash
curl -fsSL https://raw.githubusercontent.com/npanel-dev/OmnXT/main/uninstall.sh | sudo bash -s -- --purge -y
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
