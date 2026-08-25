#!/usr/bin/env bash
#
# 把上游 Teleport 源码改成能给非 glibc 目标构建(musl / Android Bionic)。
#
# 用法: apply-nonglibc-patch.sh <上游源码目录> [目标]
#   目标 = musl (默认) | android
#
# 两个目标需要的改动量差很多:
#
#   musl     只需 1 个包。musl 提供了 <signal.h>/<utmp.h>/<pwd.h> 的完整实现,
#            唯一无解的是 <gnu/libc-version.h>(glibc 独有)。
#
#   android  额外需要 2 个包。Bionic 比 musl 缺得多 —— 它**没有 passwd 枚举
#            API**(setpwent/getpwent/endpwent), 也没有 utmp 的写入函数
#            (updwtmp/getutline)。这不是疏漏: Android 上根本不存在
#            /etc/passwd 和 utmp, "遍历系统用户"这个概念不成立。
#            好在上游给这两个包都留了 _other.go 兜底实现, 我们只需把
#            build 约束改成让 android 走兜底那条路。
#
# 设计取向: 宁可炸得响, 也不要静默产出一个坏二进制。
# 每处改动前都断言上游的当前形状, 不符就立刻退出并打印实际内容。

set -euo pipefail

SRC="${1:?用法: $0 <上游源码目录> [musl|android]}"
TARGET="${2:-musl}"

case "$TARGET" in
  musl|android) ;;
  *) echo "目标只能是 musl 或 android, 收到: $TARGET" >&2; exit 2 ;;
esac

die()  { printf '\n[apply-nonglibc-patch] 失败: %s\n' "$*" >&2; exit 1; }
note() { printf '[apply-nonglibc-patch] %s\n' "$*"; }

note "目标 = $TARGET"

TOUCHED=""   # 供最后的 gofmt 检查

# ──────────────────────────────────────────────────────────────
# 工具: 改写一行已存在的 //go:build 约束
# ──────────────────────────────────────────────────────────────
retag() {
  f="$1"; want="$2"; new="$3"
  [ -f "$f" ] || die "找不到 $f —— 上游布局可能变了"
  if grep -qxF "$new" "$f"; then
    note "  $(basename "$f"): 已是目标约束, 跳过"
    return 0
  fi
  grep -qxF "$want" "$f" || die "$f 的约束不是预期的
        预期: $want
        实际: $(grep -m1 '^//go:build' "$f" || echo '<该文件没有 //go:build>')
        上游改了约束, 需要人工看过再决定怎么调整。"
  awk -v w="$want" -v n="$new" '$0==w && !d {print n; d=1; next} {print}' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
  note "  $(basename "$f"): $want  →  $new"
  TOUCHED="$TOUCHED $(dirname "$f")"
}

# ──────────────────────────────────────────────────────────────
# 工具: 给一个**本来没有** //go:build 的文件插入约束
# (这类文件靠 _linux.go 文件名后缀约束; 插入的 tag 与后缀是 AND 关系)
# ──────────────────────────────────────────────────────────────
addtag() {
  f="$1"; tag="$2"
  [ -f "$f" ] || die "找不到 $f —— 上游布局可能变了"
  if grep -qxF "$tag" "$f"; then
    note "  $(basename "$f"): 已有该约束, 跳过"
    return 0
  fi
  if grep -q '^//go:build' "$f"; then
    die "$f 现在有了 //go:build ($(grep -m1 '^//go:build' "$f"))
        本脚本原本假设它没有(只靠文件名后缀约束)。上游改了, 需要人工确认。"
  fi
  # gofmt 要求 //go:build 在文件最顶部, 在版权块注释之前
  { printf '%s\n\n' "$tag"; cat "$f"; } > "$f.tmp"
  mv "$f.tmp" "$f"
  note "  $(basename "$f"): 插入 $tag"
  TOUCHED="$TOUCHED $(dirname "$f")"
}

# ══════════════════════════════════════════════════════════════
# 1. lib/inventory/metadata —— 两个目标都需要
#
# 上游这里有 <gnu/libc-version.h>, glibc 独有, musl 和 Bionic 都没有。
# 拆成两个 build tag 变体:
#   metadata_linux_glibc.go     linux && !musl && !android   原 cgo 实现
#   metadata_linux_nonglibc.go  (linux && musl) || android   纯 Go 空实现
#
# ⚠️ GOOS=android **同时满足 linux build tag**, 所以 glibc 变体必须显式
#    !android; 反过来 nonglibc 变体在 android 上不需要传任何 tag 就生效 ——
#    少传一个 tag 不该变成一次编译失败。
# ══════════════════════════════════════════════════════════════
PKG="$SRC/lib/inventory/metadata"
F="$PKG/metadata_linux.go"

if [ -f "$PKG/metadata_linux_nonglibc.go" ]; then
  note "[metadata] 补丁已存在, 跳过"
