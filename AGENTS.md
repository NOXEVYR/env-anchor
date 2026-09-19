# 环境锚点开发约定

- 面向 Windows 10 的单文件客户端。`Client.cs` 内置 PowerShell 引擎，`Ui.cs` 负责绘制，`Core.ps1` 管理数据，`EnvAnchor.ps1` 管理界面。
- 构建：`python build.py`。构建机需 Windows 自带 .NET Framework、PowerShell 5.1，以及 Python/Pillow；最终 EXE 无需 Python。
- 构建脚本对最终 ZIP 解压后的 EXE 运行 `--self-test` 和 `--smoke-test`。前者仅操作临时合成目录，后者仅操作界面测试数据。
- 涉及数据迁移时保留旧副本，维护中断恢复状态；不在真实桌面、配置或启动项上做自动测试。
- 保留发布历史；公开包只含 EXE 和说明，不上传用户方案、订阅、个人路径或测试夹具数据。
- 截图使用 Demo 用户和示意路径，不能把真实用户目录放入公开项目页。
- 发布后回下载资产并核对大小、SHA-256、ZIP CRC 和单根目录，再更新下载说明。
