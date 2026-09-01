# FFPA — Tech & Res Auto PM Adapter

为 Tech & Res 与两个通用 Auto-Apply Mod 提供完整的双向生产方式适配。该 Mod 已从旧版 `2050 Firefall — Personal Preferences Adapter`（现 `FFPA — Firefall Flavor Pack`）独立迁出，不依赖风味合集、Firefall、Core Balance 或 Building Pruning。

## 必要前置与加载顺序

- `[1.13] Tech & Res`，Workshop ID `3472248460`；
- `Auto-Apply PMs`，Workshop ID `3353797125`；
- `Auto-Apply Automation PMs`，Workshop ID `3344726320`。

两个 Auto-Apply Mod 是彼此及 Tech & Res 均独立的通用 Mod；只有本适配器同时消费三者。由于它们当前的 metadata ID 为空，Launcher 无法建立可靠的硬依赖，因此必须由玩家手动启用。

推荐加载顺序：

```text
Tech & Res
→ Auto-Apply PMs
→ Auto-Apply Automation PMs
→ FFPA Tech & Res Auto PM Adapter
```

关键约束是本适配器最后加载。

## 功能

- 补齐 Tech & Res 新建筑、普通生产方式、自动化、运输和数据优化。
- 普通生产可以在相邻生产方式之间双向试用；自动化、运输和数据优化只会向上升级，绝不主动降低现有方式。
- 完整管理炸药厂“勒布朗法 → 氨碱法 → 真空蒸发 → 盐水电解”生产链。
- 候选条件连续满足 2 个月后才试切换；普通生产观察 3 个月，自动化观察 6 个月。
- 普通生产切换前记录约 2% 粒度的收益档位，并在试运行后检查收益、周利润和补贴状态。
- 普通生产连续两次验收通过后保留；连续两次失败后回滚并冷却 9 个月；成功冷却 6 个月。
- 普通生产的新投入品价格达到 +60% 时紧急回滚；自动化和运输的向上候选在观察结束后无条件保留并进入成功冷却。
- 普通生产在 24 个月内第二次方向反转会触发 18 个月震荡锁；外部或玩家手动切换提供 12 个月保护。
- 状态保存在州作用域，按建筑与 PMG 隔离；同一建筑的普通生产与自动化共享互斥锁。

## 玩家控制

玩家会自动获得“Tech & Res 自动生产适配”日志。原有 11 个类别按钮继续作为矿产、农业与水资源、化工、新机械、电子、数字产业、物流、能源、交通、文化和研究设施的普通生产管理主开关；每个主开关下另有对应的逐建筑按钮，共精确控制 34 种存在普通生产升级链的 Tech & Res 新建筑。逐建筑选择默认全部开启，因此旧存档不需要迁移；关闭某个建筑按钮只排除该建筑，不影响同类其他建筑。聚变电厂当前没有受管的普通生产升级链，仍只受上游自动化设置控制，因而不会显示一个无效的逐建筑按钮。

逐建筑按钮只控制普通生产方式。两个上游 Auto-Apply 日志仍需启用；它们继续拥有通用建筑开关、自动化与运输开关、频率、单次调整数量和未覆盖建筑。本适配器只接管已经完整覆盖的实例，并读取上游 `zw_var_auto_pm_*` 设置。

低频普通生产继续使用上游的半年频率和错开月份；自动化、运输可按上游设置每月或每年两次扫描，但扫描只会寻找向上候选。候选与试运行始终每月推进；收益验收、紧急回滚、失败回滚和主动降级仅适用于普通生产。旧存档中尚未结束的自动化/运输降级候选会被清理，已切换的当前方式保持不变。

## 诊断

在 Victoria 3 用户日志目录中搜索 `FFPA_PM|`。主要阶段包括：

- `ADAPTER_MONTHLY`：适配 JE 月度脉冲；
- `UPSTREAM_*_SCAN`：上游管理器进入适配层；
- `PRODUCTION_GUARD`、`AUTOMATION_GUARD`、`TRANSPORT_GUARD`：旧管理器委托实例；
- `UP_CANDIDATE`、`TRIAL_START`：自动化/运输向上候选，以及普通生产候选和试运行；`DOWN_CANDIDATE` 只可能来自普通生产；
- `EVAL_PASS`、`EVAL_FAIL`、`KEEP`、`ROLLBACK`：普通生产的验收与结果；
- `KEEP_NO_ROLLBACK`：自动化或运输观察结束后无条件保留；
- `RETIRED_AUTOMATION_DOWN_CANCEL`：旧存档中的自动化/运输降级工作流已清理，当前方式不变；
- `EXTERNAL_CANCEL`、`COUNTER_REPAIR`、`OSCILLATION_LOCK`：异常修复和保护。

完整机械覆盖结果见 `TECHRES_AUTO_PM_COVERAGE.md`。报告中的两个孤立自动化组是有意排除项。

## 生成器

不要直接编辑三个 `ffpa_generated_*` 文件或覆盖报告。使用参数调用：

```powershell
$GameRoot = '<Victoria 3>/game'
$WorkshopRoot = '<Steam>/steamapps/workshop/content/529340'
./tools/generate_ffpa_auto_pm_compat.ps1 `
  -GameRoot $GameRoot `
  -WorkshopRoot $WorkshopRoot `
  -OutputRoot (Get-Location).Path
```

生成器必须连续运行两次并产生相同哈希。当前拆分只机械搬移生成器与产物，不改变生成逻辑或持久 ID。
# ffpa-techres-auto-pm-adapter
