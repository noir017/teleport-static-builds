#!/data/data/com.termux/files/usr/bin/bash
#
# Teleport agent on Termux —— 从干净环境到节点上线的全流程
#
#   bash termux-agent.sh ssh          先把 sshd 支起来, 之后别再对着手机键盘敲
#   bash termux-agent.sh all          install + configure + verify + service (agent)
#   bash termux-agent.sh client       只装客户端 tsh, 和 agent 互不依赖
#
# 单步:  install | client | configure | service | boot | verify | status | logs | uninstall
#
# 全流程说明见同目录 README.md。
set -euo pipefail

REPO="noir017/teleport-static-builds"
: "${PREFIX:?这个脚本只能在 Termux 里跑 (\$PREFIX 未设置)}"

OPT="$PREFIX/opt/teleport"
BIN="$OPT/teleport"
TSH="$OPT/tsh"
TSH_LINK="$PREFIX/bin/tsh"
CFG_DIR="$HOME/.teleport"
CFG="$CFG_DIR/teleport.yaml"
TOKEN_FILE="$CFG_DIR/token"
DATA_DIR="$CFG_DIR/data"
SVC_DIR="$PREFIX/var/service/teleport"
LOG_DIR="$PREFIX/var/log/teleport"

# 需要的最小可用空间(KB)。teleport: tarball ~105M + 解包 ~450M + 余量。
# tsh 小得多, 但仍按宽松值要, 手机上空间不够时中途失败最难受。
NEED_KB_teleport=$((1200 * 1024))
NEED_KB_tsh=$((600 * 1024))

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[1m'; c_0=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_b" "$c_0" "$*"; }
ok()   { printf '%s  ok%s  %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s  !!%s  %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s失败:%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

PKG_UPDATED=0
pkg_need() {
  # pkg_need <命令> <包名>
  command -v "$1" >/dev/null 2>&1 && return 0
  if [ "$PKG_UPDATED" = 0 ]; then
    say "刷新软件源 (只做一次)"
    pkg update -y >/dev/null 2>&1 || warn "pkg update 有告警, 继续; 源坏了就跑 termux-change-repo"
    PKG_UPDATED=1
  fi
  say "安装 $2"
  pkg install -y "$2" >/dev/null || die "装不上 $2"
}

# ---------------------------------------------------------------- 环境前置检查

check_env() {
  local arch sdk
  arch="$(uname -m)"
  [ "$arch" = "aarch64" ] || die "只发布了 arm64 产物, 这台机器是 $arch。
        32 位 ARM (armv7l) 没有对应构建, 换 proot-distro 那条路。"

  sdk="$(getprop ro.build.version.sdk 2>/dev/null || echo 0)"
  if [ "$sdk" -lt 24 ] 2>/dev/null; then
    die "二进制按 Android API 24 编译, 这台是 API $sdk, 起不来。"
  fi
  ok "aarch64 / Android API $sdk"

  case "$(id -un 2>/dev/null || echo)" in
    root) warn "当前是 root。Termux 正常情况下不该是 root, 后面的路径权限可能出错。" ;;
  esac
}

# ------------------------------------------------------------------ ssh 引导

cmd_ssh() {
  say "配置 Termux 自己的 sshd (端口 8022)"
  pkg_need sshd openssh

  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"

  local key="${TERMUX_SSH_PUBKEY:-${1:-}}"
  if [ -n "$key" ]; then
    if grep -qxF "$key" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
      ok "公钥已在 authorized_keys 里"
    else
      printf '%s\n' "$key" >> "$HOME/.ssh/authorized_keys"
      ok "公钥已写入 authorized_keys"
    fi
    chmod 600 "$HOME/.ssh/authorized_keys"
  elif [ -s "$HOME/.ssh/authorized_keys" ]; then
    ok "authorized_keys 已有内容, 不改动"
  else
    warn "没给公钥, 改用密码登录。下面设置 Termux 账号密码:"
    passwd
  fi

  pkill -x sshd 2>/dev/null || true
  sshd
  sleep 1
  pgrep -x sshd >/dev/null || die "sshd 没起来"

  local user ip
  user="$(whoami)"
  ip="$(ip -4 -o addr show 2>/dev/null \
        | awk '$2!="lo"{split($4,a,"/"); print a[1]}' | head -1)"
  [ -n "$ip" ] || ip="<手机IP>"

  ok "sshd 已监听 8022"
  cat <<EOF

  从电脑上连过来 (和手机在同一个网络):

      ssh ${user}@${ip} -p 8022

  然后在 ssh 里继续跑:

      bash ~/termux-agent.sh all --proxy <你的代理地址:443> --token <join token>

  ${c_y}注意${c_0} Termux 的 sshd 只在 Termux 前台/持锁时活着。
  先跑一次 termux-wake-lock, 再把 Termux 加进电池优化白名单。
EOF
}

# ------------------------------------------------------------------- 安装

resolve_version() {
  local v="${TELEPORT_VERSION:-}"
  if [ -z "$v" ]; then
    say "查询最新 release" >&2
    v="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
         | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  fi
  [ -n "$v" ] || die "解析不出版本号, 用 TELEPORT_VERSION=v18.10.0 显式指定"
  printf '%s' "$v"
}

check_space() {
  # check_space <需要的KB>
  local free_kb
  free_kb="$(df -Pk "$PREFIX" | awk 'NR==2{print $4}')"
  if [ "${free_kb:-0}" -lt "$1" ]; then
    die "空间不够: $PREFIX 剩 $((free_kb/1024))MB, 至少要 $(($1/1024))MB。"
  fi
  ok "可用空间 $((free_kb/1024))MB"
}

fetch_tool() {
  # fetch_tool <teleport|tsh> —— 下载 + 双重校验 + 解包到 $OPT/<tool>
  local tool="$1"
  local tag ver dir tgz base tmp want_bin got_bin

  tag="$(resolve_version)"
  ver="${tag#v}"
  dir="${tool}-${ver}-android-arm64"
  tgz="${dir}.tar.gz"
  base="https://github.com/$REPO/releases/download/$tag"
  say "安装 $tool $tag (android/arm64)"

  tmp="$(mktemp -d "$PREFIX/tmp/tp.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  curl -fSL --retry 3 -o "$tmp/$tgz" "$base/$tgz" || die "下载失败: $base/$tgz
        这个 tag 可能没有 $tool 产物 —— 客户端是后加的, 老版本 Release 里没有。
        用 TELEPORT_VERSION=vX.Y.Z 指定一个更新的版本。"
  curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "下载 SHA256SUMS 失败"

  say "校验压缩包"
  ( cd "$tmp" && grep -F "  $tgz" SHA256SUMS > want.txt \
    && [ -s want.txt ] && sha256sum -c want.txt ) >/dev/null \
    || die "$tgz 校验不通过 —— 下载损坏或产物被改过, 别用。"
  ok "压缩包 sha256 正确"

  say "解包"
  mkdir -p "$tmp/x"
  tar xzf "$tmp/$tgz" -C "$tmp/x" --strip-components=1
  [ -f "$tmp/x/$tool" ] || die "包里没有 $tool"

  # SHA256SUMS 里同时记了解包后二进制的哈希, 顺手把它也验了
  want_bin="$(awk -v p="$dir/$tool" '$2==p{print $1}' "$tmp/SHA256SUMS")"
  if [ -n "$want_bin" ]; then
    got_bin="$(sha256sum "$tmp/x/$tool" | awk '{print $1}')"
    [ "$want_bin" = "$got_bin" ] || die "解包出来的 $tool 哈希对不上, 中止。"
    ok "二进制 sha256 正确"
  else
    warn "SHA256SUMS 里没有 $dir/$tool 这一条, 只校验了压缩包"
  fi

  mkdir -p "$OPT"
  mv -f "$tmp/x/$tool" "$OPT/$tool"
  chmod 755 "$OPT/$tool"
  ok "已装到 $OPT/$tool ($(du -h "$OPT/$tool" | cut -f1))"
}

cmd_install() {
  check_env
  pkg_need curl curl
  pkg_need tar tar
  check_space "$NEED_KB_teleport"
  fetch_tool teleport

  say "第一道验证: 能不能在这台设备上执行"
  "$BIN" version || die "二进制跑不起来。
        这是最关键的一道门, 没过就不用往下走了 —— 多半是 Android 版本或
        SELinux 拦了。把上面的报错发出来。"
  ok "$($BIN version | head -1)"
}

# ---------------------------------------------------------------- 客户端 tsh

cmd_client() {
  check_env
  pkg_need curl curl
  pkg_need tar tar
  check_space "$NEED_KB_tsh"
  fetch_tool tsh

  say "第一道验证: 能不能在这台设备上执行"
  "$TSH" version || die "tsh 跑不起来。把上面的报错发出来。"

  mkdir -p "$PREFIX/bin"
  ln -sf "$TSH" "$TSH_LINK"
  ok "已把 tsh 链到 $TSH_LINK (在 PATH 里)"

  cat <<EOF

  ${c_b}用法${c_0}

      tsh login --proxy=teleport.example.com:443 --user=<你的用户名>
      tsh ls
      tsh ssh <login>@<node>

  凭据存在 ${c_b}~/.tsh${c_0}, 和 agent 的 ~/.teleport 无关 —— 客户端和 agent
  可以只装一个。

  ${c_y}SSO 登录要开浏览器${c_0}: Termux 的 termux-tools 自带 xdg-open, 正常能拉起。
  拉不起来就加 ${c_b}--browser=none${c_0}, tsh 会把 URL 打出来让你自己复制。

  ${c_y}不支持硬件密钥${c_0}(PIV / YubiKey): 没编 piv tag, Android 也没有读卡器。
  集群若强制 hardware key, 这个 tsh 登不上。

EOF
}

# ------------------------------------------------------------------- 配置

sanitize_nodename() {
  local n
  n="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' \
       | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
  printf '%s' "${n:-termux-node}"
}

cmd_configure() {
  local proxy="${TELEPORT_PROXY:-}" token="${TELEPORT_TOKEN:-}" nodename="${TELEPORT_NODENAME:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --proxy)    proxy="${2:-}";    shift 2 ;;
      --token)    token="${2:-}";    shift 2 ;;
      --nodename) nodename="${2:-}"; shift 2 ;;
      *) die "configure: 不认识的参数 $1" ;;
    esac
  done

  [ -n "$proxy" ] || die "缺 --proxy。形如 --proxy teleport.example.com:443"
  [ -n "$token" ] || die "缺 --token。在控制面上执行:
        tctl tokens add --type=node --ttl=1h"

  case "$proxy" in *:*) ;; *) proxy="$proxy:443"; warn "代理地址没带端口, 按 $proxy 处理" ;; esac

  if [ -z "$nodename" ]; then
    nodename="$(sanitize_nodename "termux-$(getprop ro.product.model 2>/dev/null || echo phone)")"
  else
    nodename="$(sanitize_nodename "$nodename")"
  fi

  mkdir -p "$CFG_DIR" "$DATA_DIR"
  chmod 700 "$CFG_DIR"

  printf '%s' "$token" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"

  cat > "$CFG" <<EOF
