# EchoThink Godot 编辑器插件生产级设计方案

> 文档性质：生产级架构设计（非 MVP）  
> 适用范围：Godot 4.x 编辑器插件、本地受控执行层、EchoThink 云侧集成层  
> 目标：将 Godot 编辑器变成 EchoThink/ClawCluster 的本地执行桥，而不是一个仅能对话的面板

## 1. 背景与设计输入

当前 EchoThink 已具备两层核心基础：

1. **基础设施层**：Outline、GitLab、MinIO、Supabase/Postgres、Hatchet、Graphiti、Langfuse、Dify、n8n、LiteLLM 等已构成系统底座。
2. **Agent/执行层**：ClawCluster 采用 HiClaw/OpenClaw 模式，已经明确了 Manager/Worker、Bridge、Policy、Publisher、Observability 等角色分工。

基于现有设计，Godot 插件必须遵守以下权责边界：

- **Outline** 是长文档、规划、设计意图的系统事实源。
- **GitLab** 是代码、分支、MR、审核历史的系统事实源。
- **MinIO** 是资产包、任务工件、共享文件系统数据的事实源。
- **Supabase/Postgres** 是结构化任务、审批、执行状态的事实源。
- **ClawCluster** 负责规划、编码、QA、知识同步、执行编排。
- **Godot 插件** 不是新的系统事实源；它是**本地上下文采集、受控执行、实时反馈、人工审批入口**。

本设计同时参考了以下现有文档中的约束和能力：

- `../echothink-infra/docs/clawcluster-design.md`
- `../echothink-infra/docs/open-source-stack-architecture.md`
- `../echothink-infra/docs/outline-agent-workflows.md`
- `../echothink-clawcluster/docs/integrations/echothink-bridges.md`
- `../echothink-clawcluster/docs/workflows/coding-workflow.md`

## 2. 设计目标

本插件不是“Godot 里的聊天框”，而是一个**云-本地协同控制桥**。其生产级目标如下：

### 2.1 核心目标

1. **把设计与任务真正带进编辑器**  
   插件应把 Outline 中的设计文档、开发任务、验收标准、审批状态、Agent 执行状态直接带入 Godot 工作流。

2. **让 Agent 可以在受控前提下操作本地 Godot 项目**  
   包括读取场景、脚本、资源、导入设置、日志、测试结果，并以声明式操作形式修改项目。

3. **打通资产与代码两条生产链路**  
   资产从 MinIO/infra 进入 Godot，本地差异再以“快照/补丁/工件”方式回流；代码则围绕 GitLab 分支/MR 工作流闭环。

4. **保持人在回路中的审批与可回滚性**  
   插件必须支持预览、逐项应用、回滚、冲突提示、风险分级、审批门禁，而不能让云端任意执行本地命令。

5. **支持实时调试与迭代开发**  
   插件必须能将本地日志、测试结果、运行异常、资源导入错误实时反馈给云端 Agent，并将建议以补丁、计划、资产调度等形式返回。

### 2.2 非目标

1. 不把 MinIO 伪装成完整 Git 源码仓库；代码权威来源仍然是 GitLab。
2. 不允许云端直接拥有任意 Shell/OS 级远程执行权限。
3. 不绕过现有 ClawCluster 的 Bridge/Policy/Publisher 责任边界直接写系统事实源。
4. 不把 Godot 编辑器插件做成一个与项目无关的通用 AI 助手；它必须是**项目绑定、工作区绑定、任务绑定**的专业工具。

## 3. 设计原则

### 3.1 薄 UI、厚能力边界

Godot 内部的 `EditorPlugin` 负责 UI、上下文桥接、编辑器 API 调用与用户确认；耗时操作、网络同步、Git/对象存储交互、测试执行应落在**本地桥接进程**中，而不是全部塞在编辑器主线程里。

### 3.2 声明式操作优先于任意命令

插件对本地项目的改动应通过结构化操作完成，例如：

- `text_patch`
- `scene_op`
- `resource_op`
- `asset_import`
- `project_setting_set`
- `test_run`
- `outline_update_proposal`

而不是让云端下发任意字符串命令。

### 3.3 读写分离、事实源清晰

- 读取上下文可直接走插件网关或本地缓存。
- 外部写操作必须经过受控桥接层：
  - Outline 文档写入走 Publisher/Gateway。
  - GitLab 分支/MR 发布走 Publisher。
  - 审批走 Policy Bridge。
  - 执行记录、证据、工件回写走 Observability/Publisher。

### 3.4 默认可审计、默认可恢复

每个本地改动都要形成 `ChangeSet` 与审计日志，支持：

- 应用前预检
- 应用后验证
- 失败时自动回滚
- 重启后恢复中断状态
- 关联到 `work_item_id` / `task_run_id`

### 3.5 项目上下文最小暴露

插件上传云端的内容必须遵守最小必要原则：

- 默认上传摘要、哈希、结构化上下文；
- 需要全文时按文件、按选择、按场景范围上传；
- 遵守 `.echothinkignore` 与敏感文件屏蔽规则。

