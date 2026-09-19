# 0.6.0 验证记录

最终便携包解压后的 EXE 执行了以下 49 项合成数据检查，全部通过。

- migration creates correct junction
- original retained
- empty directories copied
- changes persist in target
- reset baseline cannot overwrite persistent data
- resume is idempotent
- undo restores ordinary directory
- undo copies current preferences back
- undo retains persistent copy
- nested reparse points rejected
- unrelated junction rejected
- interrupted copy cannot be linked
- interrupted undo can finish safely
- explicit destination is used exactly
- custom destination saved in plan
- custom destination survives simulated reset
- nonempty custom destination rejected
- source and destination overlap rejected
- overlapping project destinations rejected
- missing custom target blocks resume
- missing custom target blocks undo before unlink
- junction retained when target unavailable
- custom destination undo restores content
- batch relocation uses common root
- batch entries keep independent destinations
- relocated desktop content intact
- relocated app content intact
- old destinations retained
- new destination committed to original plan
- same-name entries receive distinct subfolders
- resume completes interrupted link switch
- resume commits already switched junction
- undo after relocation restores latest files
- dispatcher creates multi-entry plan
- selective undo leaves other entry linked
- restored entry can migrate again without disturbing others
- operation log records results
- parallel operation on same plan is blocked
- plan lock released after conflict
- same-target apply repairs reset connection
- copy refuses linked destination without writing through it
- incomplete copy is never restored as complete data
- stale relocation copy cannot replace newer source data
- successive relocations retain all previous target records
- invalid later batch item prevents earlier file changes
- failed batch validation leaves no misleading plan
- locked file fails without changing live connection
- undo can safely abandon stale pending relocation
- abandoned relocation copy is retained for inspection

## 客户端检查

- 无控制台启动与复制。
- 全选、取消全选和批量默认位置预览。
- 后台任务与 Windows 消息循环同时运行。
- 重复打开方案不增加重复行，切换方案不残留旧项目。
- 独立临时目录中创建并删除启动快捷方式，核对目标 EXE 和参数；未修改真实启动目录。
- 控件可见性、边界和脱敏界面渲染。

## 未覆盖

真实还原软件的关机周期、跨物理磁盘、大规模长时间压力测试、多显示器高 DPI、实际 Clash/TUN 集成尚未验证。
