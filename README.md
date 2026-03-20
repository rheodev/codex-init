# CodexInit

面向中国用户的 Codex CLI 一键初始化脚本。

## 文件

- `bootstrap.sh`: macOS / Linux 入口
- `bootstrap.ps1`: Windows 入口

## 特性

- 已安装即跳过，支持 `--force` 强制重装
- npm 默认使用国内镜像，失败自动回退官方源
- macOS 使用 Homebrew 临时镜像变量安装 Node
- Linux 优先支持 `apt`、`dnf`、`pacman`
- Windows 默认优先 WSL，失败回退原生 PowerShell
- API Key 只做当前会话校验，不自动写入 profile
- 可按提示生成 `~/.codex/config.toml` 与 `auth.json`，已存在默认不覆盖

## 用法

macOS / Linux:

```bash
chmod +x ./bootstrap.sh
./bootstrap.sh
```

Windows PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\bootstrap.ps1
```

常用参数:

```bash
./bootstrap.sh --force
./bootstrap.sh --no-input
```

```powershell
.\bootstrap.ps1 -Mode auto
.\bootstrap.ps1 -Mode native -NoInput
.\bootstrap.ps1 -Force
```

## 说明

- Windows 原生分支使用 `npmmirror` 下载 Node 压缩包到用户目录。
- Linux 的 `dnf` 分支优先适配 Fedora 临时镜像；其他 RHEL 系发行版回退现有系统源。
- 脚本不会永久修改 shell profile、npm 配置或系统软件源。
- 仅在用户确认后生成 Codex 配置文件：macOS / Linux 为 `~/.codex/`，Windows 为 `%USERPROFILE%\.codex\`。
