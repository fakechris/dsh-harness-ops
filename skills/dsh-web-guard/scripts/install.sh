#!/bin/bash
# install.sh — 把 dsh-web-guard 装成系统服务（macOS launchd / Linux systemd）。
# 幂等：重复执行会先卸载旧的再装新的。
#
# 用法：
#   bash install.sh                     # 装到系统服务管理器并立即启动
#   bash install.sh --port 3080         # 指定端口
#   bash install.sh --uninstall         # 卸载
#   bash install.sh --status            # 查看服务状态
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/dsh-web-guard.sh"
PORT="${DGW_PORT:-3080}"
SERVICE_NAME="com.dsh.webguard"   # launchd label / systemd unit 名

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

detect_init() {
  # macOS 用 launchd；Linux 有 systemd 用 systemd，否则报错提示。
  if [ "$(uname -s)" = "Darwin" ]; then echo "launchd"; return 0; fi
  if command -v systemctl >/dev/null 2>&1; then echo "systemd"; return 0; fi
  echo "unsupported"
}

# ── macOS: launchd LaunchAgent ────────────────────────────────────────────
install_launchd() {
  local plist="$HOME/Library/LaunchAgents/$SERVICE_NAME.plist"
  # launchd 环境 PATH 极简 —— 在 plist 的 EnvironmentVariables 里显式给全
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$SERVICE_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$GUARD_SH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DGW_PORT</key>
        <string>$PORT</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/dsh-web-guard.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/dsh-web-guard.launchd.err</string>
</dict>
</plist>
EOF
  # 先卸载旧的（幂等）
  launchctl bootout "gui/$(id -u)/$SERVICE_NAME" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  echo "installed launchd agent: $plist (port $PORT)"
}

# ── Linux: systemd user service ──────────────────────────────────────────
install_systemd() {
  local unit="$HOME/.config/systemd/user/$SERVICE_NAME.service"
  mkdir -p "$(dirname "$unit")"
  cat > "$unit" <<EOF
[Unit]
Description=dsh web guard — auto-restart dsh web on port $PORT
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $GUARD_SH
Restart=always
RestartSec=10
Environment=DGW_PORT=$PORT
Environment=HOME=$HOME

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user stop "$SERVICE_NAME.service" 2>/dev/null || true
  systemctl --user enable --now "$SERVICE_NAME.service"
  echo "installed systemd user unit: $unit (port $PORT)"
}

uninstall() {
  case "$(detect_init)" in
    launchd)
      launchctl bootout "gui/$(id -u)/$SERVICE_NAME" 2>/dev/null || true
      rm -f "$HOME/Library/LaunchAgents/$SERVICE_NAME.plist"
      echo "uninstalled launchd agent $SERVICE_NAME";;
    systemd)
      systemctl --user stop "$SERVICE_NAME.service" 2>/dev/null || true
      systemctl --user disable "$SERVICE_NAME.service" 2>/dev/null || true
      rm -f "$HOME/.config/systemd/user/$SERVICE_NAME.service"
      systemctl --user daemon-reload
      echo "uninstalled systemd unit $SERVICE_NAME";;
    *) echo "unsupported platform"; exit 1;;
  esac
}

status() {
  case "$(detect_init)" in
    launchd) launchctl print "gui/$(id -u)/$SERVICE_NAME" 2>&1 | head -8;;
    systemd) systemctl --user status "$SERVICE_NAME.service" --no-pager 2>&1 | head -10;;
    *) echo "unsupported platform"; exit 1;;
  esac
}

# ── main ─────────────────────────────────────────────────────────────────
[ -x "$GUARD_SH" ] || { echo "guard script missing: $GUARD_SH"; exit 1; }

case "${1:-}" in
  --port) PORT="${2:?--port needs a value}"; shift 2;;
esac

case "${1:-}" in
  --uninstall) uninstall;;
  --status)    status;;
  -h|--help)   usage;;
  ""|--install)
    case "$(detect_init)" in
      launchd) install_launchd;;
      systemd) install_systemd;;
      *) echo "unsupported init system (need launchd or systemd)"; exit 1;;
    esac;;
  *) usage 1;;
esac
