# Termux 上运行 Teleport agent

**状态：已在 redroid (Android 13 / arm64) 容器里实测启动成功，但未在真机 Termux 里验证。**
两者的差距不小，下面的风险一节请先读完。

## 这个产物和另外两个不一样

| 产物 | 链接方式 | 目标 |
|---|---|---|
| `linux-*-static` | 完全静态（musl） | OpenWrt 等无 glibc 的 Linux |
| `android-arm64` | **动态链接 Bionic** | Termux |

Termux 这份**刻意不是静态的**。Android 上必须链接 Bionic，有两个硬性原因：

1. **Android 没有 `/etc/passwd`。** 静态 musl 的 `getpwnam` / `getpwuid` 只会去读那个文件，
   拿不到就返回 NULL；而 Bionic 会为 Android 的 uid **合成** passwd 条目
   （形如 `u0_a123`）。Teleport 的 `ssh_service` 要解析登录用户的 shell 和 home，
   拿不到就开不了会话。
2. **Android 没有 `/etc/resolv.conf`。** DNS 要经由 Bionic 的 resolver 走 netd，
   静态二进制无从解析域名 —— 连不上代理。

所以 `readelf -d` 会看到 `NEEDED [libc.so]`，这是**正确的**，不是构建失误。

## 为了能编过，Android 版做了两处功能性妥协

Bionic 比 musl 缺得多，有两个包必须走上游的兜底实现。这不是构建细节，
是你会实际撞到的行为差异：

| 包 | Bionic 缺什么 | 后果 |
|---|---|---|
| `session/host/user` | `setpwent`/`getpwent`/`endpwent` | **主机用户自动创建（host_users）不可用**。Android 没有可枚举的 passwd 数据库 |
| `session/uacc` | `updwtmp`/`getutline` | 会话不写 utmp/wtmp。Android 上本来就没有消费方，无实际影响 |

注意 **单个用户的查询是正常的** —— Bionic 有 `getpwnam`/`getpwuid`，会为 Android
的 uid 合成条目。不能做的只是"列出所有用户"，而那在 Android 上本来就没有意义。

所以 Termux 上的 Teleport 是一个**只能以 Termux 自身账号登录的 SSH 节点**，
不能做用户provisioning。对"把手机接进集群"这个用途来说够用。

## 一条龙脚本（推荐）

同目录的 [`termux-agent.sh`](termux-agent.sh) 把下面所有手动步骤都包了，
从干净的 Termux 开始只需要两步。

### 第 1 步：在手机上敲这一次

干净的 Termux 连 `curl` 都没有，所以这一步躲不掉要用手机键盘：

```sh
pkg install -y curl && \
curl -fsSL -o ~/termux-agent.sh \
  https://raw.githubusercontent.com/noir017/teleport-static-builds/main/contrib/termux/termux-agent.sh && \
bash ~/termux-agent.sh ssh
```

`ssh` 子命令装好 sshd（监听 **8022**）并打印出连接命令。
把电脑的公钥当参数传进去就走密钥登录，不传则让你设密码：

```sh
bash ~/termux-agent.sh ssh "$(cat ~/.ssh/id_ed25519.pub)"   # 电脑上的公钥内容
```

### 第 2 步：从电脑 ssh 进去，剩下的一条命令

```sh
ssh u0_aNNN@<手机IP> -p 8022

bash ~/termux-agent.sh all \
  --proxy teleport.example.com:443 \
  --token <tctl tokens add --type=node 给的 token>
```

`all` = `install` → `configure` → `verify` → `service` → `boot`。

### 单步子命令

| 子命令 | 做什么 |
|---|---|
| `ssh [公钥]` | 装 sshd、写 authorized_keys（幂等）、打印连接命令 |
| `install` | 查架构/API/空间 → 下载 → **校验 sha256** → 解包 → `teleport version` |
| `configure` | 生成 `~/.teleport/teleport.yaml` 和 600 权限的 token 文件 |
| `verify` | 试启动 45 秒，判断到底是"没加入集群"还是"根本没起来" |
| `service` | 写 runit service + 持 wake lock + 提示关电池优化 |
| `boot` | 写 `~/.termux/boot/00-teleport`（需 Termux:Boot） |
| `status` / `logs` / `uninstall` | 状态、跟日志、卸载 |

环境变量也可以：`TELEPORT_VERSION` `TELEPORT_PROXY` `TELEPORT_TOKEN`
`TELEPORT_NODENAME` `TERMUX_SSH_PUBKEY`。

### 脚本刻意做的几件事

- **校验两次哈希**：压缩包一次，解包后的二进制再一次。对不上直接中止，
  不留半个坏文件在 `$PREFIX/opt`。
- **`install` 的最后一步是真的执行 `teleport version`**。这是最关键的一道门，
  不过就不往下走 —— 后面所有步骤都建立在"这台设备跑得动这个二进制"上。
- **`verify` 会区分两种失败**：进程起来了但没加入集群（token 过期 / 代理地址错 /
  控制面没发布 3024），和启动阶段就崩。这两种的排查方向完全不同。
- **看到 `Disabling host user creation` 会明说这是正常的**，免得当 bug 查。
- **不碰 `$PREFIX` 以外的东西**，`uninstall` 也不会替你删 token 和主机身份。

下面是手动步骤，脚本做的就是这些。

## 手动安装