else
  [ -f "$F" ] || die "找不到 $F —— 上游可能挪走了这个包"

  grep -q '#include <gnu/libc-version.h>' "$F" \
    || die "$F 里没有 gnu/libc-version.h。上游可能已自行去掉 cgo；先确认本补丁是否还有必要。"
  grep -q '^import "C"' "$F" \
    || die "$F 里没有顶格的 import \"C\"，无法安全地移除 cgo 段"
  grep -q 'func (c \*fetchConfig) fetchGlibcVersion() string' "$F" \
    || die "$F 里没有预期的 fetchGlibcVersion 方法签名"
  note "[metadata] 上游文件形状符合预期"

  awk '
    /^\/\/ #include <gnu\/libc-version\.h>$/ { next }
    /^import "C"$/                           { next }
    /^\/\/ fetchGlibcVersion / { skip = 1 }
    skip && /^}$/             { skip = 0; next }
    skip                      { next }
    { print }
  ' "$F" > "$F.tmp"

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
  note "[metadata] 已从 metadata_linux.go 移除 cgo"

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

  note "[metadata] 已生成 metadata_linux_glibc.go / metadata_linux_nonglibc.go"
  TOUCHED="$TOUCHED $PKG"
fi

# ══════════════════════════════════════════════════════════════
# 2. 仅 android: session/host/user
#
# user_linux_cgo.go 用 setpwent/getpwent/endpwent 枚举系统用户。
# **Bionic 没有这三个函数** —— Android 没有可枚举的 passwd 数据库。
# (getpwnam/getpwuid 是有的, Bionic 会为 Android uid 合成条目, 所以
#  单个用户的查询没问题, 不能做的是"列出所有用户"。)
#
# 上游已有现成的两条替代路径, 我们只需放行:
#   user_forward.go  转发给 os/user (它在 cgo 下最终还是走 Bionic getpwnam)
#   user_other.go    GetHostUsers 的兜底实现
# ══════════════════════════════════════════════════════════════
if [ "$TARGET" = android ]; then
  UPKG="$SRC/session/host/user"
  if [ -d "$UPKG" ]; then
    note "[host/user] 让 android 走非 cgo 路径"
    retag "$UPKG/user_linux_cgo.go" \
          '//go:build linux && cgo' \
          '//go:build linux && cgo && !android'
    retag "$UPKG/user_forward.go" \
          '//go:build !linux || !cgo' \
          '//go:build !linux || !cgo || android'
    retag "$UPKG/user_other.go" \
          '//go:build !darwin && !linux' \
          '//go:build (!darwin && !linux) || android'
  else
    die "找不到 $UPKG。
        v18.10.7 起系统用户枚举在这个包里(更早的版本在
        lib/secretsscanner/authorizedkeys/users_list_linux.go)。
        上游又挪动了位置, 需要人工确认 android 该排除哪些文件。"
  fi

  # ════════════════════════════════════════════════════════════
  # 3. 仅 android: session/uacc
  #
  # utmp_linux.go 通过 uacc.h 调 updwtmp/getutline 写 utmp/wtmp。
  # **Bionic 的 <utmp.h> 只有极小子集**, 这些写入函数都没有 ——
  # Android 上不存在 utmp 会话记账。
  #
  # ⚠️ utmp_linux.go **本来没有 //go:build**, 只靠 _linux.go 文件名后缀约束。
  #    插入的 tag 与后缀是 AND 关系, 即 linux && !android。
  #
  # utmp_other.go 定义了 UtmpBackend 类型和全部 5 个方法, 而 uacc.go 只用到
  # *UtmpBackend 与 NewUtmpBackend, 所以换过去是自洽的(已逐个符号核对)。
  # 代价: Android 上会话不写 utmp —— 反正也没有消费方。
  # ════════════════════════════════════════════════════════════
  APKG="$SRC/session/uacc"
  if [ -d "$APKG" ]; then
    note "[uacc] 让 android 走 utmp 兜底实现"
    addtag "$APKG/utmp_linux.go" '//go:build !android'
    retag  "$APKG/utmp_other.go" \
           '//go:build !linux' \
           '//go:build !linux || android'
  else
    die "找不到 $APKG —— 上游挪走了 uacc 包"
  fi
fi

# ══════════════════════════════════════════════════════════════
# 4. 交给 Go 自己确认结果可用
#
# gofmt 能抓出 awk 破坏语法、以及 //go:build 位置不对之类的问题
# (gofmt 要求 build 约束在文件最顶部, 在版权块注释之前)。
#
# ⚠️ 这项检查曾经因为"环境里没有 gofmt 就静默跳过"而让本地测试假绿。
#    现在跳过时会明确出声, 别再把"没报错"当成"检查通过"。
# ══════════════════════════════════════════════════════════════
DIRS="$(echo "$TOUCHED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
if [ -z "$DIRS" ]; then
  note "没有任何改动(全部已是目标状态)"
elif command -v gofmt >/dev/null 2>&1; then
  bad="$(gofmt -l $DIRS || true)"
  if [ -n "$bad" ]; then
    printf '\n[apply-nonglibc-patch] gofmt 差异:\n' >&2
    for f in $bad; do gofmt -d "$f" >&2 || true; done
    die "改动后的文件不符合 gofmt: $bad"
  fi
  note "gofmt 检查通过 ($DIRS)"
else
  note "⚠️ 环境里没有 gofmt, 已跳过格式检查(不是通过)"
fi

note "完成"
