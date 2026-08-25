# teleport-static-builds

给官方包跑不了的平台构建 Teleport agent。

本仓库**不存放上游源码**，每次构建时按 tag 现拉 `gravitational/teleport`，
打一个很小的补丁，然后编译、发 Release。

产物分两类：Linux 目标是**完全静态**的（musl，不依赖目标系统 libc）；
Termux 目标**刻意是动态**的（链接 Android Bionic）—— 原因见下面的 Termux 一节。

## 解决的是什么问题

官方 Linux 包是 CGO 动态链接 glibc 的：

```
$ ldd teleport
        libresolv.so.2 => /lib64/libresolv.so.2
        libdl.so.2 => /lib64/libdl.so.2
        ...
$ file teleport
        ELF 64-bit LSB executable, x86-64, dynamically linked,
        interpreter /lib64/ld-linux-x86-64.so.2
```

OpenWrt 只有 musl（`/lib/ld-musl-x86_64.so.1`），Android/Termux 只有 Bionic，
两者都没有 glibc，也默认不装 gcompat —— 官方包直接起不来。

## 产物

每个 Release 对应一个上游 tag：

| 文件 | 链接方式 | 平台 |
|---|---|---|
| `teleport-<ver>-linux-amd64-static.tar.gz` | 静态 musl | x86_64 OpenWrt / 软路由 / 任意 x86_64 Linux |
| `teleport-<ver>-linux-arm64-static.tar.gz` | 静态 musl | arm64 OpenWrt / 树莓派 / Termux 里的 proot-distro |
| `teleport-<ver>-android-arm64.tar.gz` | **动态 Bionic** | Termux（原生，非 proot） |
| `SHA256SUMS` | | 校验 |

两个 `-static` 产物 `readelf -d` 没有任何 `NEEDED` 条目，不依赖目标系统的 libc。
`android-arm64` 则**应该**有 `NEEDED [libc.so]`，那是 Bionic，不是构建失误。

**只含 `teleport`（agent），不含 `tsh` / `tctl`。** 客户端工具请用官方包。

体积约 357MB —— 这是 Teleport 本身就有的大小，不是静态链接造成的
（实测静态 musl 比官方 glibc 动态版只大 1.3MB，+0.35%）。

## 构建方式

Actions → `build` → Run workflow。

| 输入 | 默认 | 说明 |
|---|---|---|
| `upstream_ref` | 空 | 上游 tag。留空则自动取最新正式版（忽略 rc/alpha） |
| `publish` | true | 编译成功后发 Release |
| `force` | false | 同名 Release 已存在时删掉重发 |
| `include_termux` | true | 同时构建 Termux 目标。Termux 目标较新，出问题时可关掉它单独发静态版 |

两个架构分别在**各自的原生 runner** 上用原生 `musl-gcc` 编译
（amd64 用 `ubuntu-latest`，arm64 用 GitHub 的免费 arm64 runner `ubuntu-24.04-arm`，
仅 public 仓库可用）。**不做交叉编译，不需要 zig。**

想每周自动跟进上游，把 `.github/workflows/build.yml` 里的 `schedule` 两行取消注释。
默认关着是刻意的：定时任务会在无人看管时对外发布 Release，那应该是一个明确的选择。

## 补丁：只改一个包

上游唯一真正 glibc 专有的地方，是 `lib/inventory/metadata/metadata_linux.go` 里的
`#include <gnu/libc-version.h>` —— 这个头文件 glibc 独有，任何 musl 工具链都变不出来。

`scripts/apply-nonglibc-patch.sh` 把它拆成两个带 build tag 的文件：

| 文件 | build tag | 内容 |
|---|---|---|
| `metadata_linux_glibc.go` | `linux && !musl && !android` | 原 cgo 实现，一字不改 |
| `metadata_linux_nonglibc.go` | `(linux && musl) \|\| android` | 纯 Go，返回空串 |

**普通 glibc Linux 构建（不带 `-tags musl`、非 android）行为与上游完全一致。**

⚠️ `!android` 那半边是必需的：**Go 的 `GOOS=android` 同时满足 `linux` build tag**，
不排除的话 Android 构建会去找 Bionic 根本没有的 `gnu/libc-version.h`。
反过来 `|| android` 让 Android 上**不需要传任何 tag** 就选中正确的变体 ——
少传一个 tag 不该变成一次编译失败。

### 为什么不直接 `CGO_ENABLED=0`

实测（v18.10.0）关掉 CGO 会打断 5 个包：

