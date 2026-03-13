#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  ./scripts/build.sh [--test] [--verbose]

选项:
  --test      构建后执行 `go test ./...`
  --verbose   打印更详细的构建命令
  -h, --help  显示帮助
EOF
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "错误: 未找到命令 '$name'。请先安装后再重试。" >&2
    exit 1
  fi
}

check_go_version() {
  local version
  version="$(go env GOVERSION 2>/dev/null || true)"

  if [[ -z "$version" ]]; then
    echo "警告: 无法读取 Go 版本，继续尝试构建。" >&2
    return
  fi

  if [[ "$version" =~ ^go([0-9]+)\.([0-9]+) ]]; then
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    if (( major < 1 || (major == 1 && minor < 22) )); then
      echo "错误: 需要 Go 1.22 或更高版本，当前为 ${version}。" >&2
      exit 1
    fi
  fi

  echo "==> 使用 ${version}"
}

run_tests=0
verbose=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test)
      run_tests=1
      ;;
    --verbose)
      verbose=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "错误: 不支持的参数 '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BRIDGE_DIR="${ROOT_DIR}/local-bridge"
OUTPUT_DIR="${ROOT_DIR}/bin"
OUTPUT_BIN="${OUTPUT_DIR}/echothink-bridge"

if [[ ! -f "${BRIDGE_DIR}/go.mod" ]]; then
  echo "错误: 未找到 ${BRIDGE_DIR}/go.mod，当前目录结构可能不是预期的插件仓库。" >&2
  exit 1
fi

require_command go
check_go_version

mkdir -p "${OUTPUT_DIR}"

build_cmd=(go build -o "${OUTPUT_BIN}" ./cmd/echothink-bridge)
test_cmd=(go test ./...)

if (( verbose == 1 )); then
  set -x
fi

echo "==> 构建 EchoThink Local Bridge"
(
  cd "${BRIDGE_DIR}"
  "${build_cmd[@]}"
)

if (( run_tests == 1 )); then
  echo "==> 执行 Go 测试"
  (
    cd "${BRIDGE_DIR}"
    "${test_cmd[@]}"
  )
fi

set +x 2>/dev/null || true

echo "==> 输出文件: ${OUTPUT_BIN}"
cat <<EOF

构建完成。

常用后续命令:
  启动本地桥接进程:
    ECHOTHINK_PROJECT_DIR="${ROOT_DIR}" "${OUTPUT_BIN}"

  打开 Godot 编辑器:
    godot --editor "${ROOT_DIR}"

  检查桥接健康状态:
    curl http://127.0.0.1:19821/healthz

说明:
  `--test` 目前只覆盖 Go 侧的桥接进程代码。
  Godot 侧自动化 smoke / GUT 测试策略已声明，但仓库中尚未补齐对应测试脚本与 GUT 插件目录。
EOF
