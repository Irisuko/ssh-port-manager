# SSH 端口助手

Windows 10/11 本地小工具：管理 SSH 主机及其 Coder 对应关系，启动工作区，在服务器 Terminal 中执行 `chmod g-w /root`，同步外部 SSH 端口，并清除相应的旧主机密钥记录。

## 运行软件

从 [最新发布下载 SSH-Port-Manager.exe](https://github.com/Irisuko/ssh-port-manager/releases/latest/download/SSH-Port-Manager.exe)，双击即可使用。[查看版本说明及校验文件](https://github.com/Irisuko/ssh-port-manager/releases/latest)。发布版是单个 EXE，可单独放到桌面，无需附带源码目录；使用 Windows 的 .NET Framework、Windows PowerShell 5.1 和 OpenSSH 客户端。

运行时文件会按版本内容释放到 `%LOCALAPPDATA%\SshPortManager\Runtime`。登录信息和对应关系仍保存在 `%LOCALAPPDATA%\SshPortManager`，更新 EXE 不会覆盖这些设置。发布文件不包含账号密码、SSH 配置或本机备份。

当前应用针对 `36.140.239.91` 和 `https://coder.sage.org.ai:9450`。使用其他部署前需要调整对应源码常量。软件不附带预设账号；首次在新电脑使用时，请在登录设置中填写自己的 Coder 账号。

窗口读取当前用户的 `%USERPROFILE%\.ssh\config`，列出 `HostName 36.140.239.91` 的主机及当前端口。支持以下两种操作。

## 自动启动并同步

在“自动启动并同步”区域选择主机：

| 本机 SSH 别名 | Coder 工作区 |
| --- | --- |
| `PyramidKV-plugin` | `PyramidKV` |
| `MuxWise-plugin` | `Irisuko` |

点击 **启动并同步端口**，程序登录 `https://coder.sage.org.ai:9450`，启动所选工作区并等待启动完成。如果它已经运行，直接读取端口，不重启。程序保留工作区原来的模板和参数，不自动升级模板。随后从网站的 SSH 元数据读取端口，在该工作区的 Terminal 通道执行 `chmod g-w /root`，验证命令成功且 `/root` 已无组写权限，再请求管理员授权、备份并更新该主机的 config 端口，最后清除相应 known_hosts 记录。

上表是首次运行的默认对应关系，可以通过下面的管理功能修改。

## 管理本机主机与对应关系

点击 **管理主机与映射**，管理 `HostName 36.140.239.91` 下的本机 SSH 配置：

- **新增**：填写 SSH 别名、登录用户、端口，可选填写对应的 Coder 工作区名称。
- **编辑/保存**：修改选中主机的别名、用户、端口或 Coder 对应关系。工作区名称留空表示取消绑定，主机仍可手动更新端口。
- **删除**：确认后删除所选本机 Host 配置块及对应绑定；原配置会先备份。

这些操作不创建、重命名或删除 Coder 网站上的真实工作区，也不停止服务器。Coder 名称应填写当前账号已有工作区的准确名称。没有绑定的 SSH 主机仅显示在手动区域；有绑定的主机会出现在自动启动列表。

配置保存保留其他 SSH 条目及选中主机的无关选项（例如 RemoteForward）。多别名、通配符等复杂 Host 块在管理窗口中只读。对应关系保存在 `%LOCALAPPDATA%\SshPortManager\mappings.json`，文件存在时以已保存内容为准，即使全部删除也不会恢复默认绑定。配置和对应关系分别保存；如果第二步失败，结果会说明本地配置已保存并提供备份路径。

自动模式只提交选中的一个主机，其他手动输入框不会一起提交。如果远端已启动并完成权限设置，但取消了本地管理员授权，服务器会保持运行，远端权限设置会保留，获取的端口会留在输入框中。启动失败、端口不唯一、Terminal 命令失败或配置发生外部修改时，不会自动写入 SSH 配置。启动阶段和 Terminal 准备阶段各最多等待 10 分钟；失败或超时请查看结果及网站状态。命令提交前的超时会明确报告未执行；提交后无法确认结果时不会自动重复执行。

账号在“登录设置”中管理。密码使用 Windows 当前用户 DPAPI 加密保存在 `%LOCALAPPDATA%\SshPortManager\coder-credential.xml`；无法复制给其他 Windows 用户或电脑使用。源码、后台任务 JSON、命令行参数及应用日志不保存明文密码或 session token。只有网络阶段使用凭据，网络阶段不提权。

## 手动更新端口

1. 可以自行在网站启动服务器，再使用本区域更新。手动模式也需要在“登录设置”保存 Coder 凭据，用于在服务器 Terminal 执行命令。
2. 在需要修改的主机旁输入新端口，例如 `32091`。**留空的行完全跳过**。填写与当前相同的端口，会重新确认远端权限并清除该端口的旧密钥记录。
3. 点击 **确认手动更新**。程序按输入端口查找当前账号唯一匹配且已运行的 Coder 工作区，在其 Terminal 执行 `chmod g-w /root` 并验证结果。此步骤不会启动停止的服务器，也不要求预先配置 SSH → Coder 映射。
4. 所选主机的远端权限处理全部成功后，在 Windows 管理员授权提示中选择“是”。程序备份并写入 config，再执行 `ssh-keygen -R "[36.140.239.91]:32091"`，并通过 `-f` 指定原用户的 `known_hosts`，避免提权后清理了其他管理员用户的文件。
5. 查看下方执行结果。多主机处理遇到失败会停止，本地配置尚未提交；已经成功执行的远端命令会单独列出。端口匹配不唯一、Terminal 代理未就绪或命令结果无法确认时，不会将整次操作报告为成功。

备份与原文件位于同一目录，名称含时间戳。配置未变化时不重复写入 config；`known_hosts` 不存在时会报告无需清理。取消管理员授权不会修改任何本地 SSH 文件；之前完成的远端 `chmod` 会保留。如果配置被其他程序改动，程序会要求刷新，避免覆盖更新。

界面只读取主 config 中直接出现的 Host 块，不展开 Include 或 Match 条件。手动模式不更改服务器端口；输入的端口应是服务器已经开放的 SSH 端口。Terminal 使用 Coder 登录通道，无需先通过外部 SSH 验证。命令固定为 `chmod g-w /root`，不会递归修改目录或其他权限。出现部分失败时，结果区会说明哪些步骤已完成并显示备份路径。

## 开发验证

从源码构建单文件软件：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1
```

构建结果在 `dist\SshPortManager.exe`。构建只使用系统 .NET 编译器，不下载依赖。也可用 `Start.cmd` 在源码目录启动。

在此目录运行以下命令。测试只操作项目内的临时文件，使用真实 ssh-keygen 验证记录清除，不修改用户的 SSH 文件。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SshConfig.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Operations.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Coder.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CoderJob.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CoderWorker.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CoderTerminal.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PreparationJob.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PreparationWorker.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-AppFlows.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Mappings.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HostManagement.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-HostManagerUi.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

`App.ps1` / `App.xaml` 为界面；`SshConfig.psm1` 负责配置；`Operations.psm1` 负责更新及清除记录；`Apply-Changes.ps1` 为提权入口。

`Launcher.cs` 是无控制台窗口的 .NET 启动器，内嵌运行时文件并在进程内托管 Windows PowerShell。`Build.ps1` 生成单文件发布包，凭据、测试和开发笔记不会打包。

`Coder.psm1` 为 Coder API 接口和启动状态处理，`CredentialStore.psm1` 负责本机加密凭据，`CoderJob.psm1` / `Start-Coder.ps1` 为普通用户后台任务。`Check-Coder.ps1` 提供只读网络诊断：只读取已运行的工作区端口，遇到停止的工作区会报错，绝不启动。停止→启动流程使用模拟 API 测试；真实网站验证只读取已经运行的工作区，不为测试停机或重启。

`Mappings.psm1` 管理本机绑定；`HostManagement.psm1` 协调配置和绑定保存；`HostManager.ps1` / `HostManager.xaml` 为管理窗口。开发测试使用隔离的配置和映射副本，不修改真实主机。

`CoderTerminal.psm1` 通过 Coder Terminal 执行并验证固定权限命令；`PreparationJob.psm1` / `Start-Prepare.ps1` 为两种模式共用的普通用户准备阶段。Terminal 返回明确的完成标记、退出码和权限模式后，才允许进入本地提权阶段。凭据及会话令牌不会进入命令行或任务 JSON。