```sh
pkg install -y curl tar

mkdir -p "$PREFIX/opt/teleport" "$HOME/.teleport"
cd "$PREFIX/opt/teleport"

# 换成 Release 里的实际版本
V=18.10.0
B=https://github.com/noir017/teleport-static-builds/releases/download/v$V
curl -fSL -o t.tar.gz "$B/teleport-$V-android-arm64.tar.gz"
curl -fsSL -o SHA256SUMS "$B/SHA256SUMS"
grep -F "  teleport-$V-android-arm64.tar.gz" SHA256SUMS | sha256sum -c -   # 必须 OK

tar xzf t.tar.gz --strip-components=1
chmod 755 teleport && rm t.tar.gz SHA256SUMS

./teleport version        # 第一道验证: 能不能跑起来
```

`teleport version` 跑通就说明二进制在这台设备上可执行，是最重要的一步。

## 配置

```yaml
version: v3
teleport:
  nodename: my-phone            # 必须全小写
  data_dir: /data/data/com.termux/files/home/.teleport
  proxy_server: teleport.example.com:443
  join_params:
    method: token
    token_name: /data/data/com.termux/files/home/.teleport-token
  log:
    output: stderr
    severity: INFO

auth_service:  { enabled: "no" }
proxy_service: { enabled: "no" }

ssh_service:
  enabled: "yes"
  labels:
    os: android
    kind: termux
```

⚠️ `data_dir` 必须在 Termux 自己的目录里。`/var/lib` 之类在 Android 上不可写。

⚠️ **能登录的账号只有 Termux 自己那个**（Bionic 合成的 `u0_aNNN`）。
用 `id -un` 查出实际名字，让 Teleport 角色的 `logins` 里包含它。
Android 上没有别的用户可切，也没有 root。

## 自启

Termux 没有 systemd / procd。用 `termux-services`（runit）：

```sh
pkg install termux-services
mkdir -p "$PREFIX/var/service/teleport"
cat > "$PREFIX/var/service/teleport/run" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
exec 2>&1
exec /data/data/com.termux/files/usr/opt/teleport/teleport start \
  --config=/data/data/com.termux/files/home/teleport.yaml
EOF
chmod +x "$PREFIX/var/service/teleport/run"
sv-enable teleport
sv status teleport
```

**Android 会杀后台进程。** 要让它活着，两件事都得做：

```sh
termux-wake-lock          # 持有 wake lock
```

以及在系统设置里把 Termux 的电池优化关掉（各家 ROM 位置不同，
国产 ROM 通常还要额外加"自启动"白名单）。这一条不做，agent 迟早离线。

## 已实测（redroid，Android 13 / arm64-v8a / SDK 33）

用 `adb push` 到 `/data/local/tmp` 后：

- `./teleport version` 正常返回，退出码 0。
- `readelf` 层面确认 `NEEDED = liblog.so libdl.so libc.so`、interpreter `/system/bin/linker64`，
  没有任何 glibc 依赖。
- `teleport start` 指向一个假 proxy，一路走到 `/webapi/find returned HTTP 404` ——
  说明 **data_dir 创建、host UUID 生成、DNS 解析、TLS 握手、ALPN upgrade 全部正常**。
  DNS 能通尤其关键，它证明 Bionic resolver 那条路是活的。
- **SQLite 后端运行正常**（`[SQLITE] Connected to database ... proc/sqlite.db`，pragma 读回成功）。
  go-sqlite3 的 C amalgamation 在 NDK 下能编也能跑。
- 启动时会打一行 `Disabling host user creation as this feature is only available on Linux`，
  这正是上面那张表的第一行的预期表现 —— **是降级，不是崩溃**。

## redroid 覆盖不到的三件事

这三条仍然是未知数，别把上面的"实测通过"当成真机结论：

1. **SELinux**：redroid 里 `getenforce` 是 **Disabled**。真机是 Enforcing，
   `untrusted_app` 域对 PTY 分配、`/proc`(hidepid) 的限制完全没被测到。
2. **运行身份不同**：`adb shell` 是 uid 2000（`shell` 域），**比 Termux 的 `u0_aNNN`
   （`untrusted_app` 域）权限高**。从 `$PREFIX` 执行、app 沙箱内的行为没覆盖。
3. **真实 SSH 会话**：没接入真集群，PTY 分配、会话录制、`ssh_service` 端到端都没测过。
   接进集群后第一件事就是开一个会话试试。

## 其余已知风险

- **exec 限制**：Termux 的 prefix 目录可执行，理论上没问题；但从 `/sdcard`
  之类的位置执行必然失败（那些挂载点带 `noexec`）。
- **utmp**：Bionic 的 utmp 是空桩，`session/uacc` 的会话记录会静默落空。
  Android 上本来就没有 utmp 消费方，预计无实际影响。
- **体积**：解包后约 450MB。Android 内部存储紧张的设备要留意。
- **Termux 版本**：必须用 F-Droid 或 GitHub 的官方版。
  Google Play 上那个旧版 Termux 已停止维护，targetSdk 更高，exec 行为不同。

## 另一条路：proot-distro

不想碰这些 Android 特有的坑，可以在 Termux 里跑一个 Linux rootfs：

```sh
pkg install proot-distro
proot-distro install debian
proot-distro login debian
```

进去之后用 **`linux-arm64-static`** 那个产物（不是本产物），因为 rootfs 里
`/etc/passwd` 和 `/etc/resolv.conf` 都是齐的，静态二进制反而最省事。

代价：proot 是用户态 ptrace 模拟，syscall 开销显著，且多一层进程。
但胜在环境正常、坑少。