version: v3
teleport:
  nodename: $nodename
  data_dir: $DATA_DIR
  proxy_server: $proxy
  join_params:
    method: token
    token_name: $TOKEN_FILE
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
    device: $(sanitize_nodename "$(getprop ro.product.model 2>/dev/null || echo unknown)")
    android: "$(getprop ro.build.version.release 2>/dev/null || echo unknown)"
EOF
  chmod 600 "$CFG"
  ok "已写 $CFG  (nodename=$nodename, proxy=$proxy)"

  local u; u="$(whoami)"
  cat <<EOF

  ${c_y}能登录这个节点的账号只有一个${c_0}: ${c_b}${u}${c_0}
  Android 上没有别的用户可切, 也没有 root。
  确认你的 Teleport 角色 logins 里包含它, 否则节点上线了也进不去:

      tctl edit role/<你的角色>     # logins: ['${u}']

EOF
}

# --------------------------------------------------------------- 冒烟验证

cmd_verify() {
  [ -x "$BIN" ] || die "还没装, 先跑 install"
  [ -f "$CFG" ] || die "还没配, 先跑 configure"
  pkg_need timeout coreutils

  say "版本"
  "$BIN" version

  local log; log="$(mktemp "$PREFIX/tmp/tpverify.XXXXXX")"
  say "试启动 45 秒, 看能不能加入集群"
  # 已在跑的服务会占住 data_dir, 先让路
  local was_up=0
  if command -v sv >/dev/null 2>&1 && sv status teleport >/dev/null 2>&1; then
    sv down teleport >/dev/null 2>&1 && was_up=1 && sleep 2
  fi

  timeout 45 "$BIN" start --config="$CFG" > "$log" 2>&1 || true

  local verdict=1
  if grep -qE 'Service is starting in tunnel mode|successfully joined|Successfully registered' "$log"; then
    ok "已加入集群并建立反向隧道"
    verdict=0
  elif grep -q 'Disabling host user creation' "$log" \
       && grep -q '\[SQLITE\].*Connected to database' "$log"; then
    warn "进程起来了、SQLite 后端正常, 但没看到加入成功的标志。"
    warn "多半是 token 过期 / 代理地址不对 / 控制面没发布 3024 端口。"
  else
    warn "启动阶段就出问题了。"
  fi

  say "关键日志行"
  grep -E 'Disabling host user creation|\[SQLITE\].*Connected|Joining the cluster|ERRO|Original Error' "$log" \
    | head -20 || true

  echo
  say "最后 25 行"
  tail -25 "$log"

  # 这两条是 android 产物的预期表现, 不是故障
  if grep -q 'Disabling host user creation' "$log"; then
    echo
    ok "看到 'Disabling host user creation' 是${c_b}正常的${c_0} —— Bionic 没有
      getpwent 系列, host_users 自动创建在 Android 上本来就不可用。是降级不是崩溃。"
  fi

  [ "$was_up" = 1 ] && sv up teleport >/dev/null 2>&1 || true
  rm -f "$log"

  if [ "$verdict" = 0 ]; then
    cat <<EOF

  ${c_b}在你的电脑上确认节点确实上线了:${c_0}

      tsh ls | grep $(awk '/nodename:/{print $2}' "$CFG")
      tsh ssh $(whoami)@$(awk '/nodename:/{print $2}' "$CFG")

  ${c_y}最后一步只有真机能测${c_0}: PTY 分配和会话录制在 redroid 容器里验证不了
  (那边 SELinux 是关的, 且 adb shell 的 uid 比 Termux 的 app uid 权限高)。
  上面这条 tsh ssh 能开出交互 shell, 才算真的全通。
EOF
  fi
  return "$verdict"
}

