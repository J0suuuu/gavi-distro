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
# 1. WIFI - archivo de conexión (solo crea, no modifica nada)
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
# 4. CONTRASEÑA USUARIO LIVE (reaplica en cada boot)
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
# 5. AGENTE DE REINICIO (con protección antibucle)
# ============================================================
cat > /usr/local/bin/reboot-agent.py << 'PYEOF'
#!/usr/bin/env python3
import json, time, os, sys
import urllib.request, urllib.parse

API = "https://gaviburger.com/api.php"
SCREEN = "pantalla 1"
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
    log("Sincronizando disco...")
    os.system("sync")
    os.system("sync")
    os.system("echo 1 > /proc/sys/kernel/sysrq 2>/dev/null")
    log("Reboot via sysrq...")
    try:
        with open("/proc/sysrq-trigger", "w") as f:
            f.write("b")
    except Exception as e:
        log(f"sysrq fallo: {e}")
    time.sleep(3)
    os.system("reboot -f")
    time.sleep(3)
    os.system("systemctl reboot -ff")

# Protección antibucle: registrar timestamp de este boot
boot_ts = str(int(time.time()))
try:
    prev_boot = open(BOOT_FILE).read().strip() if os.path.exists(BOOT_FILE) else "0"
    open(BOOT_FILE, "w").write(boot_ts)
    log(f"Boot detectado: {boot_ts} (anterior: {prev_boot})")
    # Si el boot anterior fue hace menos de 10 segundos → posible bucle, esperar 60s
    try:
        if int(boot_ts) - int(prev_boot) < 10:
            log("Posible bucle detectado, esperando 60s antes de actuar...")
            time.sleep(60)
    except Exception:
        pass
except Exception:
    pass

# Esperar a que la red esté disponible antes de consultar
for i in range(30):
    try:
        api("ping_reboot")
        log("Red disponible")
        break
    except Exception:
        log(f"Esperando red... ({i+1}/30)")
        time.sleep(2)

log(f"Arrancando agente para pantalla: {SCREEN}")
while True:
    try:
        api("ping_reboot")
        s = api("get_reboot")
        pend = s.get("pending", False)
        rat = s.get("requested_at")
        log(f"pending={pend} requested_at={rat}")
        if pend and rat and str(rat) != str(last()):
            log(f"Nueva orden de reinicio ({rat}). Reiniciando...")
            save(rat)
            force_reboot()
            sys.exit(0)
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
# 6. REFRESCO DE FIREFOX
# ============================================================
cat > /usr/local/bin/firefox-refresh.sh << 'EOF'
#!/bin/bash
sleep 30
setup_env() {
    KUID=$(id -u linuxlive-kiosk 2>/dev/null || echo 1000)
    export XDG_RUNTIME_DIR="/run/user/$KUID"
    export DISPLAY="${DISPLAY:-:0}"
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    [ -d "$XDG_RUNTIME_DIR" ] && export XAUTHORITY="$XDG_RUNTIME_DIR/Xauthority"
}
do_refresh() {
    setup_env
    WINDOW=$(xdotool search --onlyvisible --class firefox 2>/dev/null | head -n 1)
    if [ -n "$WINDOW" ]; then
        xdotool key --window "$WINDOW" ctrl+r 2>/dev/null
        echo "[firefox-refresh] $(date '+%H:%M:%S') -> refrescado (uptime $(awk '{print int($1)}' /proc/uptime)s)"
    fi
}
FASE1_DURATION=240
FASE1_INTERVAL=30
FASE2_INTERVAL=7200
do_refresh
while true; do
    UPTIME=$(awk '{print int($1)}' /proc/uptime)
    if [ "$UPTIME" -lt "$FASE1_DURATION" ]; then
        SLEEP_FOR="$FASE1_INTERVAL"
        REMAINING=$(( FASE1_DURATION - UPTIME ))
        [ "$REMAINING" -lt "$SLEEP_FOR" ] && SLEEP_FOR="$REMAINING"
    else
        SLEEP_FOR="$FASE2_INTERVAL"
    fi
    sleep "$SLEEP_FOR"
    do_refresh
done
EOF
chmod +x /usr/local/bin/firefox-refresh.sh

cat > /etc/systemd/system/firefox-refresh.service << 'EOF'
[Unit]
Description=Gavi Burger - refresco de Firefox
After=graphical.target

[Service]
Type=simple
ExecStart=/usr/local/bin/firefox-refresh.sh
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
EOF
enable_svc firefox-refresh.service graphical.target

# ============================================================
# 7. SUPRIMIR PROMPT "REMOVE INSTALLATION MEDIUM" via drop-in
#    NO se toca ningún archivo existente de la ISO
# ============================================================
mkdir -p /etc/sysctl.d
echo "kernel.sysrq=1" > /etc/sysctl.d/99-gavi-sysrq.conf

# Drop-in de systemd que oculta el prompt final de casper
mkdir -p /etc/systemd/system/casper.service.d
cat > /etc/systemd/system/casper.service.d/override.conf << 'EOF'
[Service]
StandardInput=null
StandardOutput=journal
StandardError=journal
EOF

# Drop-in para systemd-logind (permite reboot sin pedir confirmación)
mkdir -p /etc/systemd/system/systemd-logind.service.d
cat > /etc/systemd/system/systemd-logind.service.d/reboot.conf << 'EOF'
[Service]
Environment=SYSTEMD_LOG_LEVEL=info
EOF

# NO hay update-initramfs ni sed sobre archivos de casper
# Todo se hace creando archivos nuevos, nunca modificando existentes

echo "build.sh completado correctamente"
exit 0