## 4. 产品定位与能力范围

插件最终提供六大类能力，而不仅是你当前分析出的三个大类。

### 4.1 设计/任务规划

- 从 Outline 设计文档、开发任务队列、GitLab issue、当前本地上下文中生成本地开发计划。
- 将计划拆分为可执行任务、依赖关系、验收标准、风险与成本估计。
- 支持开发者在编辑器内补充新洞见，并形成**Outline 文档更新提案**。

### 4.2 资产导入与资产同步

- 从 MinIO 拉取 agent 生成或运营侧维护的资产包。
- 在本地进行预检、下载、解包、导入、重导入与依赖修复。
- 提供基于快照的 `diff / pull / push` 能力，用于本地与 infra 之间同步资产状态。

### 4.3 代码生成、补丁应用与代码发布

- 为新功能生成原型代码、场景变更、资源配置变更。
- 为缺陷修复生成补丁并在本地预览、应用、验证。
- 将通过验证的变更发布为 GitLab branch / MR。

### 4.4 日志分析与调试协助

- 采集编辑器日志、导入错误、运行时日志、测试日志。
- 形成可上传的 `log bundle` 与 `repro bundle`。
- 让 Agent 基于日志与上下文生成故障定位建议和修复补丁。

### 4.5 测试策略触发与 QA 协同

- 定义项目级测试策略（如 GUT/WAT/自定义 headless 测试/场景烟雾测试）。
- 让 Agent 在补丁应用前后选择合适策略执行。
- 将结果写回任务证据链，供 QA Worker 与审批使用。

### 4.6 本地上下文桥接与知识回流

- 将当前编辑场景、选择节点、打开脚本、改动文件、运行平台等上下文打包给云端。
- 将稳定的修复经验、调试结论、场景约束回流到 Graphiti/Outline。

## 5. 总体架构

生产级方案建议拆成四个可部署部件，而不是一个单体插件：

```text
┌───────────────────────────────────────────────────────────────────┐
│                        EchoThink Cloud                           │
│                                                                   │
│  Outline   GitLab   MinIO   Supabase   Hatchet   Graphiti         │
│      \        |       |         |          |          /            │
│       \       |       |         |          |         /             │
│        └──────┴───────┴─────────┴──────────┴────────┘              │
│                          ClawCluster                               │
│      Intake / Policy / Publisher / Observability / Workers        │
│                                  │                                │
│                          Editor Gateway                            │
└──────────────────────────────────┼─────────────────────────────────┘
                                   │ HTTPS + WebSocket
┌──────────────────────────────────┼─────────────────────────────────┐
│                          Developer Machine                         │
│                                                                   │
│   Godot Editor                                                     │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │ EchoThink EditorPlugin                                      │   │
│   │ - Dock / Panel / Context Menu                              │   │
│   │ - EditorInterface Bridge                                   │   │
│   │ - Change Preview / Apply / Rollback                        │   │
│   └──────────────────────────┬──────────────────────────────────┘   │
│                              │ Local IPC (UDS / Named Pipe)         │
│   ┌──────────────────────────▼──────────────────────────────────┐   │
│   │ EchoThink Local Bridge                                      │   │
│   │ - Git / MinIO / Cache / Diff / Test / Log / Journal         │   │
│   │ - Policy-enforced local executor                            │   │
│   └──────────────────────────┬──────────────────────────────────┘   │
│                              │ Optional runtime channel             │
│   ┌──────────────────────────▼──────────────────────────────────┐   │
│   │ Optional Runtime Probe                                      │   │
│   │ - Playtest telemetry / runtime logs / scene state           │   │
│   └─────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────┘
```

### 5.1 为什么必须有本地桥接进程

仅用 GDScript 编写插件无法优雅解决以下生产问题：

- 大型资产包下载与校验会阻塞编辑器；
- Git/MinIO/WebSocket/断点续传/重试等系统能力更适合独立进程；
- 测试执行、headless 运行、日志采集不能无限绑定 Godot 主线程；
- 安全上需要把“编辑器 UI 权限”与“本地受控执行权限”隔离；
- 崩溃恢复需要独立的 journal 与任务恢复器。

因此建议：

- **Godot 插件层**：GDScript 为主，必要时引入少量 GDExtension；
- **Local Bridge 层**：建议 Go 实现，负责高可靠本地系统交互；
- **Cloud Gateway 层**：新增面向编辑器的统一网关，复用现有桥接与 Agent 能力。

## 6. 与现有 EchoThink/ClawCluster 的系统映射