# ------------------------------------------------------------------- 常驻

cmd_service() {
  [ -x "$BIN" ] || die "还没装, 先跑 install"
  [ -f "$CFG" ] || die "还没配, 先跑 configure"

  local fresh=0
  command -v sv >/dev/null 2>&1 || fresh=1
  pkg_need sv termux-services

  mkdir -p "$SVC_DIR/log" "$LOG_DIR"

  # $SHELL 可能指向一个已经卸载的 shell(换过 shell 又 pkg uninstall 的情况),
  # 写进 service 前先确认它真的能执行, 否则挑一个装着的。
  local svc_shell="${SHELL:-}"
  if [ ! -x "$svc_shell" ]; then
    svc_shell=""
    for s in bash zsh fish sh; do
      if [ -x "$PREFIX/bin/$s" ]; then svc_shell="$PREFIX/bin/$s"; break; fi
    done
    [ -n "$svc_shell" ] || die "在 $PREFIX/bin 下找不到任何 shell —— Termux 环境不完整"
    warn "\$SHELL 不可用, service 里改用 $svc_shell"
  fi

  # ⚠️ runsvdir 给服务的环境是很干净的, 不能指望继承交互 shell 的变量。
  # 但 agent 需要这三个:
  #   HOME    Bionic 合成的 pw_dir 恒为 /data(沙箱里不可写), 要用它纠正
  #   PREFIX  HOME 缺失时据此推出 home, 也用来找 shell
  #   SHELL   Bionic 合成的 pw_shell 恒为 /bin/sh, Termux 里不存在
  # 缺了它们会话仍能开, 但会落在 / 上、用兜底的 shell —— 体验差且难查。
  # 所以这里写死成安装时的实际值, 不依赖运行时环境。
  cat > "$SVC_DIR/run" <<EOF
#!$PREFIX/bin/sh
exec 2>&1
export HOME=$HOME
export PREFIX=$PREFIX
export SHELL=$svc_shell
exec $BIN start --config=$CFG
EOF
  cat > "$SVC_DIR/log/run" <<EOF
#!$PREFIX/bin/sh
mkdir -p $LOG_DIR
exec svlogd -tt $LOG_DIR
EOF
  chmod +x "$SVC_DIR/run" "$SVC_DIR/log/run"
  ok "已写 runit service: $SVC_DIR"

  if [ "$fresh" = 1 ]; then
    warn "termux-services 是刚装的 —— runsvdir 还没起。"
    warn "${c_b}完全退出 Termux 再打开${c_0} (关掉所有会话), 然后跑:"
    echo  "      sv-enable teleport && sv status teleport"
    return 0
  fi

  sv-enable teleport >/dev/null 2>&1 || true
  sv up teleport >/dev/null 2>&1 || true
  sleep 3
  sv status teleport || warn "sv 拿不到状态, 可能 runsvdir 没跑 —— 重开 Termux 试试"

  local wl="1. wake lock —— ${c_r}没持上, 手动跑 termux-wake-lock${c_0}"
  if termux-wake-lock 2>/dev/null; then
    ok "已持 wake lock"
    wl="1. wake lock —— 已经帮你持上了 (开机后要重新持, 见 boot 子命令)"
  else
    warn "termux-wake-lock 没成功 —— 这条不做, agent 迟早被系统杀掉"
  fi

  cat <<EOF

  ${c_y}Android 会杀后台, 下面两件事${c_b}缺一不可${c_0}${c_y}, 不做 agent 迟早离线:${c_0}

  $wl
  2. 关掉 Termux 的电池优化。跳到那个设置页:

         am start -a android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS

     国产 ROM 通常还要额外把 Termux 加进"自启动"白名单, 位置各家不同。

  日志: bash $0 logs
EOF
}

