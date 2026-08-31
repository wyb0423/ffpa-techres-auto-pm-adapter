# FFPA Tech & Res Auto PM Adapter — Agent 开发指南

## 1. 范围与身份

本文件适用于本 Mod 根目录及全部子目录。

- Mod ID：`com.wyb.ffpa-techres-auto-pm-adapter`
- Victoria 3：`1.13.*`
- metadata 硬依赖：`tech.res`
- 必要运行前置：Auto-Apply PMs `3353797125`、Auto-Apply Automation PMs `3344726320`
- 生成器输入：原版、Tech & Res `3472248460` 和上述两个 Workshop Mod

两个 Auto-Apply Mod 的当前 metadata ID 为空，因此不能写入可靠的 Launcher dependency。README 和交付说明必须明确它们仍是必要前置。

本 Mod 不依赖 Personal Adapter、Firefall、Core Balance 或 Building Pruning，也不得调用这些 Mod 的私有接口。

## 2. 开工前检查

1. 运行 `git status --short --branch`，保留用户已有修改。
2. 用 `rg --files -uu -g '!/.git/**'` 盘点运行时、生成器、报告和本地化。
3. 确认游戏根目录、Workshop 根目录、三个上游 Mod 的安装版本和真实加载顺序。
4. 对要改的 building、PMG、PM、goods、effect 和 trigger，检查原版、Tech & Res 与两个 Auto-Apply Mod 的最终定义。
5. 路径是环境输入，不得把机器绝对路径写入生成器或报告。

## 3. 文件所有权

手写控制面：

- `common/decisions/ffpa_auto_pm_decisions.txt`
- `common/journal_entries/ffpa_auto_pm_compat_je.txt`
- `common/scripted_buttons/ffpa_auto_pm_buttons.txt`
- `common/script_values/ffpa_auto_pm_values.txt`
- `common/scripted_effects/ffpa_auto_pm_settings_effects.txt`
- `common/scripted_effects/ffpa_auto_pm_journal_effects.txt`
- `common/on_actions/ffpa_on_actions.txt`
- 两份本地化文件

生成接口：

- 唯一源：`tools/generate_ffpa_auto_pm_compat.ps1`
- 生成：`common/scripted_effects/ffpa_generated_auto_pm_effects.txt`
- 生成：`common/scripted_effects/ffpa_generated_auto_pm_trials.txt`
- 生成：`common/scripted_triggers/ffpa_generated_auto_pm_triggers.txt`
- 报告：`TECHRES_AUTO_PM_COVERAGE.md`

禁止直接编辑三个生成脚本和覆盖报告。分类、阈值模板、guard 或状态机发生变化时必须运行生成器。

## 4. 上游接口与管理权

- 读取 `zw_var_auto_pm_*` 类别、频率和数量变量；这些键属于上游，不得改名或写入不同含义。
- 生成文件当前替换 38 个 Auto-Apply PMs 建筑管理器，以及自动化和运输两个州级管理器。
- 已完整覆盖的实例委托给本适配器；未覆盖实例必须继续由上游管理。
- 普通生产、自动化和运输分类以“上游实际引用 + 最终建筑挂载”为准，不能按名称猜测。
- Tech & Res 与上游版本更新后，逐一核对 40 个 `REPLACE:` 目标及其原始逻辑。

## 5. 存档接口

以下均为持久或跨包 API，不得因重构重新编号或改变含义：

- JE、决议、11 个按钮和类别变量；
- 阈值 script values；
- `ffpa_ap_b*` building/PMG 隔离变量；
- pending、trial、收益基线、连续验收计数器、cooldown、manual lock 和 oscillation lock；
- 生成 transition ID、debug 标记和上游 replacement key。

新游戏初始化、旧存档补发和月度状态推进必须分别验证。ensure effect 必须幂等，不得重置玩家设置或运行中的 trial。

## 6. 生成器约束

推荐调用：

```powershell
$GameRoot = '<Victoria 3>/game'
$WorkshopRoot = '<Steam>/steamapps/workshop/content/529340'
./tools/generate_ffpa_auto_pm_compat.ps1 `
  -GameRoot $GameRoot `
  -WorkshopRoot $WorkshopRoot `
  -OutputRoot (Get-Location).Path
```

- 生成器、三个运行时文件和覆盖报告必须同次提交。
- 连续运行两次必须得到相同 SHA-256。
- 不得静默纳入报告中记录的两个孤立 PMG。
- 排序重构不得改变生成 ID。
- 不把游戏、Workshop、日志或存档绝对路径提交到 Mod。

## 7. 本地化与格式

- 英文与简体中文键集合必须一致。
- 保留 UTF-8 BOM、语言头、换行符和原技术 ID。
- 玩家可见阈值必须与脚本一致，不得手工猜测覆盖数量。

## 8. 验证

最低静态验证：

- metadata 可解析且只声明 `tech.res`；
- 脚本花括号、字符串、注释和顶层结构正常；
- 没有意外重复顶层键；
- 所有新增引用在最终加载栈中存在；
- 40 个 replacement 目标仍存在；
- 两种语言键集合一致并保留 BOM；
- `git diff --check` 无新增空白错误。

自动 PM 变更还必须：

1. 连续运行生成器两次并比较四个结果哈希；
2. 确认报告继续覆盖全部 automation building/PM 对和炸药厂完整双向链；
3. 检查每条升级边都有降级边，设置 gate 正确，未覆盖实例仍归上游；
4. 游戏内从 `FFPA_PM|` 区分调度、候选、试运行、验收、保留、回滚和外部取消。

无法运行 PowerShell或游戏时，必须分别列出静态确认、生成器断言、日志证据和仍待验证项目，不得把定义存在描述成运行时生效。

## 9. Git 与交付

未经明确要求，不执行 add、commit、reset、checkout、clean、rebase 或 force push。交付时报告修改文件、上游覆盖、存档接口、静态/生成器/运行时验证和工作树状态。
