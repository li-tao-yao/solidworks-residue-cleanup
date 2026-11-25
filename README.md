# SOLIDWORKS 卸载残留排查与清理 · SOLIDWORKS Residue Audit & Cleanup

**面向 Windows 的 SOLIDWORKS / Electrical / SQL Server 卸载残留只读诊断脚本与 AI Agent 清理技能（兼容 Windows PowerShell 5.1 与 PowerShell 7+）。**

> A read-only Windows audit script and AI Agent Skill for investigating and safely cleaning up SOLIDWORKS, Electrical (`TEW_SQLEXPRESS`), hidden MSI registrations, `RsFx` drivers, orphan COM keys, and non-ASCII hostname FLEXlm startup failures.

[中文](#中文) · [English](#english)

---

## 中文

### 为什么需要这个项目？

卸载 SOLIDWORKS 或安装失败后，常见到四类“看起来清干净了，实际上还在阻塞重装”的问题：

1. **桌面卸载列表为空，实际仍残留十余个 MSI 产品**：例如卸载 SOLIDWORKS Electrical 后，Windows“已安装的应用”和第三方卸载器里已经找不到条目，但 `Installer\UserData` 中仍有大量 SQL Server 2022 组件的 `MsiQueryProductStateW = 5`（已安装）登记。
2. **驱动与 32 位注册表漏检**：`RsFx` 等内核驱动的文件虽已随卸载移除，但服务注册表键仍残留；`WOW6432Node` 下的 32 位 SQL 键树与孤儿 COM（如卸载提示“无法注销以下库”）未清理。
3. **误删其他软件共享依赖**：直接按关键词全盘清理，极易误伤 **COMSOL LiveLink**（`file:///` COM 注册）、**MySQL**、或公共 **FlexNet** 许可服务，以及用户的自建零件、模板与 Toolbox 库。
4. **把主机名故障当成卸载残留**：中文计算机名会导致传统 `lmgrd`（ANSI 程序）解析 `this_host` 失败秒退，报错“服务没有报告任何错误（`NET HELPMSG 3534`）”或 `25734@localhost` 连不上——这并不是清理不够干净。

**本项目的解法：**
- **默认完全只读、隐私安全**：随包脚本 `scripts/diagnose-residue.ps1` 只采集计数、产品代码、服务/驱动状态与元数据，**绝不使用会触发静默修复的 `Win32_Product`**，也不输出序列号、license 原文、用户名或主机名。
- **结构化 AI Agent Skill**：通过 [SKILL.md](SKILL.md) 与 `references/` 下 4 份专题手册，约束 AI 助手先盘点取证、严格保护共享组件与个人数据、按用户授权串行调用官方卸载器并实时复查验收。

---

### 目录结构

```text
solidworks-residue-cleanup/
├── SKILL.md                                   # AI Agent 主技能规范（流程、红线与命令模板）
├── agents/openai.yaml                         # Codex / OpenAI 风格 Agent 界面元数据
├── references/
│   ├── checklist-and-commands.md              # 全面盘点表、msiexec / SQL Setup 卸载模板与验收格式
│   ├── hidden-msi-and-drivers.md              # ARP 为空但 MSI State=5、RsFx 三端核验与 32 位 SQL
│   ├── com-and-troubleshooting.md             # 孤儿 COM 5 坑、UAC 1603/1730、PowerShell 避坑与选型建议
│   └── flexlm-non-ascii-hostname.md           # 中文主机名导致 FLEXlm 秒退与 ActiveComputerName 陷阱
├── scripts/
│   ├── diagnose-residue.ps1                   # 只读诊断主脚本（支持 Win PS 5.1 & PS 7+，64 位）
│   └── audit-helpers.ps1                      # 压缩 ProductCode 解码、分类规则与安全写文件封装
├── tests/
│   └── smoke.ps1                              # 本地离线回归测试（GUID、分类、防覆盖、隐私检查）
├── LICENSE                                    # MIT License
└── README.md
```

---

### 快速开始（人工只读诊断）

**运行要求**：64 位 Windows 10/11 + 系统自带 **64 位 Windows PowerShell 5.1** 或 **PowerShell 7+**。初次排查用普通用户权限即可（若报告部分项显示 `Incomplete`，再按需在管理员 PowerShell 中复查）。

1. 克隆或下载并解压本仓库，在仓库根目录打开 PowerShell：

```powershell
# 仅在控制台输出脱敏汇总（不落盘、不改系统）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnose-residue.ps1
```

2. 若需要查看具体的产品 GUID、MSI 状态码（`5` / `-1`）、服务路径与不存在的目录明细，用 `-OutFile` 写出一个新的本地 JSON 文件（不可覆盖已有文件；支持用 `-AdditionalPath` 追加自定义安装盘符路径）：

```powershell
.\scripts\diagnose-residue.ps1 -AdditionalPath 'D:\SolidWorks' -OutFile .\residue-audit.json
```

#### 控制台汇总输出示例（不含敏感信息）

```json
{
  "Status": "CheckedListedScopes",
  "Context": {
    "IsAdmin": false,
    "PowerShellVersion": "7.6.10",
    "Is64Bit": true,
    "HasNonAsciiActiveHostname": false,
    "PendingHostnameReboot": false
  },
  "Checks": [
    { "Check": "ARP HKLM:\\SOFTWARE", "Status": "Checked", "Rows": 0 },
    { "Check": "InstallerUserData", "Status": "Checked", "Rows": 14 },
    { "Check": "Paths", "Status": "Checked", "Rows": 2, "TotalChecked": 14 }
  ],
  "Errors": []
}
```

#### 结果怎么看？

| 观察到的现象 | 含义与建议下一步 |
|---|---|
| `ARP` 为 `0`，但 `InstallerUserData` 有 `CurrentContextState = 5` | 卸载列表已空但 MSI 仍在登记。按 [隐藏 MSI 与驱动核验](references/hidden-msi-and-drivers.md) 核实归属后用 `msiexec /x` 正式卸载 |
| `Services` 无异常，但 `RsFxDrivers` / `RsFxServiceKeys` / `RsFxDriverFiles` 非零 | 存在停用或残留驱动。先完成相关 SQL MSI 卸载，再三端交叉核验 |
| `Context.HasNonAsciiActiveHostname = true` 或 `PendingHostnameReboot = true` | 中文主机名或改名未重启可能引发 `lmgrd` 启动失败。详见 [中文主机名 FLEXlm 排查](references/flexlm-non-ascii-hostname.md) |
| 某项 `Status = "Incomplete"` | 存在访问拒绝或模块受限，不能当作无残留；可在管理员终端重跑并查看 `Errors` 中的异常类型 |
| 出现 `SharedComponent`（如 `SQLBrowser`、`FlexNet`） | 极可能被其他软件共用，清理前必须查清依赖方 |

---

### 作为 AI Agent Skill 使用

本仓库遵循通用 `SKILL.md` 规范，可接入 **Codex、Antigravity、Claude Code、Cursor** 等支持技能目录的助手：

- **方式一（安装到技能目录）**：将本仓库整个目录复制到你所用工具的 skills 目录并命名为 `solidworks-residue-cleanup`（例如 `~/.codex/skills/solidworks-residue-cleanup` 或工作区 `.agents/skills/solidworks-residue-cleanup`）。
- **方式二（直接指定路径）**：克隆本仓库后，在对话中让助手先读取根目录 [SKILL.md](SKILL.md)。

**推荐提问示例：**
> 使用 `solidworks-residue-cleanup` skill，先只读运行 `diagnose-residue.ps1` 盘点本机 SOLIDWORKS、Electrical SQL 实例和驱动残留，区分专属项与可能被 COMSOL/MySQL 共享的组件，把只读结论发给我确认后再决定是否清理。

---

### 安全边界与回归测试

- **不越权修改系统**：附带脚本只有只读诊断功能，不包含一键强删脚本；所有清理动作必须基于本次实测证据和用户授权。
- **不收集隐私**：`.gitignore` 已屏蔽 `*.json`、`*.reg`、`*.log`、`*.lic` 等本地现场文件。向外反馈问题时，请只贴控制台汇总或脱敏片段，切勿上传包含本机路径/授权信息的完整报告。
- **运行本地测试**（同时支持 Windows PowerShell 5.1 与 PowerShell 7+）：

```powershell
pwsh -NoProfile -File .\tests\smoke.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1
```

---

## English

### Overview

This repository provides a **read-only Windows diagnostic script** and a structured **AI Agent Skill** for auditing and safely cleaning up failed or incomplete **SOLIDWORKS**, **SOLIDWORKS Electrical (`TEW_SQLEXPRESS`)**, **SQL Server**, **RsFx driver**, and **orphan COM** residues—while protecting shared dependencies such as **COMSOL LiveLink**, **MySQL**, shared **FlexNet** services, and user CAD/Toolbox data.

#### Key Capabilities
- **Detects Hidden MSI Registrations (`State = 5`)**: Queries `Installer\UserData` and `MsiQueryProductStateW` directly—**never invoking `Win32_Product`** (which triggers unintended MSI self-repairs)—to catch products missing from Installed Apps / Add-Remove Programs.
- **Triple-Checks `RsFx` Drivers & 32-bit SQL Views**: Inspects `Win32_SystemDriver`, `CurrentControlSet\Services`, `System32\drivers\RsFx*.sys`, and both 64-bit / `WOW6432Node` SQL trees.
- **Identifies Non-ASCII Hostname `lmgrd` Failures**: Privacy-safely flags non-ASCII active computer names and pending hostname reboots (`Context.HasNonAsciiActiveHostname`, `PendingHostnameReboot`) without exposing actual hostnames.
- **PowerShell 5.1 & 7+ Compatible**: Runs out of the box on 64-bit Windows 10/11 with built-in Windows PowerShell 5.1 or PowerShell 7+.

### Quick Start

Run the read-only summary audit in a 64-bit PowerShell window:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnose-residue.ps1
```

Write full details (including `ProductCode` GUIDs, `LocalPackage` paths, and `InstallLocation`) to a **new** local JSON file:

```powershell
.\scripts\diagnose-residue.ps1 -AdditionalPath 'D:\SolidWorks' -OutFile .\residue-audit.json
```

> Note: Detailed JSON reports contain local filesystem paths and installed product metadata—review before sharing publicly.

### Using as an AI Agent Skill

Place this directory into your agent's skills folder as `solidworks-residue-cleanup` (compatible with Codex, Antigravity, Claude Code, Cursor, etc.), or point your agent directly to [SKILL.md](SKILL.md). Note that the detailed reference guides under `references/` are written in Chinese while console schemas and scripts are in English.

### Tests

Run the offline regression suite (covers packed GUID decoding, component classification, non-overwrite JSON output, access-denied `Incomplete` tracking, privacy filtering, and `Paths.Rows` counting):

```powershell
pwsh -NoProfile -File .\tests\smoke.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1
```

## License

[MIT](LICENSE)
