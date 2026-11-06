# SSH 端口助手

Windows 10/11 本地小工具：管理 SSH 主机及其 Coder 对应关系，启动工作区，在服务器 Terminal 中执行 `chmod g-w /root`，同步外部 SSH 端口、更新主机密钥，并通过 VS Code Remote SSH 连接。

## 运行软件

从 [最新发布下载 SSH-Port-Manager.exe](https://github.com/Irisuko/ssh-port-manager/releases/latest/download/SSH-Port-Manager.exe)，双击即可使用。[查看版本说明及校验文件](https://github.com/Irisuko/ssh-port-manager/releases/latest)。发布版是单个 EXE，可单独放到桌面，无需附带源码目录；使用 Windows 的 .NET Framework、Windows PowerShell 5.1 和 OpenSSH 客户端。

运行时文件会按版本内容释放到 `%LOCALAPPDATA%\SshPortManager\Runtime`。登录信息和对应关系仍保存在 `%LOCALAPPDATA%\SshPortManager`，更新 EXE 不会覆盖这些设置。发布文件不包含账号密码、SSH 配置或本机备份。

当前应用针对 `36.140.239.91` 和 `https://coder.sage.org.ai:9450`。使用其他部署前需要调整对应源码常量。软件不附带预设账号；首次在新电脑使用时，请在登录设置中填写自己的 Coder 账号。

窗口读取当前用户的 `%USERPROFILE%\.ssh\config`，列出 `HostName 36.140.239.91` 的主机及当前端口。支持自动同步、手动更新，以及检查并连接。

## 自动启动并同步

在“自动启动并同步”区域选择主机：

| 本机 SSH 别名 | Coder 工作区 |
| --- | --- |
| `PyramidKV-plugin` | `PyramidKV` |
| `MuxWise-plugin` | `Irisuko` |

点击 **启动并同步端口**，程序登录 `https://coder.sage.org.ai:9450`，启动所选工作区。如果它已经运行，直接读取端口，不重启。程序保留工作区原来的模板和参数，不自动升级模板。启动和 Terminal 就绪共用最多 **3 分钟**等待时间。

就绪后，程序在工作区 Terminal 执行 `chmod g-w /root`，确认成功，并读取该服务器的 SSH 主机公钥。随后请求管理员授权，备份并更新本机 config 端口，清除该端口的旧 known_hosts 记录，再添加已验证的新公钥。

如果 3 分钟后仍在等待资源或 Terminal 尚未就绪，只要能够确认当前构建已分配的 SSH 端口，仍可先更新端口和清理旧密钥；权限设置和新密钥添加会明确显示为待处理。以后使用 **检查并连接** 完成剩余步骤。如果尚未分配端口，或不能确认它属于当前构建，则不会使用旧端口修改本机配置。

上表是首次运行的默认对应关系，可以通过下面的管理功能修改。

## 管理本机主机与对应关系

点击 **管理主机与映射**，管理 `HostName 36.140.239.91` 下的本机 SSH 配置：

- **新增**：填写 SSH 别名、登录用户、端口，可选填写对应的 Coder 工作区名称。
- **编辑/保存**：修改选中主机的别名、用户、端口或 Coder 对应关系。工作区名称留空表示取消绑定，主机仍可手动更新端口。
- **删除**：确认后删除所选本机 Host 配置块及对应绑定；原配置会先备份。

这些操作不创建、重命名或删除 Coder 网站上的真实工作区，也不停止服务器。Coder 名称应填写当前账号已有工作区的准确名称。所有可编辑的 SSH 主机均可手动更新或检查并连接；有绑定的主机会出现在自动启动列表。

配置保存保留其他 SSH 条目及选中主机的无关选项（例如 RemoteForward）。多别名、通配符等复杂 Host 块在管理窗口中只读。对应关系保存在 `%LOCALAPPDATA%\SshPortManager\mappings.json`，文件存在时以已保存内容为准，即使全部删除也不会恢复默认绑定。配置和对应关系分别保存；如果第二步失败，结果会说明本地配置已保存并提供备份路径。

自动模式只提交选中的一个主机，其他手动输入框不会一起提交。如果远端已启动并完成权限设置，但取消了本地管理员授权，服务器会保持运行，远端权限设置会保留，获取的端口会留在输入框中。启动失败、端口不唯一、Terminal 命令失败或配置发生外部修改时，不会自动写入 SSH 配置。只有明确确认命令尚未提交、服务器仍未就绪时才允许延期处理；登录或网络错误、命令失败、提交后结果无法确认，都不会被当作普通等待而继续本地更新。

账号在“登录设置”中管理。密码使用 Windows 当前用户 DPAPI 加密保存在 `%LOCALAPPDATA%\SshPortManager\coder-credential.xml`；无法复制给其他 Windows 用户或电脑使用。源码、后台任务 JSON、命令行参数及应用日志不保存明文密码或 session token。只有网络阶段使用凭据，网络阶段不提权。

## 手动更新端口

1. 可以自行在网站启动服务器，再使用本区域更新。手动模式也需要在“登录设置”保存 Coder 凭据，用于在服务器 Terminal 执行命令。
2. 在需要修改的主机旁输入新端口，例如 `32091`。**留空的行完全跳过**。填写与当前相同的端口，会重新确认远端权限并更新该端口的主机密钥。
3. 点击 **确认手动更新**。程序按输入端口查找当前账号唯一匹配的 Coder 工作区，在其 Terminal 执行 `chmod g-w /root`、验证结果并读取主机公钥。此步骤不会启动停止的服务器，也不要求预先配置 SSH → Coder 映射。多个主机共用最多 3 分钟就绪等待；明确未就绪的主机可延期处理权限和新密钥。
4. 在 Windows 管理员授权提示中选择“是”。程序备份并写入 config，再执行 `ssh-keygen -R "[36.140.239.91]:32091"`，并通过 `-f` 指定原用户的 `known_hosts`，然后写入已取得的新主机公钥。未就绪的主机只更新端口和清理旧记录，标记新密钥待添加。
5. 查看下方执行结果。多主机处理遇到失败会停止，本地配置尚未提交；已经成功执行的远端命令会单独列出。端口匹配不唯一或命令结果无法确认时，不会继续本地更新；延期处理会单独提示，不能视为已完成全部步骤。

备份与原文件位于同一目录，名称含时间戳。配置未变化时不重复写入 config；`known_hosts` 不存在时会报告无需清理。取消管理员授权不会修改任何本地 SSH 文件；之前完成的远端 `chmod` 会保留。如果配置被其他程序改动，程序会要求刷新，避免覆盖更新。

界面只读取主 config 中直接出现的 Host 块，不展开 Include 或 Match 条件。手动模式不更改服务器端口；输入的端口应是服务器已经开放的 SSH 端口。Terminal 使用 Coder 登录通道，无需先通过外部 SSH 验证。命令固定为 `chmod g-w /root`，不会递归修改目录或其他权限。出现部分失败时，结果区会说明哪些步骤已完成并显示备份路径。

## 检查并连接 VS Code

在 **检查并连接** 区域选择 SSH 主机并点击按钮。程序只检查，不会启动已停止的工作区。有对应关系时从 Coder 刷新当前端口；没有对应关系时按本机配置端口定位工作区。

如果工作区或 Terminal 尚未就绪，直接提示稍后重试，不修改本地文件，也不打开 VS Code。就绪后依次执行 `chmod g-w /root`、取得新主机公钥、更新本机端口、清理旧密钥和添加新密钥，全部确认成功后，以普通用户启动 VS Code，连接所选 SSH 别名的 `/root` 目录。自动同步和手动更新不会自动打开 VS Code。

电脑需已安装 VS Code 和 Remote - SSH 扩展，SSH 用户及登录凭据仍使用本机配置。软件报告“已打开 VS Code”表示已发起连接；最终登录结果以 VS Code 为准。

添加的是服务器 **SSH 主机公钥**，不会创建或更改用户登录密钥。公钥通过已认证的 Coder Terminal 读取并校验格式后，按 `[36.140.239.91]:端口` 写入原用户的 `known_hosts`；默认端口 22 使用 OpenSSH 的不带端口主机记录。不读取服务器私钥，也不使用未经认证的网络扫描结果。

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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HostKeys.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-VsCode.ps1
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

`App.ps1` / `App.xaml` 为界面；`SshConfig.psm1` 负责配置；`Operations.psm1` 负责更新配置、清除旧记录及写入已验证的新公钥；`HostKeys.psm1` 校验主机公钥；`Apply-Changes.ps1` 为提权入口；`VsCode.psm1` 负责普通用户 VS Code 连接启动。

`Launcher.cs` 是无控制台窗口的 .NET 启动器，内嵌运行时文件并在进程内托管 Windows PowerShell。`Build.ps1` 生成单文件发布包，凭据、测试和开发笔记不会打包。

`Coder.psm1` 为 Coder API 接口和启动状态处理，`CredentialStore.psm1` 负责本机加密凭据，`CoderJob.psm1` / `Start-Coder.ps1` 为普通用户后台任务。`Check-Coder.ps1` 提供只读网络诊断：只读取已运行的工作区端口，遇到停止的工作区会报错，绝不启动。停止→启动流程使用模拟 API 测试；真实网站验证只读取已经运行的工作区，不为测试停机或重启。

`Mappings.psm1` 管理本机绑定；`HostManagement.psm1` 协调配置和绑定保存；`HostManager.ps1` / `HostManager.xaml` 为管理窗口。开发测试使用隔离的配置和映射副本，不修改真实主机。

`CoderTerminal.psm1` 通过 Coder Terminal 执行并验证固定权限命令和主机公钥；`PreparationJob.psm1` / `Start-Prepare.ps1` 为三种操作共用的普通用户准备阶段。结果区分已准备、可延期、未就绪和失败；只有已准备或同步模式下明确可延期的结果允许进入本地提权阶段。凭据及会话令牌不会进入命令行或任务 JSON。
