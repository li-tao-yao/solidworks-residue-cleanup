# 检查清单、卸载命令模板与交付证据格式

## 1. 执行身份与权限边界

在开始排查前先记录执行身份：

```powershell
whoami /user
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
```

- 普通终端或沙箱进程的 `HKCU` 不必然等于交互式桌面用户的 `HKCU`。读取用户级注册表时，确认当前用户 SID 与目标桌面账户一致，或只读查询 `HKEY_USERS\<目标SID>`。
- 脱离沙箱不等于完成 UAC 管理员提权。需要管理员权限的正式卸载、系统服务删除与 `HKLM` 清理，应在用户知情并完成 UAC 确认后执行，不要保存管理员密码或绕过 UAC。
- **并发控制**：只读探测可以并行；MSI 卸载、SQL Server 实例卸载及依赖这些结果的目录删除必须**串行**进行。不要终止用户正在运行的其他安装进程。

---

## 2. 全面资产盘点清单

`scripts/diagnose-residue.ps1` 会自动采集下列主要只读指标；COM 深度扫描与用户自建工程数据盘点则需按本表人工复核：

| 层面 | 检查位置 / 方法 | 判断依据与注意事项 |
|---|---|---|
| **卸载列表 (ARP)** | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`、`WOW6432Node`、`HKCU\Software\...\Uninstall` | 核对 `DisplayName`、`DisplayVersion`、`InstallLocation`、`UninstallString` |
| **MSI 内部登记** | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\<SID>\Products\*\InstallProperties` + `MsiQueryProductStateW` | **严禁使用 `Win32_Product`**；ARP 为空但 `State=5` 即为隐藏已安装产品 |
| **Windows 服务** | `Win32_Service` 与 `HKLM\SYSTEM\CurrentControlSet\Services` | 核对精确 `Name`、`State`、`StartMode`、`PathName`；`FlexNet` 名称不能直接证明归属 |
| **内核驱动** | `Win32_SystemDriver`、`Services` 注册表、`sc.exe query`、`System32\drivers\RsFx*.sys` | `Stopped`/`Disabled` 仍算存在；CIM 有时会漏掉驱动文件已删但服务键还在的项 |
| **SQL 实例与分支** | `HKLM\SOFTWARE\Microsoft\Microsoft SQL Server`（64 位与 `WOW6432Node`） | 核对实例名（如 `TEW_SQLEXPRESS`）、服务路径与使用方，排除 `MySQL` 等其他数据库 |
| **许可配置元数据** | `FLEXlm License Manager`（64/32/HKCU）、`%ProgramData%\FLEXnet\SW_D_*` | 只记录值名、文件名和大小；不读取或输出 license 原文与序列号 |
| **系统 Loader 设置** | `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager` 的 `ExcludeFromKnownDlls` | 检查该值是否存在及条目数；不可依据模板盲目恢复其他系统默认值 |
| **计划任务 / 启动 / 防火墙** | `Get-ScheduledTask` Actions、`Win32_StartupCommand`、Run/RunOnce、`Get-NetFirewallApplicationFilter` | 不只按名称匹配，需看可执行文件路径 |
| **COM 注册** | `HKLM/HKCU\Software\Classes`（含 `WOW6432Node`）下的 `ProgID`、`CLSID`、`TypeLib`、`AppID` | 沿 `LocalServer32`/`InprocServer32` 验证目标文件是否真实存在，保护 `file:///` 第三方集成 |
| **文件目录** | 实际安装目录、`ProgramData`、`AppData`、`LocalAppData`、`Temp`、`Public Documents`、`Common Files`、快捷方式 | 使用 `-Force` 统计隐藏文件并记录读取错误；不能把拒绝访问当成空目录 |

---

## 3. 正式卸载命令形态（需替换为本机实测值）

以下模板仅供在核实 `ProductCode`、安装路径与归属证据后替换使用，**严禁不经核对直接照抄运行**：