| 领域 | 当前权威系统 | 插件职责 | 写入路径 |
|---|---|---|---|
| 设计文档/GDD/任务说明 | Outline | 读取、提案、局部编辑预览 | Gateway → Publisher/Outline API |
| 代码历史/分支/MR | GitLab | 拉取上下文、应用补丁、发起发布 | Gateway → Publisher → GitLab |
| 二进制资产/工件 | MinIO | 拉取、导入、同步快照、上传工件 | Gateway/Local Bridge → MinIO |
| 任务/审批/状态 | Supabase/Postgres | 展示状态、请求审批、显示执行链路 | Gateway → Intake/Policy/Observability |
| Agent 执行 | ClawCluster | 发起任务、接收计划/补丁/诊断 | Gateway → ClawCluster |
| 知识/经验回流 | Graphiti | 提交候选知识、查看相关经验 | Gateway → Observability/Knowledge Worker |
| LLM 观测与日志 | Langfuse | 关联本地会话与 task run | Gateway → Observability |

## 7. 部件设计

## 7.1 Godot 编辑器插件层

### 7.1.1 入口

使用 `EditorPlugin` 作为唯一入口，负责：

- 注册主 Dock；
- 注册顶部工具栏按钮；
- 向 Scene Tree / FileSystem Dock / Script Editor 注入上下文菜单；
- 监听编辑器生命周期事件；
- 连接 Local Bridge；
- 将编辑器状态转换为结构化上下文。

### 7.1.2 UI 结构

建议采用**单主 Dock + 多标签页 + 若干上下文入口**的形态。

主 Dock 至少包含以下标签：

1. **概览**
   - 工作区绑定状态
   - 当前 Agent/任务运行状态
   - 待审批项
   - 最近失败与告警

2. **任务与规划**
   - 当前任务队列
   - 计划拆解视图
   - 验收标准
   - 风险/成本/依赖
   - “更新 Outline 提案”入口

3. **补丁与代码**
   - 补丁列表
   - 文件树差异
   - 结构化场景操作预览
   - 一键应用 / 分块应用 / 回滚 / 生成 MR

4. **资产**
   - 远端资产包查询
   - 资产预览与依赖信息
   - 导入队列
   - 本地/远端快照 diff

5. **日志与 QA**
   - 编辑器日志
   - 运行日志
   - 导入错误
   - 测试策略与执行结果
   - 提交“分析日志”任务

6. **设置与安全**
   - 登录/工作区绑定
   - GitLab/Outline/MinIO 映射
   - 本地允许的测试策略
   - 文件忽略规则
   - 本地执行权限级别

### 7.1.3 上下文入口

除 Dock 外，还应提供以下入口：

- Scene Tree 右键：对选中节点发起“解释问题 / 生成脚本 / 修改节点属性 / 提交上下文”；
- FileSystem 右键：对选中文件发起“生成补丁 / 上传为工件 / 与远端比对 / 设为任务上下文”；
- Script Editor 工具栏：对当前脚本发起“解释错误 / 生成修复补丁 / 查看 MR 差异”；
- 顶部状态按钮：显示连接状态、任务数、待审批数、最新失败。

## 7.2 Local Bridge 层

这是生产级实现的关键部件，建议作为独立本地守护进程运行。

### 7.2.1 主要职责

- 管理与云端的长连接和断线重连；
- 执行 Git 状态读取、分支切换、worktree/patch 预检；
- 执行 MinIO 下载、上传、校验、断点续传；
- 维护本地缓存、快照、ChangeSet Journal；
- 运行项目定义的测试策略；
- 采集和打包日志；
- 严格按白名单执行本地声明式操作。

### 7.2.2 本地执行白名单

Local Bridge 只接受有限操作集合：

| 操作类 | 例子 | 默认策略 |
|---|---|---|
| 只读上下文 | 扫描文件、读取当前分支、列出场景树、读取日志 | 自动允许 |
| 可逆改动 | 应用文本补丁、导入新资产、添加新脚本文件 | 用户一键确认后允许 |
| 高风险改动 | 删除资源、覆盖已有二进制、批量 rename、修改项目关键设置 | 明确二次确认 |
| 验证动作 | 运行测试策略、headless 检查、重导入 | 受项目策略控制 |
| 外部写动作 | GitLab 发布、Outline 更新、审批提交 | 只通过云端 Bridge 执行 |

### 7.2.3 本地 IPC

插件与 Local Bridge 之间建议使用：

- macOS/Linux：Unix Domain Socket
- Windows：Named Pipe

消息格式采用 JSON-RPC 2.0 或自定义轻量 RPC，要求：

- 请求/响应可关联；
- 支持流式事件推送；
- 支持长任务进度订阅；
- 支持取消任务；
- 支持 session nonce 鉴权。

## 7.3 Optional Runtime Probe

如果只依赖编辑器插件，很多运行中信息并不好拿到。为支持真正的“实时调试桥”，建议设计一个**可选运行时探针**，在游戏运行/Playtest 时上报：

- 运行时错误与堆栈；
- 当前场景与节点状态摘要；
- 关键游戏事件；
- 性能告警（可选）；
- 自定义调试标记。

该探针不是第一阶段必需，但它是“实时修 bug”体验走向生产可用的重要补件。

## 7.4 Cloud Editor Gateway

当前系统已有 Intake / Policy / Publisher / Observability 四桥，但缺少**面向编辑器交互的统一入口**。因此建议新增 `Editor Gateway`，职责不是替代现有桥，而是做以下事：

