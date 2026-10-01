# 环境锚点开发约定

- 面向 Windows 10 的单文件客户端。`Client.cs` 内置 PowerShell 引擎，`Ui.cs` 负责绘制，`Core.ps1` 管理数据，`EnvAnchor.ps1` 管理界面。
- 构建：`python build.py`。构建机需 Windows 自带 .NET Framework、PowerShell 5.1，以及 Python/Pillow；最终 EXE 无需 Python。
- 构建脚本对最终 ZIP 解压后的 EXE 运行 `--self-test` 和 `--smoke-test`。前者仅操作临时合成目录，后者仅操作界面测试数据。
- 涉及数据迁移时保留旧副本，维护中断恢复状态；不在真实桌面、配置或启动项上做自动测试。
- 保留发布历史；公开包只含 EXE 和说明，不上传用户方案、订阅、个人路径或测试夹具数据。
- 截图使用 Demo 用户和示意路径，不能把真实用户目录放入公开项目页。
- 发布后回下载资产并核对大小、SHA-256、ZIP CRC 和单根目录，再更新下载说明。

## 当前界面迭代

- 本地预览版本为 `0.8.0-preview.1`，基于上游 `38fc611`。未经用户明确要求不提交、推送或发布。
- `EnvAnchor.ps1` 的 `Layout-Workspace` 管理窗口布局；`Ui.cs` 提供 `DashboardForm`、`RoundedButton` 与 `AnchorListView`，保持 .NET Framework 编译兼容性。
- 页面使用嵌套容器，`Set-Busy` 必须递归冻结操作控件；只读详情可查看，任务期间禁止重复执行或关闭。
- 构建前先执行隔离核心测试或烟测；`python build.py` 会再对最终 ZIP 中的单文件客户端进行核心与界面验证，并生成当前预览图。
- 源码烟测：`powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File EnvAnchor.ps1 -SmokeTest`；记录见 `docs/UI-REDESIGN.md`。
- `Preflight.ps1` 提供只读操作预览，`Environment.ps1` 提供引用扫描/有限修复与跨身份恢复清单。`Worker.cs` 使用明确命令白名单在后台运行。
- 分层自测命令：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Core.Tests.ps1`，同样运行 `tests\Preflight.Tests.ps1`、`tests\Environment.Tests.ps1`。界面集成测试在 `tests\Ui.Tests.ps1`，通过上面的 SmokeTest 入口执行。
- PowerShell 5.1 注意数组展开和 UTF-8/ANSI 区别。新增测试须同时兼容源码与无 PSScriptRoot 的嵌入引擎执行。
- 跨身份恢复必须显式映射并建立新方案，保留旧状态。恢复清单只含数量/大小摘要，不得称为内容哈希或完整备份。