| 包 | 症状 |
|---|---|
| `lib/system` | 整包被 build 约束排除（`signal.go` 是该目录唯一的非 Windows 文件，且是 cgo） |
| `lib/inventory/metadata` | `fetchOSVersion` / `fetchGlibcVersion` undefined |
| `session/uacc` | `UtmpBackend` undefined，外加 `sqlite3.ErrReadonly` undefined（来自 `mattn/go-sqlite3` 的非 cgo 桩） |
| `session/shell` | `getLoginShell` undefined |
| `lib/secretsscanner/authorizedkeys` | `getHostUsers` undefined |

要补 5 个包（其中一个还牵扯第三方桩实现缺常量），代价远大于收益。

保留 `CGO_ENABLED=1` 换 `musl-gcc` 后，这 5 个包里除 metadata 外用的是
`<signal.h>` / `<utmp.h>` / `<pwd.h>` —— **musl 全都提供，一行都不用改就编过**。

### 上游改了会怎样

补丁脚本在动手前会断言上游文件的形状（三条 grep）。任意一条不成立就**立刻失败并打印原因**，
不会静默产出一个坏二进制。这时需要人工看过上游改动，再决定怎么调整。

## 安装 —— OpenWrt

```sh
# 1. 放在外挂盘上, 别放 /overlay(空间小, 且固件升级会清)
mkdir -p /mnt/DISK/apps/teleport/bin /mnt/DISK/apps/teleport/data
chmod 700 /mnt/DISK/apps/teleport/data
cd /mnt/DISK/apps/teleport

# 2. 下载解包(把 URL 换成 Release 里的)
curl -fSL -o t.tar.gz "https://github.com/noir017/teleport-static-builds/releases/download/vX.Y.Z/teleport-X.Y.Z-linux-amd64-static.tar.gz"
tar xzf t.tar.gz --strip-components=1 -C bin teleport-X.Y.Z-linux-amd64-static/teleport
chmod 755 bin/teleport && rm t.tar.gz

# 3. 配置(见 contrib/openwrt/teleport.yaml.example)
cp /path/to/teleport.yaml.example teleport.yaml && chmod 600 teleport.yaml
printf '%s' '<join token>' > token && chmod 600 token
./bin/teleport configure --test teleport.yaml    # 语法自检

# 4. procd 服务
cp /path/to/contrib/openwrt/teleport.init /etc/init.d/teleport
chmod 755 /etc/init.d/teleport
/etc/init.d/teleport enable && /etc/init.d/teleport start
```

### OpenWrt 上的几个坑

- **固件升级保护**：二进制在外挂盘上不受 sysupgrade 影响，**但 `/etc/init.d/teleport`
  和 `/etc/rc.d/S95teleport` 在 overlay 里会被清掉**，必须加进 `/etc/sysupgrade.conf`。
- **`dockerd` 默认 `START=99`，比本服务的 `95` 晚。** 如果控制面是同机的容器，
  开机时 agent 会先起、连不上、然后靠重试自愈（`max_retry_period` 约 4 分钟）。
  节点开机后会短暂离线，属正常。
- **`nodename` 必须全小写。** 带大写字母时原生 `ssh` + `ProxyCommand` 会因为 OpenSSH
  把 `%h` 小写化而报 `offline or does not exist`，与真实原因毫无关系。
- **日志没有轮转**。配置示例里写的是文件输出，长期跑要自己加。
- **`who` / utmp**：musl 的 utmp 函数是空桩，`session/uacc` 的会话记录会静默落空。
  但 OpenWrt 上根本没有 `/var/run/utmp`，也不装 `who`，所以这个差异**没有实际影响**，
  别当 bug 查。
- 解包和算 sha256 在路由器 CPU 上要几十秒，ssh 前台命令容易超时，用 `nohup` 或后台跑。

### 传输技巧

357MB 从本地中继到路由器可能极慢。**让目标机自己从 GitHub 拉**（Release 是免鉴权的，
直接 `curl` 即可）—— 实测比经由一条慢链路中继快一到两个数量级。

## Termux（Android）

**已在 redroid (Android 13 / arm64) 容器里实测启动成功，未在真机 Termux 里验证。**
完整说明见 [`contrib/termux/README.md`](contrib/termux/README.md)，那份也会一并打进 Termux 的 tarball。

### 为什么它不是静态的

我最初以为 arm64 静态产物可以直接在 Termux 里跑 —— 静态二进制不碰目标系统的 libc，
内核也还是 Linux。**这个判断是错的**，有两个硬性原因：

1. **Android 没有 `/etc/passwd`。** 静态 musl 的 `getpwnam` / `getpwuid` 只会读那个文件，
   返回 NULL；Bionic 则会为 Android 的 uid **合成** passwd 条目。
   Teleport 的 `ssh_service` 要解析登录用户的 shell 和 home，拿不到就开不了会话。
2. **Android 没有 `/etc/resolv.conf`。** DNS 要经 Bionic 的 resolver 走 netd，
   静态二进制无从解析域名 —— 连代理都连不上。