- 统一鉴权与 session；
- 聚合编辑器所需的多系统查询；
- 为编辑器提供事件流；
- 将编辑器请求编排到现有桥接与 Worker；
- 管理本地/远端快照与补丁提案模型；
- 屏蔽 Godot 客户端不应直接面对的后端复杂度。

## 8. 核心工作流设计

## 8.1 规划与 Outline 协同工作流

### 8.1.1 使用场景

- 开发者打开项目后，希望基于当前 GDD、任务队列和本地进度生成今日开发计划；
- 开发中产生新想法，需要补充或修改设计文档；
- 需要把模糊需求拆解为 Godot 内可执行任务。

### 8.1.2 流程

1. 插件加载项目绑定配置，确定 `workspace_id`、关联的 Outline 文档/集合、GitLab 项目。
2. 插件抓取当前本地上下文：当前场景、最近改动文件、未完成任务、最近错误。
3. 插件将上下文提交给 `Editor Gateway`，由其生成或创建 `plan.breakdown` / `plan.support` 类型工作项。
4. ClawCluster 的 `planner-worker` 结合 Outline、Graphiti、项目上下文产出：
   - 任务拆分
   - 依赖图
   - 风险估计
   - 验收标准
   - 建议 owner / 优先级
5. 插件以结构化视图展示计划，并允许开发者：
   - 接受整个计划
   - 接受部分子任务
   - 调整优先级
   - 提交“更新 Outline 文档”提案
6. 若开发者确认更新设计文档，插件提交 **Outline 更新提案**，而不是直接覆盖。

### 8.1.3 Outline 更新策略

由于 Outline API 主要是整篇文档创建/更新，生产级方案不应简单整文覆盖。建议采用：

1. 插件或 Gateway 维护 Markdown AST/段落级 patch；
2. 以“提案”形式展示：新增段、修改段、附录决策；
3. 对 canonical 文档采用乐观锁：比较远端版本戳/更新时间；
4. 若有冲突，则退化为：
   - 新建草稿子文档；或
   - 追加审阅建议；
   - 由人确认后再覆盖主文档。

### 8.1.4 文档更新模式

- **Append 模式**：开发日志、迭代记录、决策备注。
- **Replace-with-review 模式**：GDD、架构说明、任务规范。
- **Create-child-doc 模式**：设计讨论稿、备选方案、回顾总结。

## 8.2 资产导入与本地-远端同步工作流

### 8.2.1 问题定义

MinIO 不提供 Git 级语义，因此不能把“本地-远端资产同步”设计成 Git 替身。生产级方案应采用**对象快照 + 清单 + 差异集**模型。

### 8.2.2 资产数据模型

每个资产包至少包含：

- 原始对象文件；
- `asset_bundle.json` 元数据；
- 校验和；
- 依赖列表；
- 目标导入路径；
- Godot 导入建议；
- 许可证与来源信息；
- 预览图（可选）；
- 与任务、设计文档、生成链路的关联信息。

示例：

```json
{
  "bundle_id": "ab_01JXYZ",
  "workspace_id": "game-studio-main",
  "source": {
    "type": "agent_generated",
    "task_run_id": "tr_01JAAA",
    "outline_doc_id": "doc_123"
  },
  "assets": [
    {
      "path": "characters/hero/hero.glb",
      "sha256": "...",
      "kind": "mesh",
      "target_path": "res://assets/characters/hero/hero.glb",
      "import_preset": "character_mesh_v2"
    }
  ],
  "dependencies": [
    "textures/hero_albedo.png",
    "textures/hero_normal.png"
  ],
  "license": {
    "type": "internal",
    "attribution_required": false
  }
}
```

### 8.2.3 资产导入流程

1. 插件从 Gateway 查询与当前任务/设计相关的资产包。
2. 开发者预览资产信息与依赖关系。
3. Local Bridge 执行预检：
   - 本地路径是否冲突；
   - 是否覆盖已有资产；
   - 依赖是否齐全；
   - 许可证是否允许导入；
   - 磁盘空间是否足够。
4. 资产先下载到本地 staging 区。
5. 校验哈希与 manifest。
6. 通过受控文件操作写入 Godot 项目目录。
7. 插件调用 Godot 文件系统扫描与重导入流程。
8. 导入结果、错误日志、生成的 `.import` 结果写入 `ChangeSet` 与任务证据。

### 8.2.4 `diff / pull / push` 设计

建议把“同步”限制在**资产、生成工件、场景辅助资源、导入元数据**等对象域，不覆盖 GitLab 负责的源码历史。

远端对象布局建议：

```text
s3://artifacts/godot/<workspace_id>/snapshots/<snapshot_id>/manifest.json
s3://artifacts/godot/<workspace_id>/objects/sha256/<hash>
s3://artifacts/godot/<workspace_id>/refs/latest.json
s3://artifacts/godot/<workspace_id>/changesets/<changeset_id>.json
```

`manifest.json` 中记录：

