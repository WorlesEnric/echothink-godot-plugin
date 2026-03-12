# EchoThink Godot 编辑器插件设计说明

> 本文档是 `docs/godot-editor-plugin-production-design.md` 的专题补充，重点补充 lakeFS 引入后与资产工作流相关的设计。

## 1. 定位

Godot 插件不是一个直接操作裸 `MinIO` bucket 的下载器，也不是一个简单聊天面板。

在引入 `lakeFS` 后，插件在资产链路中的正确定位应当是：

- 作为 **开发者本地控制面**；
- 查看逻辑资产的当前版本状态；
- 预览云端候选资产与本地固定版本的差异；
- 在本地执行 `pull / import / validate / rollback`；
- 将验证结果、反馈与 promote 请求回送云端；
- 与 `GitLab` 中的代码工作流并行协作，而不是替代代码工作流。

## 2. 插件与后端的职责边界

### 2.1 GitLab

继续负责：

- 源代码；
- 文本配置；
- 代码审查；
- MR 流程；
- 可选的 `assets.lock` 文件。

### 2.2 lakeFS

负责：

- 资产对象版本；
- 候选版本与批准版本；
- branch / commit / tag / compare / rollback 所需的对象级版本能力。

### 2.3 Asset Bridge / Editor Gateway

插件不应直接拼接底层 lakeFS API 语义，而应通过云侧桥接层访问：

- `Asset Registry` 提供逻辑资产视图；
- `Editor Gateway` 提供编辑器友好的 API；
- `Asset Bridge` 负责把逻辑动作翻译为 lakeFS 与对象存储操作。

### 2.4 Godot 插件

负责：

- 展示资产状态；
- 拉取指定版本；
- 本地导入与验证；
- 记录本地 `ChangeSet`；
- 反馈问题并请求重生成；
- 在需要时更新项目中的资产引用锁文件。

## 3. 推荐架构

```text
Designer / AI Generate Page
        |
        v
   n8n orchestration  --->  Dify generation / evaluation
        |                              |
        +---------------> Asset Bridge + Asset Registry
                                   |
                                   v
                              lakeFS + MinIO
                                   |
                    --------------------------------
                    |                              |
                    v                              v
           Godot Editor Plugin              GitLab repo (assets.lock / code)
```

说明：

- `lakeFS + MinIO` 负责版本化资产对象；
- `GitLab` 不负责保存全部原始资产版本，而负责保存代码和可审查引用；
- 插件侧围绕“逻辑资产”和“版本引用”工作，而不是围绕裸对象路径工作。

## 4. 插件中的资产模型

插件至少需要以下模型：

### 4.1 逻辑资产

```yaml
asset_id: hero_sword
project_id: games/prototype
kind: weapon-model
```

### 4.2 版本引用

```yaml
repo: game-assets
ref: candidate
commit_id: 3f2a1c...
tag: v2026-03-13-001
```

### 4.3 本地固定引用

项目中建议增加一个可提交文件，例如：`res://.echothink/assets.lock`

```yaml
assets:
  hero_sword:
    repo: game-assets
    ref: approved
    commit_id: 3f2a1c
    import_target: res://assets/weapons/hero_sword.glb
  inventory_icons:
    repo: game-assets
    tag: ui-icons-2026-03-13
    commit_id: 77de8b
    import_target: res://assets/ui/icons/
```

该文件的作用：

- 让构建可复现；
- 让团队成员拉到相同版本；
- 让资产版本变更可以像代码一样在 GitLab 中审查。

## 5. 核心资产工作流

## 5.1 设计师生成资产

1. 设计师在 AI Generate 页面选择或创建一个 `asset_id`；
2. `n8n` 接收请求并编排生成流程；
3. `Dify` 负责提示词扩展、变体生成、评分与反馈理解；
4. 生成结果写入 `lakeFS` 的 `draft` 或 `candidate`；
5. `Asset Registry` 更新该逻辑资产的最新候选版本；
6. 插件通过事件流得知有新版本可用。

## 5.2 开发者在插件中 pull 资产

1. 插件列出当前项目相关的逻辑资产；
2. 每个资产显示：
   - 当前本地固定版本；
   - 云端最新 `candidate`；
   - 云端 `approved` / `stable`；
   - 更新时间、生成来源、预览图、差异摘要；
3. 开发者点击 `Preview Diff`；
4. 插件调用网关比较：
   - `local pinned ref`
   - `remote candidate ref`
