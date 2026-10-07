#!/bin/bash
# ============================================================
# 提交/打包前的静态检查
#
# 检查项：
#   1. 变量后紧跟非 ASCII 字符（全角标点会被 bash 当成变量名的一部分，
#      在 set -u 下报 unbound variable）—— 这个坑踩过两次，故固化成检查
#   2. shell 语法
#   3. Python 语法
#   4. 是否误带凭据（.sub-url / .api-secret / 真实 config.yaml）
#
# 用法: bash scripts/check.sh
# ============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

echo "=== 1. 全角标点紧跟变量检查 ==="
HITS="$(python3 - "$REPO" <<'PY'
import re, pathlib, sys
root = pathlib.Path(sys.argv[1])
total = 0
for p in sorted(root.rglob("*.sh")):
    s = p.read_text(encoding="utf-8", errors="replace")
    for m in re.finditer(r'\$(\w+)(?=[^\x00-\x7f])', s):
        line = s[:m.start()].count("\n") + 1
        print(f"  {p.relative_to(root)}:{line}  ${m.group(1)} 后紧跟 {s[m.end()]!r}")
        total += 1
print(f"__COUNT__{total}")
PY
)"
COUNT="$(printf '%s' "$HITS" | grep -o '__COUNT__[0-9]*' | grep -o '[0-9]*$')"
printf '%s\n' "$HITS" | grep -v '__COUNT__'
if [ "${COUNT:-0}" != "0" ]; then
  echo "  ✗ 发现 $COUNT 处，请改为 \${VAR} 形式"
  FAIL=1
else
  echo "  ✓ 无"
fi

echo
echo "=== 2. shell 语法 ==="
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then echo "  ✓ ${f#$REPO/}"; else echo "  ✗ ${f#$REPO/}"; FAIL=1; fi
done < <(find "$REPO" -name "*.sh" -not -path "*/build/*")

echo
echo "=== 3. Python 语法 ==="
while IFS= read -r f; do
  if python3 -c "import ast;ast.parse(open('$f').read())" 2>/dev/null; then
    echo "  ✓ ${f#$REPO/}"
  else
    echo "  ✗ ${f#$REPO/}"; FAIL=1
  fi
done < <(find "$REPO" -name "*.py" -not -path "*/build/*")

echo
echo "=== 4. 凭据泄漏检查 ==="
LEAK=0
for pat in ".sub-url" ".api-secret" ".mimio-rules-backup.yaml" ".mimio-validate-*.yaml" ".config.yaml.notun" ".mimio-chain.json"; do
  if [ -n "$(find "$REPO" -name "$pat" -not -path "*/build/*" 2>/dev/null)" ]; then
    echo "  ✗ 仓库内存在 $pat"; LEAK=1
  fi
done
# 真实 config.yaml（含 secret 字段）不应存在，只应有模板
if [ -n "$(find "$REPO" -name "config.yaml" 2>/dev/null)" ]; then
  echo "  ✗ 仓库内存在 config.yaml（应为 config.template.yaml）"; LEAK=1
fi
# 真实订阅特征：http(s)://<域名>:<端口>/subs/<较长 token>
# 故意不写死具体服务商名——既避免把域名带进仓库，也避免检查脚本自我误报
SUBRE='https?://[A-Za-z0-9.-]+:[0-9]{2,5}/subs/[A-Za-z0-9_-]{4,}'
if grep -rqE "$SUBRE" "$REPO" 2>/dev/null; then
  echo "  ! 疑似含真实订阅地址，请人工确认："
  grep -rnE "$SUBRE" "$REPO" 2>/dev/null | head -5 | sed 's/^/      /'
fi
[ "$LEAK" = "0" ] && echo "  ✓ 未发现凭据文件" || FAIL=1

echo
if [ "$FAIL" = "0" ]; then
  echo "=== 全部通过 ==="
else
  echo "=== 存在问题，请修复 ==="
  exit 1
fi