- 路径
- 内容哈希
- 逻辑类型（texture/mesh/audio/material/scene-helper/import-meta）
- 来源 bundle / task run
- import preset hash
- 最后修改者与时间

#### Diff

对比本地 manifest 与远端 manifest，输出：

- `added`
- `modified`
- `deleted`
- `renamed`
- `metadata_changed`

#### Pull

1. 拉取最新远端 manifest；
2. 显示预览；
3. 选择性下载对象；
4. 应用到 staging；
5. 通过 Local Bridge 原子替换到项目目录；
6. 触发 Godot reimport；
7. 写入本地 snapshot journal。

#### Push

1. 只允许上传白名单范围内的对象域；
2. 本地生成 manifest 与对象哈希；
3. 将新增/变更对象上传到对象区；
4. 生成新的 snapshot manifest；
5. 以 compare-and-swap 方式更新 `latest.json`；
6. 若远端已前进，则提示冲突并要求 rebase/pull 后重试。

### 8.2.5 关键约束

- **MinIO 不是 Git**：只能提供对象版本化、清单化、快照化，不应承担源码合并语义。
- **资产冲突必须显式可见**：尤其是同路径覆盖、导入参数变化、依赖缺失。
- **大文件需要断点续传与后台下载**。

## 8.3 代码生成、补丁应用与 GitLab 发布工作流

### 8.3.1 两种代码模式

插件需要同时支持两种模式：

1. **本地原型模式**
   - 适合新功能探索；
   - Agent 产出 patch proposal；
   - 开发者在本地工作树中应用、试跑、迭代；
   - 之后再决定是否发布到 GitLab。

2. **任务/MR 模式**
   - 适合缺陷修复、明确定义的 feature；
   - 通过 `code.implement` 工作项进入标准 ClawCluster 工作流；
   - 经 QA 与审批后由 Publisher Bridge 创建 GitLab branch / MR。

### 8.3.2 补丁模型

不建议只传统一段 unified diff。生产级补丁提案应为**结构化 Patch Proposal**：

```json
{
  "patch_id": "pp_01JXYZ",
  "work_item_id": "wi_01JXYZ",
  "task_run_id": "tr_01JXYZ",
  "base": {
    "gitlab_project": "games/prototype",
    "branch": "main",
    "commit": "abc123"
  },
  "operations": [
    {
      "type": "text_patch",
      "path": "res://scripts/inventory_ui.gd",
      "patch": "@@ ..."
    },
    {
      "type": "scene_op",
      "scene": "res://scenes/ui/inventory.tscn",
      "actions": [
        {"op": "set_property", "node": "FilterPanel", "property": "visible", "value": true}
      ]
    }
  ],
  "validation_plan": [
    "ui_smoke_test",
    "inventory_filter_regression"
  ],
  "publish_intent": "local_only"
}
```

### 8.3.3 为什么需要结构化补丁

- 文本 diff 适合 GDScript、配置、shader；
- `.tscn`、`.tres`、项目设置等对象更适合结构化操作；
- 结构化补丁能提供更好的预览、校验、冲突分析与回滚；
- 未来可扩展到节点树操作、Animation/Material 变更、ProjectSettings 变更。

### 8.3.4 应用流程

1. 插件接收补丁提案；
2. Local Bridge 执行预检：
   - base commit 是否匹配；
   - 目标文件是否脏；
   - 场景是否未保存；
   - 是否存在高风险覆盖；
   - 是否需要先拉远端 branch；
3. UI 展示：
   - 文件树差异
   - 代码 diff
   - 场景结构操作清单
   - 风险摘要
   - 建议验证策略
4. 开发者可选择：
   - 整体应用
   - 单文件应用
   - 单操作应用
   - 拒绝
5. 应用后触发：
   - 脚本重载
   - 场景刷新
   - 选定测试策略
6. 结果作为本地证据上传到工件区，必要时进入 GitLab 发布。

### 8.3.5 回滚设计

Godot 的 Undo/Redo 不能完全覆盖外部文件级改动，因此必须维护独立 `ChangeSet Journal`：

- 记录 preimage/postimage 或 reverse patch；
- 记录导入前后元数据；
- 记录被改动文件的校验和；
- 支持一键回滚最近一次应用；
- 支持启动恢复：上次应用中断时自动检测并提示恢复/撤销。

### 8.3.6 GitLab 发布策略

对外发布遵守现有 ClawCluster 编码工作流：

1. 插件将本地验证结果与工件上传；
2. Gateway 请求 Publisher Bridge 执行 `gitlab_branch` 或 `gitlab_mr` 发布；
3. GitLab branch 命名和 MR 标题遵循 ClawCluster 既有约定；
4. 保护分支合并仍然必须由人审核。

插件可以提供以下辅助动作：

- 查看关联 issue/MR；
- 拉取远端 MR 为本地预览分支；
- 打开 MR 页面；
- 将本地 patch 作为“候选发布”提交到 Gateway。

## 8.4 日志分析与调试工作流

### 8.4.1 日志来源

