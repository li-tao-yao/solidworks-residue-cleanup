# SOLIDWORKS 卸载残留排查 · SOLIDWORKS Residue Audit & Cleanup

[中文](#中文) · [English](#english)

## 中文

面向 Windows 用户和协助维护电脑的 AI 助手。遇到卸载列表已经清空、Electrical 仍提示 SQL 实例存在，或者想知道某个 FlexNet 服务是否还在使用时，可以用这个技能收集证据并判断下一步。随包的 PowerShell 脚本只做诊断，实际卸载由助手按用户授权和本机清单处理。

## 开始使用

需要 64 位 Windows 和 64 位 PowerShell 7。下载仓库后，在仓库根目录打开 PowerShell。可先用普通用户运行。

```powershell
pwsh -NoProfile -File ./scripts/diagnose-residue.ps1
```

终端显示每个检查项的读取状态和返回行数。比如 `Paths.Rows` 表示检查了几个位置，每行的 `Exists` 才表示该位置是否存在。SQL 和 FlexNet 共享服务也会命中。行数不能直接用作待卸载产品数。

需要看本机产品名、MSI 状态和实际路径时，显式指定一个新的本地文件。以下示例把报告放在临时目录，文件名每次不同。

```powershell
$report = Join-Path ([IO.Path]::GetTempPath()) ("sw-audit-" + [guid]::NewGuid() + ".json")
./scripts/diagnose-residue.ps1 -OutFile $report
(Get-Content -LiteralPath $report -Raw | ConvertFrom-Json).Evidence.InstallerUserData.Items
```

自定义安装目录或隔离目录可用 `-AdditionalPath` 传入。发布 issue 时优先贴摘要和错误类型。详细报告含本机目录、组件名称和产品标识，分享前请挑选相关字段。

要作为 skill 使用，把仓库放在支持 `SKILL.md` 的技能目录中，文件夹名用 `solidworks-residue-cleanup`。也可直接让助手读取根目录的 [SKILL.md](SKILL.md)。示例请求：“检查 Electrical 卸载后留下的 SQL 组件。先给我只读结果，标出可能被其他软件使用的项。”

## 如何理解结果

| 观察 | 下一步 |
|---|---|
| 卸载列表无条目，MSI 返回 5 | 核对产品 GUID、安装上下文和其他依赖，再决定是否通过正式卸载器处理 |
| SQL 服务已移除，仍发现 RsFx 驱动键 | 核对驱动文件和服务控制管理器的记录 |
| 只有一个旧安装路径或第三方集成 | 先检查文件和使用方，保留仍有用途的配置 |
| 某项显示 `Incomplete` | 已返回的记录仍可用，该项剩余范围未知。先解决对应的权限或模块问题 |

复查范围和卸载顺序见[操作指南](references/workflow.md)。运行回归测试使用 `pwsh -NoProfile -File ./tests/smoke.ps1`。本项目是独立维护的工具。

## English

Use this Windows skill to investigate what remains after a SOLIDWORKS uninstall. It helps with cases where **Installed apps** is empty but Windows Installer still recognizes a product, or a SOLIDWORKS Electrical SQL instance or driver still appears on the machine. The bundled PowerShell script performs a read-only audit. The skill guides an assistant through any cleanup you authorize.

### Quick start

Open the repository in **64-bit PowerShell 7 on Windows** and run the diagnostic as your usual user.

```powershell
pwsh -NoProfile -File ./scripts/diagnose-residue.ps1
```

The console shows a summary for each check. For example, `Paths.Rows` counts the locations checked. The `Exists` field in the detailed report tells you which locations exist. For a custom installation or quarantine folder, pass its path with `-AdditionalPath`.

To inspect product names, MSI states and paths, write the detailed report to a new local JSON file.

```powershell
$report = Join-Path ([IO.Path]::GetTempPath()) ("sw-audit-" + [guid]::NewGuid() + ".json")
./scripts/diagnose-residue.ps1 -OutFile $report
(Get-Content -LiteralPath $report -Raw | ConvertFrom-Json).Evidence.InstallerUserData.Items
```

### Reading the results

| Observation | What to check next |
|---|---|
| The app list is empty, but MSI reports state `5` | Check the product code, installation context and dependencies before using the official uninstaller. |
| The SQL instance service is gone, but an RsFx driver key remains | Check the driver file and its registration with the Service Control Manager. |
| A path points to a third-party integration or shared component | Identify which applications use it before planning removal. |
| A check reports `Incomplete` | Review its error type and rerun that check with the required access or module. |

For use with a skill-aware assistant, place this repository in its skills directory under the name `solidworks-residue-cleanup`, or give the assistant the path to [SKILL.md](SKILL.md). Try asking: “Audit the SQL components left after uninstalling Electrical and identify which ones may be shared.”

The [workflow guide](references/workflow.md) is in Chinese. Run the regression tests with `pwsh -NoProfile -File ./tests/smoke.ps1`. When filing an issue, share the console summary and relevant error types. Review any detailed report for local paths and identifying details first.
