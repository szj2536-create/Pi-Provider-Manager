# Pi 模型与第三方 API 管理器 / Pi Models and Third-Party API Manager

[中文说明](#中文说明) · [English](#english)

## 中文说明

一个可从任意目录复制、移动并运行的 Windows 工具，用于维护 Pi 的第三方 API 供应商、模型和登录凭据。目标电脑必须已安装并正在使用 Pi；程序只从自身目录加载脚本，不依赖原电脑的 Pi 安装路径或固定盘符。

## 运行环境

- 目标电脑为 Windows 10 或 Windows 11
- Windows PowerShell 5.1
- 目标电脑已安装并正在使用 Pi
- Windows Forms（系统自带）
- 不需要安装第三方 PowerShell 模块；不联网、不发送 API 请求

## 下载或复制后启动

确认目标电脑已安装并正在使用 Pi 后，将项目目录完整下载或复制到目标电脑的任意目录（路径可以包含空格），然后双击：

```text
start.cmd
```

也可以在 PowerShell 中运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\pi-model-manager.ps1
```

不要只复制 `start.cmd`；它需要从自身目录加载 `pi-model-manager.ps1`。

程序默认显示中文。在主窗口右上角选择 `English` 可切换为英语，选择 `中文` 可切回中文；供应商列表、按钮、状态信息以及之后打开的对话框会立即使用所选语言。

## Pi 配置目录规则

程序在目标电脑上按以下优先级定位 Pi 配置目录：

1. `-AgentDirectory` 启动参数
2. `PI_CODING_AGENT_DIR` 环境变量
3. `%USERPROFILE%\.pi\agent`

目录中由程序管理的文件是 `models.json` 和 `auth.json`。使用 `-AgentDirectory` 或环境变量可将配置指向指定目录；工具定位的是目标电脑的 Pi 配置目录，不依赖原电脑的 Pi 安装路径、本项目所在的盘符或用户名。

## 功能与安全边界

- 新增、编辑、重命名、删除第三方供应商
- 新增、修改、删除模型
- 图形界面支持中文和 English，可通过窗口右上角的“语言 / Language”下拉框即时切换
- API Key 使用密码框输入，不在界面列表或日志中显示
- OAuth 等非 API Key 登录凭据保持只读；删除供应商时保留受保护凭据
- 打开配置文件前会对 `auth.json` 显示敏感内容提醒
- 保存时进行并发变化检查、原子写入和回滚保护

最终发布项目清单仅保留 `.gitignore`、`README.md`、`start.cmd`、`pi-model-manager.ps1` 和 `tests/`；最终仓库不包含 `_tickets/`、`_receipts/`、`auth.json` 或 `models.json`。施工期间的 `_tickets/`、`_receipts/` 仅供项目内复审，按发布流程清理。敏感配置、日志和临时文件均不属于仓库并由 `.gitignore` 排除。不要把 API Key、令牌、密码或真实机器生成配置复制到项目目录或提交到公开仓库。

## 检查与测试

CRUD 自测、WinForms GUI 冒烟测试和独立项目测试只使用系统临时目录中的假配置：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-test.ps1
```

发布就绪测试会检查公开发布边界，并把发布文件复制到带空格的临时异路径后重新运行自测和 GUI 冒烟测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\release-readiness-test.ps1
```

只检查指定配置目录中的 JSON 结构（不发起 API 请求）：

```powershell
$tempAgent = Join-Path $env:TEMP ('pi-provider-manager-check-' + [guid]::NewGuid().ToString('N'))
try {
  powershell -NoProfile -ExecutionPolicy Bypass -File .\pi-model-manager.ps1 -CheckOnly -AgentDirectory $tempAgent
  if ($LASTEXITCODE -ne 0) { throw "CheckOnly failed: $LASTEXITCODE" }
} finally {
  if (Test-Path -LiteralPath $tempAgent) {
    Remove-Item -LiteralPath $tempAgent -Recurse -Force
  }
}
```

自动化发布测试是“临时异路径副本”的模拟，不等同于已在真实第二台电脑验证；本项目未声称完成第二台电脑实机验证。

---

## English

A portable Windows GUI for managing Pi third-party API providers, models, and login credentials. The project can be copied to and run from any directory, including paths containing spaces. It does not depend on the original computer's Pi installation path, drive letter, or user name.

### Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- Pi already installed and in use on the target computer
- Windows Forms, included with Windows
- No third-party PowerShell modules required
- No network requests or API calls are made by this manager

### Start the application

Download or copy the complete project directory, then double-click:

```text
start.cmd
```

Alternatively, run it from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\pi-model-manager.ps1
```

Do not copy `start.cmd` by itself; it loads `pi-model-manager.ps1` from the same directory.

The interface starts in Chinese. Use the **语言 / Language** selector in the upper-right corner to switch immediately between `中文` and `English`. Window text, buttons, table headings, status messages, validation errors, and subsequently opened dialogs follow the selected language.

### Pi configuration directory

The application locates Pi's configuration directory in this order:

1. The `-AgentDirectory` command-line argument
2. The `PI_CODING_AGENT_DIR` environment variable
3. `%USERPROFILE%\.pi\agent`

It manages `models.json` and `auth.json` inside that directory. The optional argument or environment variable can be used to target another Pi configuration directory.

### Features and security boundaries

- Add, edit, rename, and remove third-party providers
- Add, rename, and remove models
- Switch the GUI between Chinese and English at runtime
- Enter API keys through password fields; keys are not displayed in lists or logs
- Keep OAuth and other non-API-key credentials read-only
- Preserve protected credentials when their custom provider is removed
- Warn before opening the potentially sensitive `auth.json` file
- Detect concurrent file changes and use atomic writes with rollback protection

The release repository contains only `.gitignore`, `README.md`, `start.cmd`, `pi-model-manager.ps1`, and `tests/`. It must not contain generated `auth.json`, `models.json`, logs, temporary files, real API keys, tokens, passwords, or machine-generated configuration.

### Tests

Run the standalone CRUD and bilingual WinForms smoke tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-test.ps1
```

Run the complete release-readiness check, including privacy checks and a portable copy test from a temporary path containing spaces:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\release-readiness-test.ps1
```

The portable copy test is an automated simulation. It does not claim that the project has been manually verified on a second physical computer.
