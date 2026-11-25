# 中文 / 非 ASCII 计算机名导致 FLEXlm (`lmgrd`) 许可服务秒退排查

> **重要区分**：这不是“卸载残留没清干净”导致的报错。只要当前计算机名包含中文或非 ASCII 字符，即使把系统清理到完全干净，安装或启动依赖标准 `lmgrd.exe` 的本地许可服务时依然会遇到同样的问题。

---

## 1. 典型症状

在安装或注册本地 FLEXnet / FLEXlm 许可服务后，服务虽然注册成功，但启动几秒内立即失败：

```text
FLEXnet License Manager is successfully installed as one of your Windows Services.
...
服务正在启动 .........................
服务无法启动。
服务没有报告任何错误。
请键入 NET HELPMSG 3534 以获得更多的帮助。
```

如果是客户端安装管理器触发调用，常伴随下游提示：
> `不能核实此服务器存在：25734@localhost`（或对应许可端口）。

查看对应许可服务目录下的 `.log` 日志文件，通常会出现类似记录：

```text
(lmgrd) Unknown Hostname: <乱码字符>
        specified in the license file is not available in the local network database
(lmgrd) daemon shutdown requested - shutting down
```

---

## 2. 根本原因

1. 许多许可文件首行使用占位符：`SERVER this_host ANY <端口>`。
2. `lmgrd.exe` 启动时会将 `this_host` 替换为**当前 Windows 计算机名（Hostname）**，再尝试将其解析为 IP 地址。
3. 传统 `lmgrd.exe` 为 ANSI 程序（在简体中文 Windows 上按代码页 936 / GBK 解释字符串）；当计算机名包含汉字或其他非 ASCII 字符时，主机名解析失败，进程在约 3 秒内主动退出，导致 Windows 服务控制管理器只能报告“服务没有报告任何错误”（`NET HELPMSG 3534`）。

> 本仓库的 `scripts/diagnose-residue.ps1` 已内置 `Context.HasNonAsciiActiveHostname` 与 `Context.PendingHostnameReboot` 只读检测，可在不泄露计算机名原文的前提下直接识别此问题。

---

## 3. 两种解决方案对比

### 方案 A（推荐优先排查）：确认是否为 `this_host` 主机名解析问题

如果服务允许通过本机回环地址配置（视具体许可文件与软件许可条款而定）：

- 区分 **计算机名（Hostname）** 与 **Windows 登录用户名**：
  - 很多人误以为“用户文件夹带中文”导致报错，实际上 **`lmgrd` 解析的是 `hostname` 命令返回的计算机名**，与 `C:\Users\<用户名>` 无关。切勿盲目修改 Windows 用户配置目录名。
- 若确需按特定软件支持的方式调整 `SERVER` 行，修改任何 `.lic` 前务必先做副本备份，并以**二进制字节方式**处理（防止文本模式自动转码破坏文件内的非 UTF-8 字符）。

### 方案 B（根治方案）：将 Windows 计算机名改为纯英文 / ASCII 并重启

#### ⚠️ 最常见的误区：“我已经把电脑名改成英文了，为什么还是报错？”

Windows 用**两套不同的注册表值**分别保存“当前正在生效的计算机名”和“下次重启才生效的新计算机名”：

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' | Select-Object ComputerName
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' | Select-Object ComputerName
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' | Select-Object Hostname, 'NV Hostname'
```

| 注册表键 | 含义 |
|---|---|
| `ActiveComputerName\ComputerName` | **当前生效名**（`lmgrd` 实际读取的是这个） |
| `ComputerName\ComputerName` | **待重启生效名**（刚改完名时写在这里） |
| `Tcpip\Parameters\Hostname` / `NV Hostname` | 同上，对应当前与下次启动 |

只要两边不一致，就说明**改名后尚未重启**，服务依然会失败。

#### 改名前的副作用评估（必做）

修改计算机名前，先只读排查本机其他工程软件是否绑定了机器名：

```powershell
Get-CimInstance Win32_Service |
  Where-Object { $_.Name -match 'FLEX|lmgrd|COMSOL|Sentinel|HASP|Adsk' } |
  Select-Object Name, State, StartMode, PathName
```

- 检查其他软件的许可配置是否包含 `SERVER <主机名>` 或依赖机器名授权。
- 评估局域网 `\\旧计算机名\共享` 路径或依赖机器名的本地服务是否受影响。

---

## 4. 服务恢复后的四项验证标准

排查或修复完成后，以下 4 项同时满足才算服务真正就绪：

1. 服务状态 `State = Running`（不会在 3–5 秒内自动停止）。
2. `Get-NetTCPConnection -LocalPort <许可端口>` 显示处于 `Listen` 状态。
3. 对应的许可守护进程持续存活。
4. 许可日志尾部不再出现 `Unknown Hostname` 或 `daemon shutdown requested`。