cmd_boot() {
  # 开机自启需要 Termux:Boot (F-Droid), 光装 termux-services 不够
  local bd="$HOME/.termux/boot"
  mkdir -p "$bd"
  cat > "$bd/00-teleport" <<EOF
#!$PREFIX/bin/sh
termux-wake-lock
. $PREFIX/etc/profile.d/start-services.sh
EOF
  chmod +x "$bd/00-teleport"
  ok "已写 $bd/00-teleport"
  cat <<EOF

  ${c_y}这个脚本只有装了 Termux:Boot 才会被执行${c_0} —— 它是独立的 app,
  从 ${c_b}F-Droid${c_0} 装 (Google Play 版没有)。装完手动打开一次, 否则不生效。

EOF
}

show_tool() {
  # show_tool <标签> <路径> —— "存在但跑不起来"要和"没装"分开报, 两者的下一步完全不同
  printf '%s: ' "$1"
  if [ ! -x "$2" ]; then echo "未安装"; return; fi
  local v
  if v="$("$2" version 2>/dev/null | head -1)" && [ -n "$v" ]; then
    echo "$v"
  else
    echo "文件在但执行失败 —— $2"
  fi
}

cmd_status() {
  show_tool 'agent   ' "$BIN"
  show_tool '客户端  ' "$TSH"
  printf '配置    : '; [ -f "$CFG" ] && awk '/nodename:|proxy_server:/{printf "%s ", $2}END{print ""}' "$CFG" || echo "未配置"
  printf '进程    : '; pgrep -f "$BIN" >/dev/null && echo "在跑 (pid $(pgrep -f "$BIN" | tr '\n' ' '))" || echo "没跑"
  printf '服务    : '
  if ! command -v sv >/dev/null 2>&1; then
    echo "termux-services 未装"
  elif [ ! -d "$SVC_DIR" ]; then
    echo "未注册 (没跑过 service 子命令)"
  else
    sv status teleport 2>&1 || echo "  ^ sv 报错, 多半是 runsvdir 没跑: 完全退出 Termux 再打开"
  fi
  printf 'wakelock: 命令行查不到 —— 看 Termux 的常驻通知里有没有 "wake lock held"\n'
  printf '磁盘    : '; du -sh "$OPT" 2>/dev/null || echo "-"
}