插件应统一聚合以下日志：

- 编辑器日志；
- 资源导入日志；
- 运行/Playtest 日志；
- 测试执行日志；
- 插件自身日志；
- Local Bridge 日志。

### 8.4.2 标准化日志模型

所有日志条目统一为：

- 时间戳
- 来源（editor/runtime/import/test/plugin/bridge）
- 等级
- 文件/场景/节点上下文
- task/work item 关联
- 原始消息
- 可选堆栈

### 8.4.3 日志分析流程

1. 开发者选择日志范围或最近失败事件；
2. 插件生成 `log bundle` 与必要上下文；
3. Gateway 触发 `qa.validate` 或 `plan.support` / `code.implement` 的诊断子流程；
4. Agent 输出：
   - 可能原因排序
   - 相关文件/场景
   - 推荐修复路径
   - 可选补丁提案
5. 若需要，继续进入补丁应用流程。

### 8.4.4 运行时调试增强

若启用 Runtime Probe，可进一步支持：

- 当前场景树摘要上传；
- 关键节点属性快照；
- 游戏事件时间线；
- 用于复现的最小输入脚本/录像标记。

## 8.5 测试策略与 QA 工作流

### 8.5.1 测试策略注册

插件不应硬编码所有测试命令，而应读取项目级策略清单，例如 `.echothink/test_strategies.yaml`：

```yaml
strategies:
  - id: gdscript_smoke
    kind: headless
    profile: safe
    description: 基础脚本与资源加载检查
  - id: gut_core
    kind: framework
    framework: GUT
    profile: medium
  - id: inventory_filter_regression
    kind: custom
    profile: medium
```

每个策略在 Local Bridge 中映射为受控执行模板，不直接暴露任意命令。

### 8.5.2 测试触发时机

- 补丁应用前的 preflight 检查；
- 补丁应用后的快速验证；
- 资产导入后的 reimport/scene load check；
- 发布前的任务级 QA 运行；
- 开发者手动触发。

### 8.5.3 结果使用方式

测试结果应当：

- 在插件内可视化展示；
- 以工件上传到 MinIO；
- 关联 `task_run_id`；
- 提供给 QA Worker 与审批流程；
- 在失败时阻止一键发布。

## 9. 数据模型设计

插件侧至少需要以下核心模型：

| 模型 | 作用 |
|---|---|
| `WorkspaceBinding` | 将本地 Godot 项目绑定到 EchoThink workspace / GitLab / Outline |
| `ProjectContextSnapshot` | 当前编辑器上下文快照 |
| `TaskEnvelope` | 云端工作项在插件中的投影视图 |
| `PlanRevision` | 计划拆解及其版本 |
| `PatchProposal` | 结构化补丁提案 |
| `AssetBundle` | 远端资产包元数据 |
| `SyncSnapshot` | 本地-远端资产快照 |
| `ChangeSet` | 一次本地应用事务及其回滚信息 |
| `ApprovalTicket` | 待审批或已审批项 |
| `LogBundle` | 日志与复现证据集合 |
| `TestRunRecord` | 本地测试执行记录 |

### 9.1 项目绑定文件

建议增加可提交但不含秘密的项目绑定文件：`./.echothink/project.yaml`

```yaml
workspace_id: game-studio-main
project_name: prototype
godot:
  engine_major: 4
gitlab:
  project: games/prototype
  default_branch: main
outline:
  primary_doc_id: doc_game_design
  task_queue_doc_id: doc_dev_queue
assets:
  remote_prefix: s3://artifacts/godot/game-studio-main/
policy_profile: studio-default
```

本地秘密信息不应写入项目目录，而应存放在：

- OS Keychain / Credential Manager；
- 或 Godot `EditorSettings` 的本地用户域；
- 或 Local Bridge 自己的安全存储。

### 9.2 忽略规则

建议引入 `.echothinkignore`，用于控制哪些文件不能上传上下文或参与同步，例如：

- 导出密钥
- 本地缓存
- 大型临时文件
- 第三方闭源素材
- 个人实验目录

## 10. API 设计

## 10.1 Plugin ↔ Local Bridge RPC

建议的本地 RPC：

| 方法 | 作用 |
|---|---|
| `session.bootstrap` | 初始化本地 session、读取配置、检测项目状态 |
| `context.snapshot` | 获取当前项目/编辑器上下文 |
| `patch.preflight` | 预检补丁 |
| `patch.apply` | 应用补丁 |
| `changeset.rollback` | 回滚变更 |
| `assets.pull_preview` | 预览远端资产拉取 |
| `assets.pull_apply` | 下载并导入资产 |
| `assets.push_preview` | 预览本地资源上传 |
| `assets.push_apply` | 上传对象并生成新快照 |
| `sync.diff` | 比较本地与远端快照 |
| `tests.run` | 运行测试策略 |
| `logs.collect` | 打包日志 |
| `git.status` | 读取分支、dirty files、HEAD |
| `git.fetch_branch_preview` | 拉取远端分支/MR 供本地预览 |

