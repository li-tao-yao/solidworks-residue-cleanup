# 孤儿 COM 键清理与常见工程故障排查

## 1. 「无法注销以下库」与孤儿 COM 注册清理

### 1.1 产生原因

卸载器在收尾阶段调用 `regsvr32 /u <dll>` 反注册组件时，如果对应 DLL 文件已提前被删除或当初未能完整写入，会弹窗提示「无法注销以下库」（例如 `sldpropertyhandler.dll`、`sldfuncfeat.dll`、`sldPresMgr.dll` 等）。

该弹窗本身不影响软件继续卸载，但它会在注册表 `Classes` 中留下指向不存在路径的孤儿 `CLSID` / `ProgID` / `TypeLib` 键。

### 1.2 只读扫描与五条必避坑规则

只读搜索命令示例（注意按需同时查 64 位与 `WOW6432Node` 视图，以及目标用户 `HKCU`）：

```powershell
reg.exe query HKLM\SOFTWARE\Classes /f "*SolidWorks*" /s /d
reg.exe query HKCU\Software\Classes /f "*SolidWorks*" /s /d
```

解析和清理这些命中项时，**必须遵守以下 5 条规则**：

1. **带引号路径不能漏判**：`LocalServer32` 等值常带有双引号（如 `"C:\Program Files\...\app.exe"`），甚至带命令行参数。先剥离外层引号和尾部参数，再做 `Test-Path` 判断文件是否已死，否则会漏判死键。
2. **保护 `file:///` 第三方集成**：如果机上装有 COMSOL 等 CAE 软件，LiveLink 会在注册表写入类似 `file:///C:/Program Files/COMSOL/.../SolidWorks...dll` 的集成注册。**凡是以 `file:///` 开头且目标软件仍存在的注册项，严禁当作残留删除**。
3. **`Classes\TypeLib\{G}` 与 `Classes\WOW6432Node\TypeLib\{G}` 是两个独立真键**：在 64 位 Windows 上它们不是同义镜像；清理已确认失效的死键时，两处都要分别核验，不要只删一处。
4. **多版本根目录保护**：同一个 `ProgID` 或 `TypeLib` 根下可能并存多个版本（例如 `1.0` 和 `2.0`）。单个失效子版本不能授权直接删除整个父键，必须核对根下是否存在其他仍指向有效文件的版本。
5. **按 `{GUID}` 根去重删除**：命中的往往是 `...\InprocServer32` 或 `...\LocalServer32`，真正的清理单元是其所属的 `(CLSID|TypeLib|AppID)\{GUID}` 根（统一转为大写去重），并应在清理前 `reg export` 备份。`SldPart.Document` 等常见关联键或纯无害文本列表在确认非损坏项时可保留，重装会自动覆盖。

---

## 2. 常见安装、卸载与 PowerShell 执行故障

| 场景 | 常见根因 | 正确处理方式 |
|---|---|---|
| **静默卸载返回 `1603`** | 查看系统 Application 事件日志中的 `MsiInstaller` 事件，常见为错误 `1730`（非管理员权限无法卸载机器级产品）或文件被进程占用 | 停止依赖后续清理，查明日志；改在 UAC 提升的管理员 PowerShell 中运行并记录返回码 |
| **沙箱/工具内查不到 `HKCU` 残留** | 当前工具进程或沙箱账户的 SID 与桌面登录用户不同 | 用 `whoami /user` 核对当前 SID；按目标用户上下文或 `HKEY_USERS\<SID>` 查询 |
| **递归删除被权限/安全策略拦截** | 目录范围过大（如包含 `Public Documents`、`AppData\Roaming`、`Common Files` 等可能含个人工程或共享数据） | 停止大范围删除；先只读列出子目录清单，排除个人数据与第三方目录后，将范围缩小到明确的配置/日志子目录 |
| **`Remove-Item` 删特定 `Classes` 键报拒绝访问** | 即使拥有 Administrators 权限，某些长路径/特殊键或视图映射下 PowerShell 注册表 Provider 可能报错 | 先核对精确路径、32/64 位视图及 ACL（不要盲目 `takeown` 夺取整个 `Classes` 所有权）；在权限与授权均允许时可用系统 `reg.exe delete "<Key>" /f /reg:64` 精确删除 |
| **PowerShell 脚本里 `sc delete` 没反应** | 在 PowerShell（含 5.1 与 7）中，`sc` 是 `Set-Content` 的内置别名 | 永远显式写 **`sc.exe delete "<服务名>"`** |
| **数组拼接元素变成单个长字符串** | PowerShell 中逗号 `,` 优先级高于 `+`，写成 `@($prefix + 'a', $prefix + 'b')` 会被解析为字符串加数组，最终只有 1 个元素 | 所有拼接元素必须加括号：`@(($prefix + 'a'), ($prefix + 'b'))`，并在操作前打印数量核对 |
| **Windows PowerShell 5.1 中文乱码报假语法错** | PS 5.1 将无 BOM 的 UTF-8 文件按系统 ANSI（GBK）代码页读取 | 交付或自写含中文的 `.ps1` 务必保存为 **UTF-8 with BOM**；纯工具脚本建议全用 ASCII |
| **开启防护脚本报 `0x800106ba`（Defender 无法开启）** | 本机安装了第三方主杀毒软件（如卡巴斯基、火绒等），Windows 自动接管并禁用 Defender 实时保护 | 属正常系统行为，不必强行恢复 Defender；通过 `SecurityCenter2` 确认主杀软处于正常开启状态即可 |
| **历史脚本修改了 `ExcludeFromKnownDlls`** | 部分旧配置向 `Session Manager\ExcludeFromKnownDlls` 写入系统 DLL 白名单豁免 | 属全局安全降级；先 `reg export` 备份该项再清除多余条目，恢复系统已知 DLL 保护 |
| **误删警告：`Remove-Item` 不会进回收站** | 标准 PowerShell `Remove-Item` 属于直接删除 | 清理大目录（尤其是用户可能还需核对的旧安装文件夹）时，优先用同盘 `Move-Item` 移至临时隔离区，确认无误后再由用户决定删除 |

---

## 3. 是否需要安装 SOLIDWORKS Electrical（模块选型避坑）

很多装机/重装失败的根因其实在于“根本不需要却勾选了 Electrical”，从而额外引入了 **SQL Server Express (`TEW_SQLEXPRESS`)** 与 **`RsFx` 驱动** 这整套复杂依赖：

- **只做机械结构设计、零件建模、装配体、干涉检查与工程图**：只需 **Mechanical CAD**，无需安装 Electrical，也无需部署 SQL Server。
- **需要正式电气原理图、端子编号、线束自动布线与机电协同物料管理**：才需要评估安装 **SOLIDWORKS Electrical**（以及其依赖的 SQL 实例）。
- **切勿因为“产品里带电路板或传感器”就全选所有模块**；Electrical 不是电磁场或信号仿真工具，减少不必要的捆绑组件能显著降低安装失败与后续清理成本。
