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

# ──────────────────────────────────────────────────────────────
# 工具: 生成 session/host/user 的 android 专用实现
#
# 为什么需要它, 见下面第 2 节顶部那段长注释。一句话:
# **Go 标准库的 os/user 在 GOOS=android 下是硬编码的桩**, 所以不能像最初
# 那样把整个包让给转发实现, 必须自己用 cgo 调 Bionic。
#
# Bionic 有的(直接用):  getpwnam_r  getpwuid_r  getgrnam_r  getgrgid_r
# Bionic 没有的(让路):  setpwent    getpwent    endpwent    → GetHostUsers
# ──────────────────────────────────────────────────────────────
emit_android_hostuser() {
  pkg="$1"
  out="$pkg/user_android.go"
  if [ -f "$out" ]; then
    note "  user_android.go: 已存在, 跳过"
    return 0
  fi
  cat > "$out" <<'EOF'
//go:build android && cgo

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

package user

/*
#include <sys/types.h>
#include <pwd.h>
#include <grp.h>
#include <stdlib.h>
*/
import "C"

import (
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"unsafe"

	osuser "os/user"

	"github.com/gravitational/trace"
)

// 这个文件存在的唯一原因是 Go 标准库在 GOOS=android 下把 os/user 变成了桩:
// lookup_android.go 的约束是无条件的 `//go:build android`, 四个 Lookup* 一律
// 返回 "user: Lookup not implemented on android"; cgo 实现 cgo_lookup_unix.go
// 的约束带 `&& !android`, 开着 cgo 也选不中。
//
// 但 Bionic 本身是能查的 —— 它为 Android 的 uid **合成** passwd 条目
// (u0_aNNN, uid 与 gid 同值)。所以这里直接调 C, 绕开标准库那层桩。
//
// 唯一真正做不到的是**枚举**(setpwent/getpwent/endpwent 在 Bionic 里不存在),
// 那个留给 GetHostUsers 返回 ErrUnsupportedPlatform。

const (
	initialBufSize = 1024
	maxBufSize     = 1 << 16
)

// lookupUser 用 getpwnam_r / getpwuid_r 查单个用户。
// byName 为真时用 name, 否则用 uid。找不到时返回 (nil, nil)。
func lookupUser(name string, uid C.uid_t, byName bool) (*osuser.User, error) {
	var cname *C.char
	if byName {
		cname = C.CString(name)
		defer C.free(unsafe.Pointer(cname))
	}

	size := C.size_t(initialBufSize)
	for {
		buf := C.malloc(size)
		if buf == nil {
			return nil, trace.BadParameter("out of memory looking up user")
		}

		var pwd C.struct_passwd
		var result *C.struct_passwd
		var rv C.int
		if byName {
			rv = C.getpwnam_r(cname, &pwd, (*C.char)(buf), size, &result)
		} else {
			rv = C.getpwuid_r(uid, &pwd, (*C.char)(buf), size, &result)
		}

		// 缓冲区不够就翻倍重来, 这是 _r 系列的标准约定
		if rv == C.int(syscall.ERANGE) {
			C.free(buf)
			if size >= maxBufSize {
				return nil, trace.LimitExceeded("passwd entry for %q exceeds %d bytes", name, maxBufSize)
			}
			size *= 2
			continue
		}
		if rv != 0 {
			C.free(buf)
			return nil, trace.Wrap(syscall.Errno(rv))
		}
		if result == nil {
			C.free(buf)
			return nil, nil
		}

		// 必须在 free 之前把 C 字符串拷成 Go 字符串
		u := &osuser.User{
			Uid:      strconv.FormatUint(uint64(result.pw_uid), 10),
			Gid:      strconv.FormatUint(uint64(result.pw_gid), 10),
			Username: C.GoString(result.pw_name),
			HomeDir:  C.GoString(result.pw_dir),
		}
		C.free(buf)
		u.Name = u.Username
		applyTermuxHome(u)
		return u, nil
	}
}

// applyTermuxHome 把 Bionic 合成的 home 目录换成 Termux 的真实 home。
//
// Bionic 给 app uid 合成的 pw_dir 恒为 "/data" —— 那个目录在 app 沙箱里
// 不可写, 会话会开在一个用不了的 cwd 上。Termux 的真实 home 只能从环境变量
// 得知($HOME, 或 $PREFIX 的同级 home 目录)。
//
// ⚠️ 只对**当前进程自己的 uid** 生效。$HOME 描述的是本进程的环境, 拿它去
// 覆盖另一个用户的 home 是错的。Android 上也没有别的用户可登录, 所以这个
// 限制不损失任何能力。
func applyTermuxHome(u *osuser.User) {
	if u.Uid != strconv.Itoa(os.Getuid()) {
		return
	}

	home := os.Getenv("HOME")
	if home == "" {
		// $PREFIX = .../files/usr, home 在 .../files/home
		if prefix := os.Getenv("PREFIX"); prefix != "" {
			home = filepath.Join(filepath.Dir(prefix), "home")
		}
	}
	if home == "" {
		return
	}
	// 只在目录真实存在时才覆盖, 免得把一个坏值写进去
	if fi, err := os.Stat(home); err != nil || !fi.IsDir() {
		return
	}
	u.HomeDir = home
}

// lookupGroup 用 getgrnam_r / getgrgid_r 查单个组。找不到时返回 (nil, nil)。
func lookupGroup(name string, gid C.gid_t, byName bool) (*osuser.Group, error) {
	var cname *C.char
	if byName {
		cname = C.CString(name)
		defer C.free(unsafe.Pointer(cname))
	}

	size := C.size_t(initialBufSize)
	for {
		buf := C.malloc(size)
		if buf == nil {
			return nil, trace.BadParameter("out of memory looking up group")
		}

		var grp C.struct_group
		var result *C.struct_group
		var rv C.int
		if byName {
			rv = C.getgrnam_r(cname, &grp, (*C.char)(buf), size, &result)
		} else {
			rv = C.getgrgid_r(gid, &grp, (*C.char)(buf), size, &result)
		}

		if rv == C.int(syscall.ERANGE) {
			C.free(buf)
			if size >= maxBufSize {
				return nil, trace.LimitExceeded("group entry for %q exceeds %d bytes", name, maxBufSize)
			}
			size *= 2
			continue
		}
		if rv != 0 {
			C.free(buf)
			return nil, trace.Wrap(syscall.Errno(rv))
		}
		if result == nil {
			C.free(buf)
			return nil, nil
		}

		g := &osuser.Group{
			Gid:  strconv.FormatUint(uint64(result.gr_gid), 10),
			Name: C.GoString(result.gr_name),
		}
		C.free(buf)
		return g, nil
	}
}

// Lookup 按用户名查找。
func Lookup(username string) (*osuser.User, error) {
	u, err := lookupUser(username, 0, true)
	if err != nil {
		return nil, trace.Wrap(err)
	}
	if u == nil {
		return nil, osuser.UnknownUserError(username)
	}
	return u, nil
}

// LookupId 按 uid 查找。
func LookupId(id string) (*osuser.User, error) {
	uid, err := strconv.ParseUint(id, 10, 32)
	if err != nil {
		return nil, trace.Wrap(err)
	}
	u, err := lookupUser("", C.uid_t(uid), false)
	if err != nil {
		return nil, trace.Wrap(err)
	}
	if u == nil {
		return nil, osuser.UnknownUserIdError(int(uid))
	}
	return u, nil
}

// LookupGroup 按组名查找。
func LookupGroup(name string) (*osuser.Group, error) {
	g, err := lookupGroup(name, 0, true)
	if err != nil {
		return nil, trace.Wrap(err)
	}
	if g == nil {
		return nil, osuser.UnknownGroupError(name)
	}
	return g, nil
}

// LookupGroupId 按 gid 查找。
func LookupGroupId(id string) (*osuser.Group, error) {
	gid, err := strconv.ParseUint(id, 10, 32)
	if err != nil {
		return nil, trace.Wrap(err)
	}
	g, err := lookupGroup("", C.gid_t(gid), false)
	if err != nil {
		return nil, trace.Wrap(err)
	}
	if g == nil {
		return nil, osuser.UnknownGroupIdError(id)
	}
	return g, nil
}

// Current 返回当前进程的用户。
func Current() (*osuser.User, error) {
	uid := os.Getuid()
	if u, err := LookupId(strconv.Itoa(uid)); err == nil {
		return u, nil
	}

	// Bionic 对 uid 的合成是有范围限制的(低于 AID_APP_START 且不在 AID 表里
	// 的 uid 查不到)。这种情况下不该整个失败 —— 上层大量代码都调 Current,
	// 用环境变量凑一个够用的条目比让 agent 起不来强。
	u := &osuser.User{
		Uid:      strconv.Itoa(uid),
		Gid:      strconv.Itoa(os.Getgid()),
		Username: os.Getenv("USER"),
		HomeDir:  os.Getenv("HOME"),
	}
	if u.Username == "" {
		u.Username = "u" + strconv.Itoa(uid)
	}
	if u.HomeDir == "" {
		if prefix := os.Getenv("PREFIX"); prefix != "" {
			u.HomeDir = filepath.Join(filepath.Dir(prefix), "home")
		} else {
			u.HomeDir = "/data"
		}
	}
	u.Name = u.Username
	return u, nil
}

// GroupIds 返回用户所属的组。
//
// ⚠️ Bionic 的 getgrouplist 是个 stub —— AOSP 的注释原话是
// "All users are in just one group, the one passed in", 它不查任何数据库,
// 只把传进去的 gid 原样回吐。所以对**非当前用户**只能如实返回主组。
//
// 对当前进程自己, getgroups(2) 能拿到内核里真实的补充组(Android 上这些组
// 是 zygote/adbd 在降权时设的, 不来自任何 passwd 数据库), 那才是准确答案。
func GroupIds(u *osuser.User) ([]string, error) {
	if u == nil {
		return nil, trace.BadParameter("user cannot be nil")
	}

	if u.Uid != strconv.Itoa(os.Getuid()) {
		return []string{u.Gid}, nil
	}

	gids, err := syscall.Getgroups()
	if err != nil {
		return []string{u.Gid}, nil
	}

	out := make([]string, 0, len(gids)+1)
	seen := make(map[int]bool, len(gids)+1)
	if primary, err := strconv.Atoi(u.Gid); err == nil {
		out = append(out, u.Gid)
		seen[primary] = true
	}
	for _, g := range gids {
		if seen[g] {
			continue
		}
		seen[g] = true
		out = append(out, strconv.Itoa(g))
	}
	return out, nil
}

// GetHostUsers 在 Android 上无法实现。
//
// 枚举需要 setpwent/getpwent/endpwent, **Bionic 没有这三个函数** ——
// Android 上不存在可遍历的 passwd 数据库, "列出所有用户"这个概念不成立。
// 返回 ErrUnsupportedPlatform 是上游约定的降级信号, 调用方(host_users
// 自动创建、authorized_keys 扫描)会据此跳过, 而不是报错。
func GetHostUsers() ([]osuser.User, error) {
	return nil, trace.Wrap(ErrUnsupportedPlatform)
}
EOF
  note "  已生成 user_android.go (cgo 直调 Bionic getpwnam_r/getgrnam_r)"
  TOUCHED="$TOUCHED $pkg"
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
#
# ⚠️ 这里曾经踩过一个大坑, 记下来免得重蹈:
#
# 最初的做法是把整个包让给上游的 user_forward.go(转发给 os/user)。
# 那是错的。**Go 标准库的 os/user 在 GOOS=android 下是硬编码的桩** ——
# lookup_android.go 的约束是无条件的 `//go:build android`, 四个 Lookup*
# 一律 `return errors.New("user: Lookup not implemented on android")`;
# 而 cgo 实现 cgo_lookup_unix.go 的约束带 `&& !android`, 开着 cgo 也选不中。
#
# 后果是 `tsh ssh` 必然失败:
#   session/reexec/reexec.go 的 hostuser.Lookup(c.Login) 拿到桩错误
#   → "Failed to launch: user: Lookup not implemented on android"
#   → 退出码 255
# 也就是说, 为了绕开"不能枚举", 把"单用户查询"一起赔了进去。
#
# 正确的做法是只让 GetHostUsers 一个函数走兜底, 其余五个自己用 cgo 实现:
#   getpwnam_r / getpwuid_r   Bionic 一直有, 连 __INTRODUCED_IN 都没标
#   getgrnam_r / getgrgid_r   Bionic 24+ (我们本来就按 API 24 编)
# Bionic 会为 Android 的 uid **合成** passwd 条目(u0_aNNN → uid/gid 同值),
# 所以单个用户的查询本来就是可用的, 只是 Go 没去调它。
# ══════════════════════════════════════════════════════════════
if [ "$TARGET" = android ]; then
  # 上游在 v18.10.x 中途把系统用户枚举挪了位置, 两种布局都要支持:
  #   新(≥18.10.7): session/host/user/                  user_linux_cgo.go
  #   旧(≤18.10.0): lib/secretsscanner/authorizedkeys/  users_list_linux.go
  UPKG_NEW="$SRC/session/host/user"
  UPKG_OLD="$SRC/lib/secretsscanner/authorizedkeys"

  if [ -f "$UPKG_NEW/user_linux_cgo.go" ]; then
    note "[host/user] 新布局(session/host/user), 生成 android 专用 cgo 实现"
    # 整个 linux+cgo 实现对 android 让路(它有 setpwent/getpwent/endpwent),
    # 但**不是**让给 user_forward.go —— 那条路会掉进 Go 的 android 桩。
    retag "$UPKG_NEW/user_linux_cgo.go" \
          '//go:build linux && cgo' \
          '//go:build linux && cgo && !android'
    # user_forward.go / user_other.go 的约束一个字都不改:
    # android 由下面新增的 user_android.go 独占, 不走这两条路。
    emit_android_hostuser "$UPKG_NEW"

  elif [ -f "$UPKG_OLD/users_list_linux.go" ]; then
    note "[authorizedkeys] 旧布局(lib/secretsscanner/authorizedkeys), 让 android 走兜底"
    # ⚠️ users_list_linux.go 与新布局不同: 它**没有** //go:build,
    #    只靠 _linux.go 文件名后缀约束, 所以是插入而非改写。
    addtag "$UPKG_OLD/users_list_linux.go" '//go:build !android'
    retag  "$UPKG_OLD/users_list_other.go" \
           '//go:build !darwin && !linux' \
           '//go:build (!darwin && !linux) || android'

    # ⚠️⚠️ 旧布局上 SSH 会话依然是坏的, 这里必须说清楚。
    #
    # 上面那两行只解决了"能编过", 解决不了"能开会话"。旧版没有
    # session/host/user 这个抽象层 —— session/reexec/reexec.go 直接
    # `import "os/user"` 然后调 user.Lookup(c.Login)。那是 Go 标准库,
    # 在 GOOS=android 下是硬编码的桩, **我们无处注入**:
    #   session/reexec/reexec.go:408  localUser, err := user.Lookup(c.Login)
    #   session/reexec/reexec.go:684  同上
    # 结果就是 `tsh ssh` 报 "Failed to launch: user: Lookup not
    # implemented on android" 并以 255 退出。
    #
    # 要在旧版上修, 只能去改 reexec.go 的 import 和调用点(改动面大且脆),
    # 或者干脆用 ≥v18.10.7。既然新版已经把这层抽出来了, 就不在旧版上
    # 堆一份注定难维护的补丁。
    #
    # 这里刻意**只警告不失败**: agent 本身(不开会话)在旧版上仍可用,
    # 而且这条路径也覆盖 tsh —— tsh 根本不碰 reexec。
    note "⚠️ 旧布局: android 的 SSH 会话不可用(reexec 直接依赖 os/user 桩)"
    note "⚠️ 想在 Termux 上开 SSH 会话, 请构建 v18.10.7 或更新的版本"

  else
    die "两种已知布局都找不到系统用户枚举的实现:
        新: $UPKG_NEW/user_linux_cgo.go        (v18.10.7 及以后)
        旧: $UPKG_OLD/users_list_linux.go      (v18.10.0 及以前)
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

  # ════════════════════════════════════════════════════════════
  # 4. 仅 android: session/shell
  #
  # shell_unix.go 用 getpwnam_r 读 pw_shell。Bionic 有这个函数, 能编也能跑,
  # **但返回值没用**: Bionic 为 app uid 合成的 pw_shell 恒为 "/bin/sh",
  # 而 Termux 里根本没有 /bin —— 它的 shell 在 $PREFIX/bin/。
  # 拿这个值去 exec 必然 ENOENT, 会话开不起来。
  #
  # 所以 android 走一个专用实现: 认 $SHELL, 再退回 $PREFIX/bin 下常见的
  # shell, 最后才是上游的 DefaultShell。
  # ════════════════════════════════════════════════════════════
  SPKG="$SRC/session/shell"
  if [ -f "$SPKG/shell_unix.go" ]; then
    note "[shell] 让 android 用 Termux 的 shell 而不是 Bionic 合成的 /bin/sh"
    retag "$SPKG/shell_unix.go" \
          '//go:build !windows' \
          '//go:build !windows && !android'

    if [ -f "$SPKG/shell_android.go" ]; then
      note "  shell_android.go: 已存在, 跳过"
    else
      cat > "$SPKG/shell_android.go" <<'EOF'
//go:build android

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

package shell

import (
	"os"
	"path/filepath"

	"github.com/gravitational/trace"
)

// getLoginShell 在 Android 上不查 passwd, 因为查了也没用。
//
// Bionic 为 app uid **合成** passwd 条目, 其中 pw_shell 是写死的 "/bin/sh"
// (见 AOSP libc/bionic/grp_pwd.cpp 的 app_id_to_passwd)。Termux 里没有 /bin,
// shell 装在 $PREFIX/bin/ 下, 所以那个路径 exec 必然失败。
//
// 这里按可靠性排序去找:
//  1. $SHELL —— Termux 会设置它, 也尊重用户自己换过的 shell
//  2. $PREFIX/bin 下的常见 shell —— $SHELL 缺失时的兜底
//  3. 交给调用方用 DefaultShell(返回 NotFound 即可, GetLoginShell 会兜)
func getLoginShell(username string) (string, error) {
	if sh := os.Getenv("SHELL"); sh != "" {
		if isExecutable(sh) {
			return sh, nil
		}
	}

	if prefix := os.Getenv("PREFIX"); prefix != "" {
		for _, name := range []string{"bash", "zsh", "fish", "sh"} {
			candidate := filepath.Join(prefix, "bin", name)
			if isExecutable(candidate) {
				return candidate, nil
			}
		}
	}

	return "", trace.NotFound("no usable shell found for %v", username)
}

// isExecutable 判断路径是否指向一个可执行的普通文件。
func isExecutable(path string) bool {
	fi, err := os.Stat(path)
	if err != nil || fi.IsDir() {
		return false
	}
	return fi.Mode().Perm()&0o111 != 0
}
EOF
      note "  已生成 shell_android.go"
      TOUCHED="$TOUCHED $SPKG"
    fi
  else
    die "找不到 $SPKG/shell_unix.go —— 上游挪走了 shell 包"
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
