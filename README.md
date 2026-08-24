# teleport-static-builds

给官方包跑不了的平台构建**完全静态链接**的 Teleport agent。

本仓库**不存放上游源码**，每次构建时按 tag 现拉 `gravitational/teleport`，
打一个很小的补丁，然后编译、发 Release。

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

本仓库的产物 `readelf -d` 没有任何 `NEEDED` 条目，不依赖目标系统的 libc。

## 产物

每个 Release 对应一个上游 tag，含两个架构：

| 文件 | 平台 |
|---|---|
| `teleport-<ver>-linux-amd64-static.tar.gz` | x86_64 OpenWrt / 软路由 / 任意 x86_64 Linux |
| `teleport-<ver>-linux-arm64-static.tar.gz` | arm64 OpenWrt / 树莓派 / **Termux（见下）** |
| `SHA256SUMS` | 校验 |

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

两个架构分别在**各自的原生 runner** 上用原生 `musl-gcc` 编译
（amd64 用 `ubuntu-latest`，arm64 用 GitHub 的免费 arm64 runner `ubuntu-24.04-arm`，
仅 public 仓库可用）。**不做交叉编译，不需要 zig。**

想每周自动跟进上游，把 `.github/workflows/build.yml` 里的 `schedule` 两行取消注释。
默认关着是刻意的：定时任务会在无人看管时对外发布 Release，那应该是一个明确的选择。

## 补丁：只改一个包

上游唯一真正 glibc 专有的地方，是 `lib/inventory/metadata/metadata_linux.go` 里的
`#include <gnu/libc-version.h>` —— 这个头文件 glibc 独有，任何 musl 工具链都变不出来。

`scripts/apply-musl-patch.sh` 把它拆成两个带 build tag 的文件：

| 文件 | build tag | 内容 |
|---|---|---|
| `metadata_linux_glibc.go` | `linux && !musl` | 原 cgo 实现，一字不改 |
| `metadata_linux_musl.go` | `linux && musl` | 纯 Go，返回空串 |

**不带 `-tags musl` 构建时行为与上游完全一致。**

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

## Termux（Android）—— 未实测

arm64 产物**理论上**可以直接在 Termux 里跑：完全静态链接的二进制不碰目标系统的 libc，
内核仍是 Linux，所以不需要为 Bionic 单独构建。

尚未验证的风险：

- Android 的 `exec` 限制（Termux 自己的 prefix 目录可执行，大概率没问题）
- Teleport 要建 PTY、读 `/proc`，Android 的 SELinux 策略可能拦
- Termux 没有 procd/systemd，自启要用 `termux-services` 或 `nohup`

试通了欢迎回来补一节。

## 许可

本仓库的脚本与 workflow 随仓库许可。
**构建产物是 Teleport 的衍生物，版权与许可归 Gravitational, Inc.，遵循 AGPL-3.0。**
补丁脚本生成的源文件保留上游的 AGPL 头。
