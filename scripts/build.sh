#!/bin/bash
set -u

enable_svc() {
    local svc="$1"
    local target="${2:-multi-user.target}"
    local path=""
    for d in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
        [ -f "$d/$svc" ] && { path="$d/$svc"; break; }
    done
    [ -z "$path" ] && { echo "AVISO: $svc no encontrado"; return 0; }
    mkdir -p "/etc/systemd/system/${target}.wants"
    ln -sf "$path" "/etc/systemd/system/${target}.wants/${svc}" || true
}

# ============================================================
# 1. WIFI
# ============================================================
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "b1f2a3c4-0000-1111-2222-333344445555")
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/Telecable_feNq.nmconnection << EOF
[connection]
id=Telecable_feNq
uuid=${UUID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=Telecable_feNq

[wifi-security]
key-mgmt=wpa-psk
psk=m3F9C3YA

[ipv4]
method=auto

[ipv6]
method=auto
EOF
chmod 600 /etc/NetworkManager/system-connections/Telecable_feNq.nmconnection

# ============================================================
# 2. LÍMITE DE CPU
# ============================================================
cat > /etc/systemd/system/gavi-cpu-limit.service << 'EOF'
[Unit]
Description=Gavi Burger - limite CPU intel_pstate
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -f /sys/devices/system/cpu/intel_pstate/max_perf_pct ]; then echo 650000 > /sys/devices/system/cpu/intel_pstate/max_perf_pct; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
enable_svc gavi-cpu-limit.service

# ============================================================
# 3. SSH
# ============================================================
enable_svc ssh.service

# ============================================================
# 4. CONTRASEÑA USUARIO LIVE
# ============================================================
cat > /usr/local/sbin/gavi-set-password.sh << 'EOF'
#!/bin/bash
for i in $(seq 1 30); do
    for u in live ubuntu casper linuxlive-kiosk; do
        if id "$u" >/dev/null 2>&1; then
            echo "${u}:holakase" | chpasswd
            passwd -u "$u" >/dev/null 2>&1 || true
        fi
    done
    sleep 2
done
exit 0
EOF
chmod +x /usr/local/sbin/gavi-set-password.sh

cat > /etc/systemd/system/gavi-set-password.service << 'EOF'
[Unit]
Description=Gavi Burger - password usuarios
After=systemd-user-sessions.service
Wants=systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gavi-set-password.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
enable_svc gavi-set-password.service

# ============================================================
# 5. AGENTE DE REINICIO (Pantalla 1)
# ============================================================
cat > /usr/local/bin/reboot-agent.py << 'PYEOF'
#!/usr/bin/env python3
import json, time, os, sys
import urllib.request, urllib.parse

API = "https://gaviburger.com/api.php"
SCREEN = "Pantalla 1"
STATE_FILE = "/var/lib/reboot-agent-state"
BOOT_FILE = "/var/lib/reboot-agent-boot"

def log(m): print(f"[reboot-agent] {m}", flush=True)

