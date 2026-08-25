# Termux 上运行 Teleport agent

**状态：已构建，未在真机验证。** 下面的风险一节请先读完。

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

## 安装

```sh
pkg install curl tar

mkdir -p "$PREFIX/opt/teleport" "$HOME/.teleport"
cd "$PREFIX/opt/teleport"

# 换成 Release 里的实际 URL
curl -fSL -o t.tar.gz "https://github.com/noir017/teleport-static-builds/releases/download/vX.Y.Z/teleport-X.Y.Z-android-arm64.tar.gz"
tar xzf t.tar.gz --strip-components=1
chmod 755 teleport && rm t.tar.gz

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

## 已知风险（未实测）

- **exec 限制**：Termux 的 prefix 目录可执行，理论上没问题；但从 `/sdcard`
  之类的位置执行必然失败（那些挂载点带 `noexec`）。
- **SELinux**：Teleport 要建 PTY、读 `/proc`。Android 对 `/proc` 有
  `hidepid` 类限制，`untrusted_app` 域也可能拦某些操作。
- **utmp**：Bionic 的 utmp 是空桩，`session/uacc` 的会话记录会静默落空。
  Android 上本来就没有 utmp 消费方，预计无实际影响。
- **体积**：二进制约 357MB。Android 内部存储紧张的设备要留意。
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
