# EchoThink Godot 插件

这是一个面向 Godot 编辑器的 EchoThink 插件代码库，当前仓库包含三部分：

- `addons/echothink`：Godot 编辑器插件本体。
- `local-bridge`：本地桥接进程，使用 Go 实现，负责 IPC、日志、补丁、任务与测试编排。
- `runtime-probe`：可选运行时探针，用于在 Playtest / 运行阶段采集上下文与日志。

当前 `project.godot` 已默认启用插件，所以直接以 Godot 编辑器打开仓库即可看到插件入口。

## 当前状态

这个仓库已经具备以下能力：

- Godot 插件代码结构完整，可作为编辑器插件加载。
- Go 侧本地桥接进程可单独构建与启动。
- 本地桥接进程带有健康检查接口，便于验证基础运行状态。
- `.echothink/test_strategies.yaml` 已声明测试策略。

但也有一个需要提前说明的限制：

- 当前仓库中还没有落地 Godot 侧 smoke 脚本，也没有引入 `addons/gut`，因此自动化测试暂时以 Go 侧 `go test ./...` 和 Godot 编辑器手工冒烟验证为主。

## 目录说明

```text
echothink-godot-plugin/
├── addons/echothink/        # Godot 编辑器插件
├── local-bridge/            # Go 本地桥接进程
├── runtime-probe/           # 可选运行时探针
├── docs/                    # 设计文档
├── .echothink/              # 项目配置与测试策略
├── scripts/build.sh         # 构建脚本
└── bin/                     # 构建输出（已被 .gitignore 忽略）
```

## 环境要求

以下说明以 Linux / macOS 为主：

- Godot `4.3`
- Go `1.22+`
- Bash
- `curl`（可选，用于检查健康接口）

## 快速开始

在仓库根目录执行：

```bash
cd /wkspace/echothink/echothink-godot-plugin
./scripts/build.sh
```

脚本会将本地桥接进程构建到：

```bash
./bin/echothink-bridge
```

如果你希望构建后顺便跑一遍 Go 侧测试：

```bash
./scripts/build.sh --test
```

如果你想看更详细的构建命令：

```bash
./scripts/build.sh --verbose
```

## 启动方式

### 1. 启动本地桥接进程

```bash
cd /wkspace/echothink/echothink-godot-plugin
export ECHOTHINK_PROJECT_DIR="$PWD"
export ECHOTHINK_SOCKET_PATH=/tmp/echothink-bridge.sock
export ECHOTHINK_HEALTH_PORT=19821
./bin/echothink-bridge
```

说明：

- `ECHOTHINK_PROJECT_DIR` 是必须项，桥接进程会据此识别 `project.godot`、Git 状态和项目上下文。
- `ECHOTHINK_SOCKET_PATH` 默认就是 `/tmp/echothink-bridge.sock`，Godot 插件也默认连接这个地址。
- `ECHOTHINK_HEALTH_PORT` 默认是 `19821`。
- `ECHOTHINK_GATEWAY_URL` / `ECHOTHINK_GATEWAY_TOKEN` 目前可以不配，本地桥接进程仍然可以启动。

### 2. 打开 Godot 编辑器

```bash
cd /wkspace/echothink/echothink-godot-plugin
godot --editor .
```

打开后可以检查：

- 是否出现 EchoThink 相关 Dock / 工具菜单。
- 编辑器启动时是否没有 GDScript 解析错误。
- 插件是否能连接到本地桥接进程。

### 3. 检查桥接健康状态

桥接进程启动后，另开一个终端执行：

```bash
curl http://127.0.0.1:19821/healthz
```

正常情况下会返回包含以下信息的 JSON：

- `status`
- `session_id`
- `workspace_id`
- `project_valid`
- `gateway_ready`

## 测试方式

### 1. Go 侧测试

当前最直接、最稳定的自动化测试是 Go 侧测试：

```bash
cd /wkspace/echothink/echothink-godot-plugin/local-bridge
go test ./...
```

由于当前仓库还没有 `_test.go` 文件，这个命令的主要价值是：

- 验证全部 Go 包都能成功编译。
- 提前发现依赖、接口签名或构建层面的回归问题。

### 2. Godot 编辑器手工冒烟

建议至少做以下检查：

1. `godot --editor .` 能正常打开项目。
2. EchoThink 插件已被自动启用。
3. 编辑器中没有明显的 GDScript 报错。
4. 本地桥接进程健康检查通过。
5. 插件能完成一次基础连接或刷新动作。

### 3. 当前未完成的自动化测试部分

虽然 `.echothink/test_strategies.yaml` 里已经声明了：

- `gdscript_smoke`
- `gut_core`
- `scene_smoke`

但仓库里暂时还缺这些配套内容：

- `.echothink/safe_smoke.gd` 或 `.echothink/smoke.gd`
- `tests/smoke.gd`
- `addons/gut/gut_cmdln.gd`

这意味着：

- `headless` smoke 测试目前还没有实际脚本可跑。
- GUT 测试目前也没有 runner 可用。

如果下一步要补齐测试，建议先添加一个最小 smoke 脚本，再决定是否正式接入 GUT。

## 常用环境变量

本项目常用的环境变量如下：

- `ECHOTHINK_PROJECT_DIR`：Godot 项目根目录。
- `ECHOTHINK_SOCKET_PATH`：本地桥接进程的 Unix Socket 路径。
- `ECHOTHINK_HEALTH_PORT`：桥接进程健康检查端口。
- `ECHOTHINK_LOG_LEVEL`：日志级别，如 `debug`、`info`。
- `ECHOTHINK_GATEWAY_URL`：远端网关地址，可选。
- `ECHOTHINK_GATEWAY_TOKEN`：远端网关令牌，可选。
- `ECHOTHINK_POLICY_PROFILE`：策略配置名，可选。

## 常见问题

### 1. `go: command not found`

说明当前环境没有安装 Go，或者 Go 不在 `PATH` 中。请先安装 Go `1.22+`。

### 2. `godot: command not found`

说明当前环境没有安装 Godot，或者 Godot 可执行文件不在 `PATH` 中。

### 3. 健康检查端口被占用

如果 `19821` 已被占用，可以修改端口：

```bash
export ECHOTHINK_HEALTH_PORT=29821
./bin/echothink-bridge
```

然后使用新的端口检查：

```bash
curl http://127.0.0.1:29821/healthz
```

### 4. 插件没有连上桥接进程

优先检查以下几项：

- `ECHOTHINK_PROJECT_DIR` 是否指向当前 Godot 项目根目录。
- `ECHOTHINK_SOCKET_PATH` 是否与插件侧配置一致。
- 桥接进程是否已经启动。
- Godot 编辑器控制台是否有脚本错误。

## 建议的后续工作

如果你准备继续完善这个插件仓库，推荐按下面的顺序推进：

1. 增加最小可运行的 Godot smoke 脚本。
2. 将 smoke 测试接到 headless 模式中验证。
3. 再决定是否引入 GUT 作为正式测试框架。
4. 补充 CI，把 `./scripts/build.sh --test` 接入自动检查。