## 10.2 Plugin/Local Bridge ↔ Editor Gateway

建议新增以下云端接口：

| 接口 | 方法 | 作用 |
|---|---|---|
| `/api/editor/v1/sessions` | `POST` | 创建编辑器 session，返回短期令牌与能力集 |
| `/api/editor/v1/bootstrap` | `GET` | 拉取工作区、任务、策略、绑定配置 |
| `/api/editor/v1/events` | `WS` | 推送任务状态、审批、补丁、日志分析结果 |
| `/api/editor/v1/context/snapshots` | `POST` | 上传上下文快照 |
| `/api/editor/v1/plans` | `POST` | 发起规划任务 |
| `/api/editor/v1/outline/proposals` | `POST` | 提交文档更新提案 |
| `/api/editor/v1/assets/search` | `POST` | 检索相关资产包 |
| `/api/editor/v1/assets/sync/diff` | `POST` | 请求远端快照比较 |
| `/api/editor/v1/assets/sync/pull` | `POST` | 创建资产拉取任务 |
| `/api/editor/v1/assets/sync/push` | `POST` | 创建资产推送任务 |
| `/api/editor/v1/patches` | `POST` | 请求新补丁/原型代码 |
| `/api/editor/v1/patches/{id}` | `GET` | 获取补丁详情 |
| `/api/editor/v1/log-analysis` | `POST` | 提交日志分析任务 |
| `/api/editor/v1/test-runs` | `POST` | 提交测试结果与证据 |
| `/api/editor/v1/publish` | `POST` | 请求 GitLab/Outline 发布 |

### 10.2.1 与现有 Bridge 的映射

`Editor Gateway` 自身不重写业务逻辑，而是做编排：

- 规划/编码任务 → Intake Bridge / ClawCluster
- 审批 → Policy Bridge
- 发布 → Publisher Bridge
- 证据与 trace → Observability Bridge
- 文档读取 → Outline API / MCP
- 资产读取 → MinIO / S3 API

## 10.3 事件流设计

编辑器必须有实时事件流，而不是轮询驱动。事件至少包括：

- `task.updated`
- `approval.pending`
- `approval.decided`
- `plan.ready`
- `patch.ready`
- `asset_bundle.ready`
- `publish.completed`
- `publish.failed`
- `diagnostics.ready`
- `bridge.health_changed`

## 11. 安全、审批与治理

## 11.1 鉴权模型

建议采用三层令牌：

1. **用户登录令牌**：标识开发者身份与工作区权限。
2. **编辑器 session 令牌**：短期有效，仅授予当前项目会话权限。
3. **本地 nonce/session key**：插件与 Local Bridge 间的本地通信令牌。

插件不得长期保存高权限基础设施凭据，如 GitLab root token、MinIO root key、Outline admin token。

## 11.2 本地执行安全边界

云端永远不能直接：

- 执行任意 shell；
- 访问本机任意目录；
- 读取未授权文件；
- 修改白名单外项目路径；
- 在没有审批的情况下执行 destructive 操作。

必须通过声明式 `OperationEnvelope` 下发操作，并经过：

1. schema 校验；
2. 项目策略校验；
3. 本地预检；
4. UI 审批（如有必要）；
5. Journal 记录；
6. 执行与结果回写。

## 11.3 风险分级

建议将本地动作分为四级：

- `low`：只读分析、查看上下文、轻量日志采集；
- `medium`：新增文件、文本补丁、可逆导入；
- `high`：删除/覆盖、批量重命名、项目配置修改；
- `critical`：远端发布、批量资源替换、分支切换导致工作区重写。

不同级别映射到不同审批与确认策略，并与 ClawCluster 的 `approval_policy` / `risk_level` 协同。

## 11.4 审计要求

每次重要动作都要产生日志：

- 谁触发的；
- 哪个任务触发的；
- 修改了什么；
- 应用前后哈希；
- 是否通过验证；
- 是否发布到 GitLab/Outline；
- 是否回滚。

## 12. 可靠性与故障恢复

### 12.1 离线与弱网

插件必须区分以下模式：

- **Online**：云端联通，可完整工作；
- **Degraded**：云端断续，允许查看缓存与本地历史；
- **Offline**：只能本地查看已缓存任务/补丁/日志，禁止外部发布。

### 12.2 长任务恢复

Local Bridge 应维护持久化 journal：

- 正在下载的资产；
- 正在应用的 ChangeSet；
- 正在执行的测试；
- 待上传的日志/证据。

Godot 重启后，插件应提示：

- 恢复下载；
- 恢复测试；
- 清理未完成变更；
- 回滚半应用补丁。

### 12.3 幂等性

所有远端操作必须携带稳定 ID：

- `work_item_id`
- `task_run_id`
- `changeset_id`
- `snapshot_id`
- `publish_request_id`

以避免重复发布、重复导入、重复审批。

## 13. 性能与扩展性

### 13.1 性能重点

