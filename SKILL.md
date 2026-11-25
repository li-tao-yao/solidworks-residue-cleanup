---
name: solidworks-residue-cleanup
description: >
  Use on Windows when SOLIDWORKS installation fails, an uninstall leaves hidden residue, or Installed Apps / third-party uninstallers show empty lists while Electrical SQL Server instances (such as TEW_SQLEXPRESS), hidden MSI registrations (State=5), RsFx drivers, FLEXlm services (including non-ASCII hostname failures), or orphan COM keys remain. Also triggers on "SOLIDWORKS 装不上要清理残留", "卸载列表为空但仍提示已安装", "Electrical 卸载不干净", "25734@localhost". Does NOT bypass software licensing/activation or blindly wipe shared SQL/MySQL/COMSOL/FlexNet components.
---

# SOLIDWORKS 卸载残留排查与清理

先确认目标版本及用户需求属于“只读盘点”还是“已授权清理”。用户仅要求排查时，严格保持只读；获得明确清理授权后，按产品归属、共享依赖和个人数据保护边界串行推进，并以实时系统状态复查验收。

## 关键红线（先看这里）

1. **普通卸载列表为空 ≠ 已卸载**：Windows Installer 仍可能保留 `State=5` 的隐藏产品登记（如卸载 Electrical 后遗留的十余个 SQL Server 2022 子组件）。必须枚举 `Installer\UserData` 并调用 `MsiQueryProductStateW`，不能只看 ARP 卸载列表。
2. **严禁使用 `Win32_Product`**：在 Windows 上查询 `Win32_Product` 会触发全部已安装 MSI 的一致性检查与静默修复，必须用 `Installer\UserData` + `MsiQueryProductStateW` 只读探测。
3. **保护共享依赖与个人数据**：`MySQL`、其他软件使用的 `FlexNet`（如 COMSOL / MATLAB / AutoCAD）、通用 `SQLBrowser`/`SQLWriter`/运行库，以及用户自建零件、装配体、工程图、模板和 Toolbox 库均不得因关键词匹配而误删。
4. **不将 `exit=0` 或界面刷新当作验收**：每个动作后必须独立重读系统状态；存在访问拒绝的检查项一律记为 `Incomplete / Unknown`，绝不把“报错空输出”说成“无残留”。
5. **不输出敏感许可内容**：只记录授权配置值名、文件长度或存在性，不读取或公开序列号、完整 license 文本或凭证环境变量。

## 工作流程

### 1. 只读建立基线（兼容 Windows PowerShell 5.1 与 PowerShell 7+）

在技能目录或仓库根目录执行随包只读诊断脚本（按需用 `-AdditionalPath` 传入自定义安装目录或隔离区路径，用 `-OutFile` 写出详细 JSON 报告）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnose-residue.ps1 -OutFile .\residue-audit.json
```

核对执行身份（`Context.IsAdmin`、`whoami /user`、目标用户 SID）：沙箱或非交互进程的 `HKCU` 不等于桌面用户 `HKCU`，需 UAC 提权时应记录清晰边界，不绕过安全机制。

### 2. 交叉核对与正式卸载（串行执行）

先正式卸载，再处理剩余驱动、孤儿 COM 和文件；切勿先手动删掉 `MSSQL` 文件夹或伪造删除 ARP/Installer 键：

1. **官方产品卸载器**：优先用对应版本的 SOLIDWORKS 安装管理器移除主程序及专用附属组件（如 CEF、Marketplace 等）。
2. **Electrical 捆绑 SQL 实例**：核对 SQL 实例映射（64 位与 `WOW6432Node`）、`InstallDate` 与使用方后，用匹配版本的 SQL Server Setup 卸载指定实例（如 `TEW_SQLEXPRESS`）。
3. **ARP 缺失但 `State=5` 的隐藏 MSI**：确认归属与 `CacheExists` 后，使用实时发现的 `ProductCode` 串行调用 `msiexec /x`：

```powershell
$args = '/x ' + $verifiedGuid + ' /qn /norestart /L*v "' + $logPath + '"'
$proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -WindowStyle Hidden -Wait -PassThru
# 必须再次调用 MsiQueryProductStateW 核验状态变为 -1，不能只看 ExitCode
```

| `msiexec` 返回码 | 含义与下一步 |
|---|---|
| `0` 且复查 `-1` | 已从当前上下文注销，继续核查对应驱动与残余目录 |
| `0` 但复查仍 `5` | 未真正移除，读取详细 `/L*v` 日志定位阻塞，严禁手删注册表掩盖 |
| `3010` | 需重启生效，记录待重启事项，重启后再做最终验收 |
| `1605` | 当前上下文未登记此产品，核对 SID 与安装上下文，不能报为本次卸载成功 |
| `1603` | 一般失败（常见原因为 1730 非管理员权限或进程占用），读详细日志 |
| `1618` | 另一安装进程占用中，等待完成，禁止并发重试 |

### 3. 精确清理剩余项（仅在正式卸载与归属确认后）

- **驱动与服务**：交叉检查 `Win32_SystemDriver`、`Services` 注册表、`sc.exe query` 与 `System32\drivers\RsFx*.sys`（注意 PowerShell 中 `sc` 是 `Set-Content` 别名，必须写 `sc.exe`）。
- **孤儿 COM 键**：按 `ProgID -> CLSID -> LocalServer32/InprocServer32 -> TypeLib/AppID` 溯源至 `{GUID}` 根；保护 `file:///` 第三方集成（如 COMSOL LiveLink）与多版本根，先 `reg export` 备份再删死键。
- **许可与系统设置**：检查 `ExcludeFromKnownDlls` 与 `FLEXlm License Manager` 精确值名；若遇到中文/非 ASCII 计算机名导致合法 `lmgrd` 服务启动报「服务没有报告任何错误」，先按专篇排除，不要误当作卸载残留反复重清。
- **目录清理**：核对绝对路径与 `Resolve-Path`、排除 junction/reparse point 及个人数据；大目录建议同盘 `Move-Item` 隔离确认后再清理，并牢记标准 `Remove-Item` 不会进入回收站。

### 4. 验收与交付

验收报告须逐项列明：**已移除项（含 MSI 前后状态）、已确认零残留的检查范围、受保护保留项（COMSOL/MySQL/共享 FlexNet 等）、权限受限未覆盖项（`Incomplete`）、以及待重启事项**。不得承诺“全盘绝对零痕迹”或“保证重装必然成功”；若重装仍报错，优先读取 `%APPDATA%\SOLIDWORKS\Installation Logs\<版本>\SummaryIMLog_*.txt`（UTF-16 编码）尾部错误原文。

## 参考文档（按需读取）

| 场景 | 文档 |
|---|---|
| 完整资产检查表、卸载命令模板与交付证据格式 | [检查清单与命令模板](references/checklist-and-commands.md) |
| ARP 为空但 MSI `State=5`、`RsFx` 驱动三端核验与 32 位 SQL 残留 | [隐藏 MSI 与驱动核验](references/hidden-msi-and-drivers.md) |
| 孤儿 COM「无法注销以下库」扫描 5 坑、UAC 1603/1730 与 PowerShell 避坑 | [COM 清理与常见故障](references/com-and-troubleshooting.md) |
| FLEXlm / `lmgrd` 在中文计算机名下秒退与 `25734@localhost` 报错排查 | [中文主机名导致 FLEXlm 故障](references/flexlm-non-ascii-hostname.md) |