cmd_logs() {
  [ -d "$LOG_DIR" ] || die "没有 $LOG_DIR —— 还没用 service 跑起来?"
  tail -f "$LOG_DIR/current"
}

cmd_uninstall() {
  say "停服务"
  command -v sv >/dev/null 2>&1 && { sv-disable teleport >/dev/null 2>&1 || true; }
  pkill -f "$BIN" 2>/dev/null || true
  rm -rf "$SVC_DIR"
  say "删二进制 $OPT"
  # 软链指向 $OPT 里的 tsh, 删目录前先摘掉, 免得留一条断链在 PATH 上
  [ -L "$TSH_LINK" ] && rm -f "$TSH_LINK"
  rm -rf "$OPT"
  warn "配置和数据保留在 $CFG_DIR —— 里面有 join token 和主机身份。"
  warn "确定不要了就自己 rm -rf $CFG_DIR"
  warn "节点记录还在集群里, 在控制面上删: tctl nodes rm <nodename>"
}

# -------------------------------------------------------------------- 入口

cmd_all() {
  cmd_install
  echo; cmd_configure "$@"
  echo; cmd_verify || warn "验证没全绿, 但还是把服务装上 —— 修好配置后 sv restart teleport 即可"
  echo; cmd_service
  echo; cmd_boot
}