```powershell
# 1) 隐藏 MSI 产品正式卸载（串行执行，保留详细日志并复查状态）
$verifiedProductCode = '{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}'
$logPath = Join-Path $env:TEMP ("msi-uninstall-" + $verifiedProductCode.Trim('{}') + ".log")
$proc = Start-Process -FilePath 'msiexec.exe' `
    -ArgumentList @('/x', $verifiedProductCode, '/qn', '/norestart', '/L*v', $logPath) `
    -WindowStyle Hidden -Wait -PassThru
$proc.ExitCode
# 卸载后必须再次调用 MsiQueryProductStateW($verifiedProductCode) 核对是否变为 -1

# 2) SOLIDWORKS Electrical 关联 SQL Server 实例正式卸载
$verifiedSqlSetupPath = 'C:\Program Files\Microsoft SQL Server\<Ver>\Setup Bootstrap\<SQLRelease>\x64\Setup.exe'
$verifiedInstanceName = 'TEW_SQLEXPRESS'
$sqlProc = Start-Process -FilePath $verifiedSqlSetupPath `
    -ArgumentList @('/Q', '/ACTION=Uninstall', "/INSTANCENAME=$verifiedInstanceName", '/FEATURES=SQLENGINE') `
    -WindowStyle Hidden -Wait -PassThru
$sqlProc.ExitCode
```

- SQL Setup 日志位于对应版本的 `Setup Bootstrap\Log\` 下按时间戳命名的目录内；查看 `Detail.txt` 与最终退出码，避免误读旧的 `Summary.txt`。
- 若因历史目录不完整导致 `Setup.exe` 缺失，可先尝试同目录 `SetupARP.exe` 或“设置 → 应用”卸载对应 SQL 组件，或逐一核实相关 SQL MSI 后通过 `msiexec /x` 正式移除。

---

## 4. 清理前单项目证据记录模板

```text
目标：精确绝对路径 / 注册表全路径与值名 / 精确服务名
来源：官方安装器 / 捆绑组件 / 第三方软件 / 未知
归属证据：InstallDate、二进制路径、服务 ImagePath、文件创建时间
共享与个人数据风险：已排除（说明依据） / 仍未知（暂不删除）
动作：正式卸载 / 备份后精确删除 / 同盘移动隔离 / 保留 / 待确认
前置条件：关联进程与服务已停止、目标不含 junction 跳转、已备份注册表或文件
执行结果：退出码、报错详情、完成时间
复查状态：独立重读后的实时状态（如 MSI=-1、Test-Path=$false）
```

---

## 5. 收尾验收清单与交付口径

清理结束后，按相同用户与相同检查范围重新运行 `diagnose-residue.ps1`，核对并如实报告：

1. 已完成正式卸载的产品及各自前后 `MsiQueryProductStateW` 状态变化。
2. 关联 SQL 实例（64 位及 `WOW6432Node`）与专属 `RsFx` 驱动/服务是否已消除。
3. 孤儿 COM 键、授权配置值与精确目标目录是否已清理并验证不存在。
4. 明确列出的受保护保留项（例如 COMSOL LiveLink、MySQL、共享 FlexNet、用户自建模型与 Toolbox、安装介质备份）。
5. 所有访问受限项（`Incomplete`）、待重启事项（`3010`）及未覆盖检查边界。

> 交付结论应表述为：“在列明范围内检查了哪些项、实际移除了哪些项、保留或未能验证哪些项”，不承诺全盘零痕迹或保证后续重装必然成功。

## 官方资料入口

- [SOLIDWORKS 卸载官方说明](https://help.solidworks.com/2024/english/Installation/install_guide/t_removing_installation.htm)
- [Windows Installer ProductState 定义](https://learn.microsoft.com/windows/win32/msi/productstate)
- [MsiQueryProductStateW API 文档](https://learn.microsoft.com/windows/win32/api/msi/nf-msi-msiqueryproductstatew)
- [SQL Server 命令行安装与卸载文档](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt)