所以 Termux 目标是 `GOOS=android` + NDK clang，动态链接 `/system/lib64` 里的 Bionic。

### 构建上的两个约束

- **必须在 x86_64 runner 上交叉编译。** NDK 的预构建工具链只有 `linux-x86_64` 一份，
  所以这个 job 不能像静态目标那样用原生 arm64 runner。
- **runner 上跑不了冒烟测试。** 静态目标能在同架构 runner 上直接 `./teleport version`，
  Android 二进制不行。CI 只能验证「解释器是 `/system/bin/linker64`、链接的是 Bionic 的
  `libc.so`、没有误链 glibc」。**真机验证是必需的，CI 绿灯不等于能跑。**

### Android 版的功能妥协

Bionic 比 musl 缺得多。除了 `metadata`，还有两个包必须走上游的兜底实现：

| 包 | Bionic 缺什么 | 后果 |
|---|---|---|
| `session/host/user` | `setpwent`/`getpwent`/`endpwent` | **host_users 自动创建不可用** |
| `session/uacc` | `updwtmp`/`getutline` | 会话不写 utmp/wtmp（Android 上无消费方） |

单个用户查询是正常的（Bionic 的 `getpwnam`/`getpwuid` 会为 Android uid 合成条目），
不能做的只是"枚举所有用户"—— 那在 Android 上本来就没有意义。

所以 Termux 目标的补丁面比 musl 大：musl 只改 1 个包，android 要改 3 个。
补丁脚本按目标区分（`apply-nonglibc-patch.sh src musl|android`），
android 那两个包的改动**不会影响**已经跑通的静态构建。

### 上游挪过位置，两种布局都支持

系统用户枚举的实现在 v18.10.x 中途被重构过，补丁脚本按实际存在的文件自动选路：

| 上游版本 | 位置 |
|---|---|
| ≥ v18.10.7 | `session/host/user/user_linux_cgo.go` |
| ≤ v18.10.0 | `lib/secretsscanner/authorizedkeys/users_list_linux.go` |

两边都有 `_other.go` 兜底，改法同构。两种布局都实测过。
再往前的版本（v17 及更早）没试过 —— 遇到未知布局脚本会带着两条路径名报错退出，
不会静默产出坏二进制。

**这只影响 Termux 目标。** 静态构建（musl）不碰这两个包，任何版本都不受影响。

### 容器实测结果（redroid, Android 13 / arm64-v8a / SDK 33）

CI 之外做过一轮真实执行，`adb push` 到 `/data/local/tmp` 后：

- `./teleport version` 退出码 0；`NEEDED = liblog.so libdl.so libc.so`，无任何 glibc 依赖。
- `teleport start` 指向假 proxy，一路走到 `/webapi/find returned HTTP 404` ——
  data_dir 创建、host UUID 生成、**DNS 解析**、TLS 握手、ALPN upgrade 全部正常。
- **SQLite 后端运行正常**（`[SQLITE] Connected to database ... proc/sqlite.db`）。
  go-sqlite3 的 C amalgamation 在 NDK 下能编也能跑，这是之前唯一没法预先验证的未知项。
- 启动时打一行 `Disabling host user creation as this feature is only available on Linux`，
  正是上面那张妥协表第一行的预期表现 —— **是降级，不是崩溃**。

### 已知风险（redroid 覆盖不到）

- **SELinux**：redroid 里 `getenforce` 是 **Disabled**，真机是 Enforcing。
  `untrusted_app` 域对 PTY 分配、`/proc`(hidepid) 的限制完全没测到。
- **运行身份不同**：`adb shell` 是 uid 2000（`shell` 域），比 Termux 的 `u0_aNNN`
  （`untrusted_app` 域）权限高。app 沙箱内、从 `$PREFIX` 执行的行为没覆盖。
- **真实 SSH 会话**：没接入真集群，PTY 分配和会话录制都没测过。
- Android 的 `exec` 限制（Termux prefix 可执行；`/sdcard` 带 `noexec` 必然失败）
- Android 杀后台：需要 `termux-wake-lock` **加上**关闭电池优化，缺一不可
- 能登录的账号只有 Termux 自己那个（Bionic 合成的 `u0_aNNN`），没有 root，无法切用户

### 想省事就用 proot-distro

在 Termux 里跑 Linux rootfs，然后用 **`linux-arm64-static`** 那个产物 —— rootfs 里
`/etc/passwd` 和 `/etc/resolv.conf` 都齐，上面这些坑一个都不用踩。
代价是 proot 的 ptrace 模拟有 syscall 开销。

## 许可

本仓库的脚本与 workflow 随仓库许可。
**构建产物是 Teleport 的衍生物，版权与许可归 Gravitational, Inc.，遵循 AGPL-3.0。**
补丁脚本生成的源文件保留上游的 AGPL 头。