def api(action):
    q = urllib.parse.urlencode({"action": action, "screen": SCREEN})
    req = urllib.request.Request(API + "?" + q, headers={"User-Agent": "RebootAgent/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode())

def last():
    try:
        return open(STATE_FILE).read().strip() if os.path.exists(STATE_FILE) else None
    except Exception:
        return None

def save(v):
    try:
        open(STATE_FILE, "w").write(str(v))
    except Exception as e:
        log(f"error guardando estado: {e}")

def force_reboot():
    log("=== INICIANDO SECUENCIA DE REINICIO ===")
    os.system("sync"); os.system("sync")
    try:
        with open("/proc/sys/kernel/sysrq", "w") as f: f.write("1")
    except Exception as e: log(f"Error habilitando sysrq: {e}")
    try:
        with open("/proc/sysrq-trigger", "w") as f: f.write("b")
    except Exception as e: log(f"sysrq fallo: {e}")
    time.sleep(3); os.system("reboot -f")
    time.sleep(3); os.system("systemctl reboot -ff")

boot_ts = str(int(time.time()))
try:
    prev_boot = open(BOOT_FILE).read().strip() if os.path.exists(BOOT_FILE) else "0"
    open(BOOT_FILE, "w").write(boot_ts)
    log(f"Boot detectado: {boot_ts} (anterior: {prev_boot})")
    try:
        if int(boot_ts) - int(prev_boot) < 10:
            log("Posible bucle detectado, esperando 60s..."); time.sleep(60)
    except Exception: pass
except Exception: pass

for i in range(30):
    try:
        api("ping_reboot"); log("Red disponible"); break
    except Exception:
        log(f"Esperando red... ({i+1}/30)"); time.sleep(2)

log(f"Arrancando agente para pantalla: '{SCREEN}'")
while True:
    try:
        api("ping_reboot")
        s = api("get_reboot")
        pend = s.get("pending", False); rat = s.get("requested_at")
        log(f"Estado API -> pending={pend}, requested_at={rat}")
        if pend and rat and str(rat) != str(last()):
            log(f"¡NUEVA ORDEN! ({rat}). Cancelando y reiniciando...")
            save(rat)
            try:
                q = urllib.parse.urlencode({"action": "cancel_reboot", "screen": SCREEN})
                req = urllib.request.Request(API + "?" + q, headers={"User-Agent": "RebootAgent/1.0"})
                with urllib.request.urlopen(req, timeout=5) as r: log(f"cancel_reboot: {r.read().decode()}")
            except Exception as e: log(f"Error cancelando: {e}")
            time.sleep(2); force_reboot(); sys.exit(0)
    except Exception as e:
        log(f"error de conexion: {e}")
    time.sleep(5)
PYEOF
chmod +x /usr/local/bin/reboot-agent.py

cat > /etc/systemd/system/reboot-agent.service << 'EOF'
[Unit]
Description=Gavi Burger Reboot Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/reboot-agent.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
enable_svc reboot-agent.service

# ============================================================
# 6. VIGILANTE DE RED + SESIÓN SIEMPRE LIMPIA (sustituye a firefox-refresh)
#    - Reinicia Firefox al recuperar internet (fix "no internet")
#    - Borra sessionstore tras cada reinicio (fix "trouble getting pages back")
#    - Refresco completo cada 2h
# ============================================================
# Limpieza por si quedara el servicio viejo de alguna build anterior
rm -f /etc/systemd/system/graphical.target.wants/firefox-refresh.service
rm -f /etc/systemd/system/firefox-refresh.service

cat > /usr/local/bin/gavi-net-watchdog.sh << 'EOF'
#!/bin/bash
SITE="https://gaviburger.com/index.php?screen=Pantalla+1"
FFBASE="/var/lib/linuxlive-kiosk/.var/app/org.mozilla.firefox/config/mozilla/firefox"
last="down"
counter=0

# Borra TODO rastro de sesión para que Firefox arranque 100% limpio
wipe_session() {
    for d in "$FFBASE"/*.default*; do
        [ -d "$d" ] || continue
        rm -f "$d/sessionstore.jsonlz4"
        rm -rf "$d/sessionstore-backups"
        rm -f "$d/recovery.jsonlz4" "$d/recovery.baklz4"
    done
}

restart_firefox() {
    pkill -9 -f 'firefox-bin' 2>/dev/null
    pkill -9 -f 'bwrap' 2>/dev/null
    sleep 2
    wipe_session   # clave: elimina la sesión "crasheada" antes del próximo arranque
}

while true; do
    if curl -s -o /dev/null -m 6 "$SITE"; then net="up"; else net="down"; fi

    # La red ACABA de volver (o primer check con red) -> reinicio limpio
    if [ "$net" = "up" ] && [ "$last" = "down" ]; then
        echo "[watchdog] $(date '+%H:%M:%S')] Red recuperada -> reinicio limpio de Firefox"
        restart_firefox
    fi

    # Refresco programado cada 2h (240 ciclos de 30s)
    counter=$((counter+1))
    if [ "$counter" -ge 240 ]; then
        counter=0
        echo "[watchdog] $(date '+%H:%M:%S')] Refresco 2h -> reinicio limpio de Firefox"
        restart_firefox
    fi

    last="$net"
    sleep 30
done
EOF
chmod +x /usr/local/bin/gavi-net-watchdog.sh

cat > /etc/systemd/system/gavi-net-watchdog.service << 'EOF'
[Unit]
Description=Gavi network watchdog (sesion limpia + recovery de red)
After=network-online.target graphical.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gavi-net-watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
enable_svc gavi-net-watchdog.service multi-user.target

# ============================================================
# 7. PANTALLAS 1080p + ROTACIÓN DINÁMICA DESDE JSON (CADA 60s)
# ============================================================
cat > /usr/local/bin/keep-displays-1080p.sh << 'EOF'
#!/bin/bash
KUSER=linuxlive-kiosk
SCREEN_NAME="Pantalla 1"

get_rotation() {
    python3 -c '
import urllib.request, json, sys
screen_name = sys.argv[1] if len(sys.argv) > 1 else "default"
try:
    with urllib.request.urlopen("https://gaviburger.com/orientacion.json", timeout=5) as r:
        data = json.loads(r.read().decode())
    o = data.get(screen_name, data.get("default", "normal")).lower().strip()
    if o in ["vertical","derecha","90"]: print("90")
    elif o in ["invertida","180"]: print("180")
    elif o in ["izquierda","270"]: print("270")
    else: print("normal")
except Exception: print("normal")
' "$1"
}

while true; do
    PID=$(pgrep -u "$KUSER" -x cage | head -n1)
    if [ -n "$PID" ]; then
        WLD=$(sudo tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | awk -F= '/^WAYLAND_DISPLAY=/{print $2}')
        XRD=$(sudo tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | awk -F= '/^XDG_RUNTIME_DIR=/{print $2}')
        [ -z "$WLD" ] && WLD=wayland-0
        [ -z "$XRD" ] && XRD=/run/user/$(id -u "$KUSER")
        ROTATION=$(get_rotation "$SCREEN_NAME")
        sudo -u "$KUSER" env XDG_RUNTIME_DIR="$XRD" WAYLAND_DISPLAY="$WLD" wlr-randr --output HDMI-A-1 --mode 1920x1080 --pos 0,0 --transform "$ROTATION" 2>/dev/null || true
        sudo -u "$KUSER" env XDG_RUNTIME_DIR="$XRD" WAYLAND_DISPLAY="$WLD" wlr-randr --output HDMI-A-2 --mode 1920x1080 --pos 0,0 --transform "$ROTATION" 2>/dev/null || true
    fi
    sleep 60
done
EOF
chmod +x /usr/local/bin/keep-displays-1080p.sh

cat > /etc/systemd/system/keep-displays-1080p.service << 'EOF'
[Unit]
Description=Keep displays at 1080p with dynamic rotation (continuous)
After=graphical.target

[Service]
Type=simple
ExecStart=/usr/local/bin/keep-displays-1080p.sh
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
EOF
enable_svc keep-displays-1080p.service graphical.target

# ============================================================
# 8. FIREFOX: SESIÓN SIEMPRE NUEVA + NUNCA MODO OFFLINE
# ============================================================
cat > /usr/local/sbin/clean-firefox-profile.sh << 'EOF'
#!/bin/bash
KUSER=linuxlive-kiosk
FFBASE="/var/lib/$KUSER/.var/app/org.mozilla.firefox/config/mozilla/firefox"

for i in $(seq 1 30); do
    if [ -d "$FFBASE" ]; then break; fi
    sleep 1
done

FFPROFILE=$(find "$FFBASE" -maxdepth 1 -type d -name "*.default*" 2>/dev/null | head -n1)
[ -z "$FFPROFILE" ] && { mkdir -p "$FFBASE"; chown "$KUSER:$KUSER" "$FFBASE"; exit 0; }

rm -f "$FFPROFILE"/sessionstore.jsonlz4
rm -rf "$FFPROFILE"/sessionstore-backups
rm -f "$FFPROFILE"/recovery.jsonlz4
rm -f "$FFPROFILE"/recovery.baklz4

cat > "$FFPROFILE/user.js" << 'USERJS'
user_pref("network.manage-offline-status", false);
user_pref("network.online", true);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.max_resumed_crashes", 0);
user_pref("browser.sessionstore.resume_session_once", false);
user_pref("browser.sessionstore.privacy_level", 2);
user_pref("browser.sessionstore.interval", 600000);
user_pref("browser.startup.page", 1);
user_pref("browser.startup.homepage", "https://gaviburger.com/index.php?screen=Pantalla+1");
user_pref("browser.sessionstore.max_tabs_undo", 0);
user_pref("browser.sessionstore.max_windows_undo", 0);
user_pref("toolkit.crashreporter.enabled", false);
user_pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);
user_pref("browser.crashReports.unsubmittedCheck.enabled", false);
user_pref("browser.sessionstore.restore_on_demand", false);
user_pref("browser.cache.disk.enable", false);
user_pref("browser.cache.offline.enable", false);
user_pref("browser.tabs.warnOnClose", false);
user_pref("browser.tabs.warnOnCloseOtherTabs", false);
user_pref("startup.homepage_override_url", "");
user_pref("startup.homepage_welcome_url", "");
user_pref("browser.startup.homepage_override.mstone", "ignore");
USERJS

chown "$KUSER:$KUSER" "$FFPROFILE/user.js" 2>/dev/null
EOF
chmod +x /usr/local/sbin/clean-firefox-profile.sh

cat > /etc/systemd/system/clean-firefox-profile.service << 'EOF'
[Unit]
Description=Clean Firefox profile before kiosk starts
Before=cage.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/clean-firefox-profile.sh
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF
enable_svc clean-firefox-profile.service graphical.target

# ============================================================
# 9. SUPRIMIR PROMPT "REMOVE INSTALLATION MEDIUM" via drop-in
# ============================================================
mkdir -p /etc/sysctl.d
echo "kernel.sysrq=1" > /etc/sysctl.d/99-gavi-sysrq.conf

mkdir -p /etc/systemd/system/casper.service.d
cat > /etc/systemd/system/casper.service.d/override.conf << 'EOF'
[Service]
StandardInput=null
StandardOutput=journal
StandardError=journal
EOF

mkdir -p /etc/systemd/system/systemd-logind.service.d
cat > /etc/systemd/system/systemd-logind.service.d/reboot.conf << 'EOF'
[Service]
Environment=SYSTEMD_LOG_LEVEL=info
EOF

# ============================================================
# 10. WATCHDOG DE PANTALLA NEGRA (reinicia si se queda colgada)
# ============================================================
export DEBIAN_FRONTEND=noninteractive
if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
    apt-get update || true
    apt-get install -y --no-install-recommends imagemagick || true
fi
command -v grim  >/dev/null 2>&1 || apt-get install -y --no-install-recommends grim || true
command -v gdbus >/dev/null 2>&1 || apt-get install -y --no-install-recommends libglib2.0-bin || true

cat > /usr/local/bin/kiosk-watchdog.sh << 'WDEOF'
#!/usr/bin/env bash
# kiosk-watchdog: reinicia si la pantalla se queda del color "malo" (negro por defecto)
# en dos capturas seguidas separadas INTERVALO segundos.
#   --test     : 1 captura, dice el % y si reiniciaria
#   --colores  : lista los colores de la pantalla
set -uo pipefail
export HOME="${HOME:-/root}"        # systemd NO define HOME: sin esto el servicio muere

INTERVALO="${INTERVALO:-120}"
UMBRAL="${UMBRAL:-99.0}"
FUZZ="${FUZZ:-5}"
COLOR="${COLOR:-#000000}"
GRACIA="${GRACIA:-240}"
MIN_UPTIME="${MIN_UPTIME:-600}"
SIMULAR="${SIMULAR:-0}"
CADA="${CADA:-10}"
[ "$CADA" -ge 1 ] 2>/dev/null || CADA=10
LOG="${LOG:-/var/log/kiosk-watchdog.log}"
MODO="${1:-loop}"

DIR=/run/kiosk-watchdog; mkdir -p "$DIR" 2>/dev/null || { DIR=/tmp/kiosk-watchdog; mkdir -p "$DIR"; }
touch "$LOG" 2>/dev/null || LOG=/tmp/kiosk-watchdog.log
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; printf '%s %s\n' "$(date '+%F %T')" "$*"; }

if command -v magick >/dev/null 2>&1; then IM=(magick); IMI=(magick import)
elif command -v convert >/dev/null 2>&1; then IM=(convert); IMI=(convert)
else log "FALTA ImageMagick"; exit 1; fi

entorno(){
  local s t uid f d
  SID=""; STYPE=""
  for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    [ "$(loginctl show-session "$s" -p Remote --value 2>/dev/null)" = "no" ] || continue
    [ "$(loginctl show-session "$s" -p Class  --value 2>/dev/null)" = "user" ] || continue
    t="$(loginctl show-session "$s" -p Type --value 2>/dev/null)"
    case "$t" in x11|wayland) SID="$s"; STYPE="$t"; break ;; esac
  done
  [ -n "$SID" ] || return 1
  uid="$(loginctl show-session "$SID" -p User --value)"
  d="$(loginctl show-session "$SID" -p Display --value)"
  export XDG_RUNTIME_DIR="/run/user/$uid"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  export DISPLAY="${d:-:0}"
  for f in "/run/user/$uid/gdm/Xauthority" /run/user/$uid/.mutter-Xwaylandauth.* "$HOME/.Xauthority"; do
    [ -r "$f" ] && export XAUTHORITY="$f" && break
  done
  return 0
}

captura(){
  local OUT="$1"; rm -f "$OUT"
  if [ "$STYPE" = "wayland" ]; then
    command -v grim >/dev/null 2>&1 && grim "$OUT" >/dev/null 2>&1 && [ -s "$OUT" ] && return 0
    command -v gdbus >/dev/null 2>&1 && gdbus call --session \
      --dest org.gnome.Shell.Screenshot --object-path /org/gnome/Shell/Screenshot \
      --method org.gnome.Shell.Screenshot.Screenshot false false "$OUT" >/dev/null 2>&1 && [ -s "$OUT" ] && return 0
    command -v gnome-screenshot >/dev/null 2>&1 && gnome-screenshot -f "$OUT" >/dev/null 2>&1 && [ -s "$OUT" ] && return 0
    command -v spectacle >/dev/null 2>&1 && spectacle -b -n -o "$OUT" >/dev/null 2>&1 && [ -s "$OUT" ] && return 0
  fi
  command -v scrot >/dev/null 2>&1 && scrot -o "$OUT" >/dev/null 2>&1 && [ -s "$OUT" ] && return 0
  "${IMI[@]}" -window root "$OUT" >/dev/null 2>&1 && [ -s "$OUT" ] && return 0
  return 1
}

medir(){
  local p
  captura "$1" || return 1
  p="$("${IM[@]}" "$1" -fuzz ${FUZZ}% +transparent "$COLOR" -alpha extract -format '%[fx:mean*100]' info: 2>/dev/null)" || return 1
  [ -n "$p" ] || return 1
  echo "$p"
}
supera(){ awk -v p="$1" -v u="$UMBRAL" 'BEGIN{exit !(p>=u)}'; }

if [ "$MODO" = "--colores" ]; then
  entorno || { echo "No hay sesion grafica local."; exit 1; }
  captura "$DIR/colores.png" || { echo "Captura fallida."; exit 2; }
  T="$("${IM[@]}" "$DIR/colores.png" -format '%[fx:w*h]' info:)"
  echo "== TOP 10 colores exactos =="
  "${IM[@]}" "$DIR/colores.png" -alpha off -depth 8 -format %c histogram:info:- \
   | sed 's/^ *//' | sort -rn | head -10 \
   | awk -v t="$T" '{c=$1+0; sub(/^[^:]*:[ ]*/,""); printf "%10d %6.2f%%  %s\n", c, c*100/t, $0}'
  echo "== 8 dominantes =="
  "${IM[@]}" "$DIR/colores.png" -alpha off -resize 200x200! -colors 8 -depth 8 -format %c histogram:info:- \
   | sed 's/^ *//' | sort -rn \
   | awk '{c=$1+0; sub(/^[^:]*:[ ]*/,""); printf "%10d %6.2f%%  %s\n", c, c*100/40000, $0}'
  exit 0
fi

if [ "$MODO" = "--test" ] || [ "$MODO" = "test" ]; then
  entorno || { echo "No hay sesion grafica local."; exit 1; }
  P="$(medir "$DIR/test.png")" || { echo "Captura fallida."; exit 2; }
  echo "Pixeles ${COLOR}: ${P}%   (umbral: ${UMBRAL}%)"
  if supera "$P"; then echo "VEREDICTO: MALA -> reiniciaria"; else echo "VEREDICTO: normal -> NO reinicia"; fi
  exit 0
fi

log "=== watchdog iniciado | color ${COLOR} | umbral ${UMBRAL}% | intervalo ${INTERVALO}s | simular=${SIMULAR} ==="
sleep "$GRACIA"
N=0
while :; do
  entorno || { log "Sin sesion grafica; reintento en 30s"; sleep 30; continue; }
  if ! P1="$(medir "$DIR/1.png")"; then log "Captura 1 fallida (no reinicio)"; sleep "$INTERVALO"; continue; fi
  if supera "$P1"; then
    log "AVISO: pantalla ${COLOR} (${P1}%). Recompruebo en ${INTERVALO}s..."
    sleep "$INTERVALO"
    if entorno && P2="$(medir "$DIR/2.png")" && supera "$P2"; then
      UP=$(awk '{print int($1)}' /proc/uptime)
      if [ "$UP" -lt "$MIN_UPTIME" ]; then
        log "Mala (${P2}%) pero uptime ${UP}s < ${MIN_UPTIME}s -> NO reinicio (anti-bucle)"
      elif [ "$SIMULAR" = "1" ]; then
        log "SIMULACION: reiniciaria ahora (${P1}% / ${P2}%)"
      else
        log "CONFIRMADO (${P1}% / ${P2}%) -> REINICIANDO"
        sync
        systemctl reboot || reboot -f || echo b > /proc/sysrq-trigger
        sleep 120
      fi
    else
      log "Segunda captura normal o fallida (${P2:-fallo}) -> no reinicio"
    fi
  else
    N=$((N+1)); [ $((N%CADA)) -eq 0 ] && log "OK (${P1}% ${COLOR})"
  fi
  sleep "$INTERVALO"
done
WDEOF
chmod +x /usr/local/bin/kiosk-watchdog.sh

cat > /etc/systemd/system/kiosk-watchdog.service << 'EOF'
[Unit]
Description=Gavi Burger - watchdog de pantalla negra (reinicia si se queda colgada)
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/kiosk-watchdog.sh
Restart=always
RestartSec=30
Nice=10
Environment=HOME=/root
Environment=COLOR="#000000"
Environment=UMBRAL=99.0
Environment=INTERVALO=120
Environment=GRACIA=240
Environment=MIN_UPTIME=600

[Install]
WantedBy=multi-user.target
EOF
enable_svc kiosk-watchdog.service

echo "build.sh completado correctamente"
exit 0