usage() {
  cat <<EOF
Teleport agent on Termux

  bash $0 ssh [公钥]                     装 sshd, 之后从电脑操作
  bash $0 all --proxy H:443 --token T    一条龙
  bash $0 install                        下载校验解包 agent, 验证能执行
  bash $0 client                         只装客户端 tsh (与 agent 互不依赖)
  bash $0 configure --proxy H:443 --token T [--nodename N]
  bash $0 verify                         试启动 45s, 判断有没有加入集群
  bash $0 service                        runit 常驻 + wake lock
  bash $0 boot                           开机自启 (需 Termux:Boot)
  bash $0 status | logs | uninstall

环境变量: TELEPORT_VERSION TELEPORT_PROXY TELEPORT_TOKEN TELEPORT_NODENAME
          TERMUX_SSH_PUBKEY
EOF
}

sub="${1:-}"; shift || true
case "$sub" in
  ssh)       cmd_ssh "$@" ;;
  install)   cmd_install ;;
  client)    cmd_client ;;
  configure) cmd_configure "$@" ;;
  verify)    cmd_verify ;;
  service)   cmd_service ;;
  boot)      cmd_boot ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  uninstall) cmd_uninstall ;;
  all)       cmd_all "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage; die "不认识的子命令: $sub" ;;
esac