- 大文件下载后台化；
- 上下文快照增量上传；
- 日志按窗口/大小裁剪；
- 场景/文件 diff 做缓存；
- 事件流采用推送而非高频轮询；
- Godot 主线程只做 UI 与必要编辑器 API 调用。

### 13.2 扩展点

生产级设计必须预留以下扩展：

- 新资产类型导入器；
- 新测试框架适配器；
- 新云端发布目标；
- 运行时 probe 能力增强；
- 未来支持 Unreal/其他引擎时复用 Gateway 和 Local Bridge 基础能力。

## 14. Godot 侧实现建议

## 14.1 技术选型建议

- **UI/Editor 集成**：GDScript
- **本地系统桥接**：Go 独立进程
- **高性能或语义化场景操作（可选）**：GDExtension

理由：

- GDScript 最适合 Godot 编辑器集成与快速 UI 迭代；
- Go 便于跨平台发布单二进制、处理网络/并发/对象存储/Git；
- GDExtension 只在必要时引入，避免过早复杂化。

## 14.2 推荐仓库结构

```text
echothink-godot-plugin/
├── addons/
│   └── echothink/
│       ├── plugin.cfg
│       ├── echothink_plugin.gd
│       ├── core/
│       │   ├── session_manager.gd
│       │   ├── editor_context.gd
│       │   ├── change_set_manager.gd
│       │   ├── event_bus.gd
│       │   └── policy_guard.gd
│       ├── services/
│       │   ├── bridge_client.gd
│       │   ├── gateway_client.gd
│       │   ├── patch_service.gd
│       │   ├── asset_service.gd
│       │   ├── task_service.gd
│       │   └── log_service.gd
│       ├── ui/
│       │   ├── dock_main.tscn
│       │   ├── dock_main.gd
│       │   ├── tabs/
│       │   └── widgets/
│       └── models/
├── local-bridge/
│   ├── cmd/
│   ├── internal/
│   ├── schemas/
│   └── adapters/
├── runtime-probe/
├── docs/
└── examples/
```

## 15. 分阶段实施建议

虽然本文不是 MVP 设计，但生产落地仍应分阶段实施：

### Phase 1：基础控制桥

- 项目绑定
- 登录/session
- 主 Dock
- 任务列表与事件流
- 本地上下文快照

### Phase 2：补丁与 ChangeSet 体系

- 结构化 Patch Proposal
- 预检/应用/回滚
- Git 状态读取
- 日志与测试结果关联

### Phase 3：资产同步体系

- 资产包查询与导入
- 本地-远端 snapshot diff/pull/push
- 导入错误证据链

### Phase 4：规划与文档协同

- `plan.breakdown` 集成
- Outline 更新提案
- 本地洞见回流

### Phase 5：QA、发布与治理闭环

- 测试策略注册/运行
- 发布到 GitLab / Outline
- 审批流对接
- Observability 与 Graphiti 回流

### Phase 6：运行时调试增强

- Runtime Probe
- 场景状态与 Playtest telemetry
- 更强的 bug reproduction bundle

## 16. 关键风险与待决策项

### 16.1 需要尽早确认的决策

1. **Godot 版本基线**：建议明确为 Godot 4.x 的哪个最小版本。
2. **Local Bridge 是否作为插件自带二进制分发**：这是生产体验的关键决策。
3. **资产远端命名空间**：继续复用 `artifacts` bucket 还是单独开 `game-assets` bucket。
4. **Outline 文档更新策略**：是否允许对 canonical 文档自动 publish，还是永远以 proposal 方式进入人工确认。
5. **测试框架标准化**：是否在团队内统一采用 GUT/WAT/自定义 runner。
6. **Runtime Probe 的优先级**：若你希望真正“实时修 bug”，它应尽早进入第二阶段而不是长期 postponed。

### 16.2 主要风险

- 纯插件无 sidecar 会导致可靠性与性能不足；
- 没有 ChangeSet journal 会导致补丁应用不可恢复；
- 没有资产 snapshot 语义会让 MinIO 同步难以维护；
- 没有结构化 scene/resource patch 会让 `.tscn` 变更容易脆弱；
- 允许任意本地命令会破坏安全边界；
- 没有清晰审批模型会让“AI 改工程”难以进入生产。

## 17. 最终建议

对于 EchoThink 的目标，这个 Godot 插件应被定义为：

> **一个运行在 Godot 编辑器内部、以 `EditorPlugin` 为入口、通过 Local Bridge 和 Editor Gateway 与 EchoThink 云侧协同的生产级本地控制桥。**

它的职责不是“把 AI 嵌进编辑器”，而是：

- 把 Outline 中的计划和设计真正带到开发现场；
- 把 ClawCluster 的规划、编码、QA、知识能力接入 Godot；
- 把 MinIO 中的资产与 GitLab 中的代码引入统一的本地操作面；
- 把所有本地改动变成可预览、可审批、可回滚、可发布、可审计的工程动作。

如果按这个方案实现，插件将不是一个附属工具，而是 EchoThink 在游戏开发链路中的**本地执行入口**。