5. 开发者确认后执行 `pull`；
6. Local Bridge 下载指定 ref 的对象并导入 Godot；
7. 插件触发重导入与验证。

## 5.3 验证与 promote

1. 插件在本地执行导入检查、场景加载检查、快速 smoke test；
2. 若通过，开发者可：
   - 仅更新本地锁定版本；
   - 请求 promote 到 `approved`；
   - 同时生成一条 GitLab 变更来更新 `assets.lock`；
3. 若失败，开发者可提交反馈，要求基于当前候选版本重生成。

## 5.4 重生成与再次 pull

1. 开发者在插件中选择“要求重生成”；
2. 插件提交：
   - `asset_id`
   - 当前候选版本
   - 失败原因
   - 本地验证结果
   - 可选截图/日志
3. `n8n + Dify` 基于该上下文生成新版本；
4. `candidate` 指向新版本；
5. 插件收到事件后可再次 pull。

## 6. 插件中需要新增的能力

## 6.1 资产版本浏览

在资产面板中至少展示：

- `asset_id`
- 当前本地固定版本
- 最新候选版本
- 最新批准版本
- commit/tag
- 差异摘要
- 生成来源（任务、设计文档、提示词版本）
- 验证状态

## 6.2 版本级 diff

插件不应只显示“文件是否不同”，还应支持：

- 版本引用差异；
- 对象清单差异；
- 导入目标路径差异；
- 依赖差异；
- 元数据差异（license / preset / generator version）。

## 6.3 选择性 pull

插件应支持：

- 拉取单个 `asset_id`
- 拉取一个资产包
- 拉取某个 tag
- 拉取某个 commit
- 批量拉取多个候选版本

## 6.4 回滚

插件必须维护 `ChangeSet`，以支持：

- 回滚最近一次 pull
- 回滚指定资产导入
- 恢复上次导入前的文件状态
- 恢复导入参数

## 6.5 锁文件更新

插件应支持在验证通过后更新 `assets.lock`，并让这类更新能够进入 GitLab 正常审查流。

## 7. 与 AI Generate 页面配合时的注意点

### 7.1 插件不直接发起底层 lakeFS 业务决策

插件可以发起：

- pull
- diff
- compare
- validate
- regenerate request
- promote request

但不应自行决定：

- 哪个版本应该成为 `approved`
- 哪个版本应当废弃
- 哪个通道应自动推进

这些动作应由：

- 前端 AI Generate 页面；
- Asset Bridge；
- 工作流审批逻辑；
- 人工确认

共同决定。

### 7.2 插件看到的是“逻辑资产”，不是“bucket path”

对开发者而言，更自然的视角应是：

- 角色武器模型
- UI 图标包
- NPC 头像集
- 场景装饰素材集

而不是：

- `s3://artifacts/game-assets/project-a/tmp/gen-2026-03-13/a.png`

因此插件的后端 API 必须以 `asset_id` 为主键，而不是以对象路径为主键。

## 8. 推荐的插件 API

建议补充以下接口：

- `GET /api/editor/v1/assets`
- `GET /api/editor/v1/assets/{asset_id}`
- `POST /api/editor/v1/assets/{asset_id}/diff`
- `POST /api/editor/v1/assets/{asset_id}/pull`
- `POST /api/editor/v1/assets/{asset_id}/validate`
- `POST /api/editor/v1/assets/{asset_id}/promote-request`
- `POST /api/editor/v1/assets/{asset_id}/regenerate-request`
- `POST /api/editor/v1/assets/lock/update`

这些接口背后应由 `Editor Gateway` 统一编排，不建议插件直接调用裸 lakeFS API。

## 9. 与现有生产设计文档的关系

当前 `docs/godot-editor-plugin-production-design.md` 中的资产部分，仍以“MinIO 快照化同步”为主。随着 lakeFS 被正式纳入资产版本控制方案，后续应将那部分进一步收敛为：

- MinIO 作为对象存储底座；
- lakeFS 作为对象版本控制层；
- GitLab 作为代码与锁文件审查层；
- 插件围绕 `asset_id + ref + commit/tag` 工作。

## 10. 结论

对于 EchoThink 的游戏资产场景，Godot 插件应当成为：

> 一个理解 lakeFS 版本语义、能够把云端候选资产拉入本地 Godot 项目并完成验证与反馈的受控开发入口。

它不应该只是“下载资产”，而应当负责把 **资产版本、导入结果、本地验证、反馈闭环** 统一到开发者工作流中。
