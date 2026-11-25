# 隐藏 MSI 产品、RsFx 驱动与 32 位 SQL 残留核验

## 1. 为什么“卸载列表为空”仍会残留十余个已安装产品

卸载程序异常中断、或手动删除过快捷方式与安装目录后，常出现 **系统“已安装的应用”及第三方卸载工具列表全部为空，但安装新版本依然报错** 的情况。

实测中曾遇到一个典型现象：桌面卸载列表里已经没有任何 SOLIDWORKS 或 SQL 项，但遍历 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\<SID>\Products` 后，发现大量 **SQL Server 2022 子组件** 的缓存 `.msi` 仍在，且调用 `MsiQueryProductStateW` 返回 **`5`（已安装）**。

只遍历 `Uninstall`（ARP）键的清理脚本会完全漏掉这些产品，或者只在 `ARP` 存在时才执行卸载。正确做法是**直接从 `Installer\UserData` 读取 32 位压缩产品代码，解包为标准 `{GUID}` 后调用 `MsiQueryProductStateW` 核验**。

### `MsiQueryProductStateW` 返回值对照

| 状态值 | 含义 | 处理方式 |
|---|---|---|
| `5` | 在当前查询上下文中**已安装** | 若确认归属本次待清理产品且排除共享依赖，通过 `msiexec /x {GUID}` 正式卸载 |
| `1` | 已公告（Advertised） | 核对归属后正式卸载或清理 |
| `2` | 为**其他用户**安装（`UserDataSID` 与当前查询 SID 不同） | 切勿直接声称已卸载；需在对应用户上下文核实 |
| `-1` | 当前上下文未知该产品（未安装 / 已卸载） | 卸载后复查变为 `-1` 才算从当前上下文注销成功 |

> **关键原则**：不要用手工删除 `Uninstall` 键、或删除 `C:\Windows\Installer` 缓存包的方式“伪造无记录”。必须保留 `.msi` 缓存供 `msiexec /x` 正常走完卸载管线。

---

## 2. `RsFx` 内核驱动与服务的“三端交叉核验”

SQL Server / Electrical 相关组件常注册名为 `RsFxXXXX`（如 `RsFx0700`）的文件系统微筛选器驱动。正式卸载产品后，常出现 **驱动 `.sys` 文件已随 MSI 移除，但服务注册表键仍残留** 的情况；同时，WMI/CIM 的 `Win32_SystemDriver` 在某些状态下可能不再列出已失效的项。

因此，核查与验收 `RsFx`（及任何专属服务）必须同时看三处：

1. **驱动枚举**：`Get-CimInstance Win32_SystemDriver | Where-Object Name -match '^RsFx\d+$'`（注意：`Disabled` 或 `Stopped` 状态仍算存在，不能忽略）。
2. **注册表服务键与 SCM**：检查 `HKLM:\SYSTEM\CurrentControlSet\Services\RsFx*` 及 `sc.exe query <服务名>`。
3. **磁盘驱动文件**：检查 `%SystemRoot%\System32\drivers\RsFx*.sys`。

**清理顺序**：
- 只要对应的 SQL MSI 产品仍为 `State=5`，**先用 `msiexec /x` 正式卸载 MSI**（多数情况下会自动移除驱动文件和注册）。
- 仅在所有关联 MSI 均变为 `-1`、驱动已停止、`.sys` 文件已确认消失且无其他 SQL 实例依赖后，才对孤立服务键执行 `reg export` 备份并用 `sc.exe delete <精确服务名>` 清理。

---

## 3. 32 位视图（`WOW6432Node`）的 SQL 残留

在 64 位 SQL 实例映射（`Instance Names\SQL`）清空后，`HKLM\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server` 下仍可能保留：
- 已卸载实例的配置子键（如 `TEW_SQLEXPRESS`）
- 旧版工具键（如 `160\Tools\ClientSetup`）
- 空的引用计数键（如 `RefCount\SQL2022`）

处理方式：确认所有 SQL 实例和专属 MSI 已正式卸载后，仅备份并删除已核实无用的特定子项；父级共享键（如 `Microsoft SQL Server` 根键）若仍包含其他版本或共享条目，绝对不可整根删除。

---

## 4. 验收失败红线（满足任一条即不可宣称完成）

- `msiexec /x` 返回 `0`，但重查 `MsiQueryProductStateW` 仍为 `5`。
- 查询 `MsiQueryProductStateW` 抛出异常却未记录错误。
- SQL 实例卸载失败后，跳过失败项直接手动删 `Microsoft SQL Server` 文件夹或强删注册表掩盖。
- 将访问拒绝（`UnauthorizedAccessException`）的目录或注册表键当成“零残留”。
- 枚举目录未加 `-Force`，漏掉隐藏的 `SW_D_*` 许可数据或配置文件。
- 注册表导出备份失败后仍继续执行删除。
- 仅凭普通服务列表为空就宣称 `RsFx` 驱动已全部清除。
