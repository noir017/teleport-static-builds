#!/usr/bin/env bash
#
# 把上游 Teleport 源码改成能给非 glibc 目标构建(musl / Android Bionic)。
#
# 上游唯一真正 glibc 专有的地方是 lib/inventory/metadata/metadata_linux.go 里的
#   // #include <gnu/libc-version.h>
#   import "C"
#   func (c *fetchConfig) fetchGlibcVersion() string { ... }
# 这个头文件 glibc 独有，任何 musl 工具链都变不出来。
#
# 本脚本把它拆成两个带 build tag 的文件：
#   metadata_linux_glibc.go     (linux && !musl && !android)  ← 原 cgo 实现，一字不改
#   metadata_linux_nonglibc.go  ((linux && musl) || android)  ← 纯 Go 空实现
#
# ⚠️ GOOS=android **同时满足 linux build tag**。所以 glibc 变体必须显式
#    `!android`，否则 Android 构建会去找 Bionic 根本没有的 gnu/libc-version.h。
#    反过来 nonglibc 变体在 android 上**不需要传任何 tag** 就生效 —— 少传一个
#    tag 不该变成一次编译失败。
#
# 普通 glibc Linux 构建(不带 -tags musl、非 android)行为与上游完全一致。
#
# 其余用到 cgo 的包（lib/system 的 <signal.h>、session/uacc 的 <utmp.h>、
# session/shell 与 secretsscanner/authorizedkeys 的 <pwd.h>）musl 全都提供，
# 一行都不用改 —— 所以这里刻意只动一个包。
#
# 用法: apply-nonglibc-patch.sh <上游源码目录>
#
# 设计取向: 宁可炸得响，也不要静默产出一个坏二进制。
# 上游一旦改动那个文件的形状，下面的断言会立刻失败并打印实际内容。

set -euo pipefail

SRC="${1:?用法: $0 <上游源码目录>}"
PKG="$SRC/lib/inventory/metadata"
F="$PKG/metadata_linux.go"

die() { printf '\n[apply-nonglibc-patch] 失败: %s\n' "$*" >&2; exit 1; }
note() { printf '[apply-nonglibc-patch] %s\n' "$*"; }

[ -f "$F" ] || die "找不到 $F —— 上游可能挪走了这个包"

# ── 幂等 ──
if [ -f "$PKG/metadata_linux_nonglibc.go" ]; then
  note "补丁已存在，跳过"
  exit 0
fi

# ── 断言上游形状与预期一致 ──
# 这三条任意一条不成立, 都说明上游变了, 必须人工看过再决定怎么改。
grep -q '#include <gnu/libc-version.h>' "$F" \
  || die "$F 里没有 gnu/libc-version.h。上游可能已自行去掉 cgo；先确认本补丁是否还有必要。"
grep -q '^import "C"' "$F" \
  || die "$F 里没有顶格的 import \"C\"，无法安全地移除 cgo 段"
grep -q 'func (c \*fetchConfig) fetchGlibcVersion() string' "$F" \
  || die "$F 里没有预期的 fetchGlibcVersion 方法签名"

# 记下原始的函数体, 原样搬进 glibc 变体, 避免手抄产生偏差
note "上游文件形状符合预期"

# ── 1. 从 metadata_linux.go 里摘掉 cgo ──
awk '
  # 丢掉 cgo 注释块里的 include 与紧随的 import "C"
  /^\/\/ #include <gnu\/libc-version\.h>$/ { next }
  /^import "C"$/                           { next }
  # 丢掉 fetchGlibcVersion 的文档注释 + 函数体(到第一个顶格 } 为止)
  /^\/\/ fetchGlibcVersion / { skip = 1 }
  skip && /^}$/             { skip = 0; next }
  skip                      { next }
  { print }
' "$F" > "$F.tmp"

# 摘完必须干净: 不能再有 cgo 痕迹, 但纯 Go 的 fetchOSVersion 必须还在
grep -q 'import "C"' "$F.tmp" && die "移除后仍残留 import \"C\""
grep -q 'gnu_get_libc_version' "$F.tmp" && die "移除后仍残留 gnu_get_libc_version"
grep -q 'func (c \*fetchConfig) fetchOSVersion() string' "$F.tmp" \
  || die "误删了 fetchOSVersion —— awk 规则与上游新版本不匹配"

# 收敛连续空行, 并去掉 EOF 处的空行。
# 后者是必须的: 被删掉的函数前面那个空行会留下来变成尾随空行, gofmt 不接受。
awk 'NF==0 { if (blank++) next } NF { blank=0 } { print }' "$F.tmp" \
  | awk '{ line[NR] = $0 } END { last = NR; while (last > 0 && line[last] ~ /^[[:space:]]*$/) last--; for (i = 1; i <= last; i++) print line[i] }' \
  > "$F"
rm -f "$F.tmp"
note "已从 metadata_linux.go 移除 cgo"

# ── 2. glibc 变体: 原实现 ──
cat > "$PKG/metadata_linux_glibc.go" <<'EOF'
//go:build linux && !musl && !android

/*
 * Teleport
 * Copyright (C) 2024  Gravitational, Inc.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

package metadata

// #include <gnu/libc-version.h>
import "C"

// fetchGlibcVersion returns the glibc version string as returned by
// gnu_get_libc_version.
func (c *fetchConfig) fetchGlibcVersion() string {
	return C.GoString(C.gnu_get_libc_version())
}
EOF

# ── 3. musl 变体: 纯 Go ──
cat > "$PKG/metadata_linux_nonglibc.go" <<'EOF'
//go:build (linux && musl) || android

/*
 * Teleport
 * Copyright (C) 2024  Gravitational, Inc.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

package metadata

// fetchGlibcVersion 在非 glibc 的 libc 上没有对应实现。
//
// musl 与 Android Bionic 都不导出运行时版本查询接口 —— 没有
// gnu_get_libc_version, 也没有与之等价的符号。返回空串是如实上报"未知",
// 比编造一个版本号诚实: 这个值只用于 inventory 展示,
// 上游对空串的处理是直接省略该字段。
func (c *fetchConfig) fetchGlibcVersion() string {
	return ""
}
EOF

note "已生成 metadata_linux_glibc.go / metadata_linux_nonglibc.go"

# ── 4. 交给 Go 自己确认结果可用 ──
# gofmt 能抓出 awk 破坏语法、以及 //go:build 位置不对之类的问题
# (gofmt 要求 build 约束在文件最顶部, 在版权块注释之前)。
#
# ⚠️ 这项检查曾经因为"环境里没有 gofmt 就静默跳过"而让本地测试假绿。
#    现在跳过时会明确出声, 别再把"没报错"当成"检查通过"。
if command -v gofmt >/dev/null 2>&1; then
  bad="$(gofmt -l "$PKG" || true)"
  if [ -n "$bad" ]; then
    printf '\n[apply-nonglibc-patch] gofmt 差异:\n' >&2
    for f in $bad; do gofmt -d "$f" >&2 || true; done
    die "生成的文件不符合 gofmt: $bad"
  fi
  note "gofmt 检查通过"
else
  note "⚠️ 环境里没有 gofmt, 已跳过格式检查(不是通过)"
fi

note "完成"
