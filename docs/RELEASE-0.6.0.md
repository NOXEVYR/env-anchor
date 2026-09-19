# 0.6.0 发布记录

- 发布日期：2026-09-19。
- 源码提交：[`7657cc71fa8669f9bf13d660887b17ff778bb81c`](https://github.com/turnsolesama/env-anchor/commit/7657cc71fa8669f9bf13d660887b17ff778bb81c)。Git 传输暂时不可用时使用 GitHub Git Data API 发布同一源码树，没有覆盖其他提交。
- 版本：[v0.6.0](https://github.com/turnsolesama/env-anchor/releases/tag/v0.6.0)。
- 上传的是本机构建并验证的同一份 EXE 和 ZIP，没有使用不同的 CI 构建产物替换。

| 资产 | 大小（字节） | SHA-256 |
| --- | ---: | --- |
| EnvAnchor-0.6.0-win10-portable.zip | 141952 | `7544d0c3bc4ff13ca6ab70fe32b16aef1ddecc0b9a7732a89ef8751dc555eb6f` |
| EnvAnchor-0.6.0.exe | 133632 | `630027ea11c05e86abe4eb4c31e4770e309927321da92b9514e8f347a617cd3d` |

最终包中的 EXE 通过 49 项合成数据测试，以及后台工作线程、界面消息循环、方案切换、隔离启动快捷方式和无控制台检查。详见 [测试记录](TESTING-0.6.0.md) 与 [构建指纹](../releases/verification-0.6.0.json)。

没有修改真实用户文件、代理配置或系统启动目录。真实还原软件关机周期、跨物理磁盘、大规模长时间压力测试、多显示器高 DPI 和实际 Clash/TUN 集成未验证。

GitHub 的 ZIP、单文件 EXE 和校验 JSON 均已完整回下载，与本地资产逐字节一致；ZIP CRC、唯一根目录及重复条目检查通过。[远端校验结果](remote-verification-0.6.0.json)。
