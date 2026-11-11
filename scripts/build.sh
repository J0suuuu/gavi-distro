#!/bin/bash
# Se ejecuta como root DURANTE la construcción de la ISO.
# Todo queda grabado en la imagen y funciona en Live y en instalado.

# ---------------------------------------------------------------------------
# Helper: habilitar un servicio systemd creando el symlink a mano
# (a prueba de fallos: no depende de que systemd esté corriendo en el build)
# ---------------------------------------------------------------------------
enable_svc() {
    local svc="$1"
    local target="${2:-multi-user.target}"
    local path=""
    for d in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
        [ -f "$d/$svc" ] && { path="$d/$svc"; break; }
    done
    [ -z "$path" ] && { echo "AVISO: $svc no encontrado"; return 0; }
    mkdir -p "/etc/systemd/system/${target}.wants"
    ln -sf "$path" "/etc/systemd/system/${target}.wants/${svc}"
}

# ===========================================================================
# 1. WIFI — archivo de conexión de NetworkManager grabado en la ISO
# ===========================================================================
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "b1f2a3c4-0000-1111-2222-333344445555")
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/Telecable_feNq.nmconnection << EOF
[connection]
id=Telecable_feNq
uuid=${UUID}
type=wifi
autoconnect=true
permissions=

[wifi]
mode=infrastructure
ssid=Telecable_feNq

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=m3F9C3YA

[ipv4]
method=auto

[ipv6]
addr-gen-mode=stable-privacy
method=auto
EOF
chmod 600 /etc/NetworkManager/system-connections/Telecable_feNq.nmconnection

# ===========================================================================
# 2. LÍMITE DE CPU — servicio oneshot en cada arranque
#    (el valor de /sys se resetea en cada boot, por eso va como servicio)
# ===========================================================================
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

# ===========================================================================
# 3. SSH — habilitar el servicio
# ===========================================================================
enable_svc ssh.service

# ===========================================================================
# 4. CONTRASEÑA DEL USUARIO "live" — servicio que la reaplica en cada boot
#    (casper recrea/bloquea el usuario live en cada arranque)
# ===========================================================================
cat > /usr/local/sbin/gavi-set-password.sh << 'EOF'
#!/bin/bash
# Reintenta hasta que casper cree el usuario live (hasta ~60s)
for i in $(seq 1 30); do
    if id live >/dev/null 2>&1; then
        echo "live:holakase" | chpasswd
        passwd -u live >/dev/null 2>&1
        exit 0
    fi
    sleep 2
done
# Respaldo por si el usuario tiene otro nombre
for u in live ubuntu casper; do
    if id "$u" >/dev/null 2>&1; then
        echo "${u}:holakase" | chpasswd
        passwd -u "$u" >/dev/null 2>&1
    fi
done
exit 0
EOF
chmod +x /usr/local/sbin/gavi-set-password.sh

cat > /etc/systemd/system/gavi-set-password.service << 'EOF'
[Unit]
Description=Gavi Burger - password usuario live
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

# ===========================================================================
# 5. AGENTE DE REINICIO — script Python + servicio
#    Incluye force_reboot() para saltar el prompt de casper
# ===========================================================================
cat > /usr/local/bin/reboot-agent.py << 'PYEOF'
#!/usr/bin/env python3
import json, time, os, sys
import urllib.request, urllib.parse

API = "https://gaviburger.com/api.php"
SCREEN = "pantalla 1"
STATE_FILE = "/var/lib/reboot-agent-state"

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
    """Reboot forzado que salta el prompt de casper"""
    log("Sincronizando disco...")
    os.system("sync")
    os.system("sync")
    
    # Habilitar sysrq si no lo está
    os.system("echo 1 > /proc/sys/kernel/sysrq 2>/dev/null")
    
    # Reboot inmediato a nivel de kernel (salta todo el shutdown de casper)
    log("Reboot via sysrq...")
    try:
        with open("/proc/sysrq-trigger", "w") as f:
            f.write("b")
    except Exception as e:
        log(f"sysrq fallo: {e}")
    
    # Si sysrq no funcionó, intentar métodos alternativos
    time.sleep(3)
    os.system("reboot -f")
    time.sleep(3)
    os.system("systemctl reboot -ff")

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
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
enable_svc reboot-agent.service

# ===========================================================================
# 6. REFRESCO DE FIREFOX — dos fases según uptime
#    Fase 1: primeros 4 min (240s) → refresh cada 30s
#    Fase 2: después → refresh cada 2h (7200s)
# ===========================================================================
cat > /usr/local/bin/firefox-refresh.sh << 'EOF'
#!/bin/bash

# --- Espera inicial para que Firefox arranque ---
sleep 20

# Variables de entorno del kiosco (para que xdotool pueda encontrar Firefox)
setup_env() {
    KUID=$(id -u linuxlive-kiosk 2>/dev/null || echo 1000)
    export XDG_RUNTIME_DIR="/run/user/$KUID"
    export DISPLAY="${DISPLAY:-:0}"
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    if [ -d "$XDG_RUNTIME_DIR" ]; then
        export XAUTHORITY="$XDG_RUNTIME_DIR/Xauthority"
    fi
}

# --- Función que hace un refresh de Firefox ---
do_refresh() {
    setup_env
    WINDOW=$(xdotool search --onlyvisible --class firefox 2>/dev/null | head -n 1)
    if [ -n "$WINDOW" ]; then
        xdotool key --window "$WINDOW" ctrl+r 2>/dev/null
        echo "[firefox-refresh] $(date '+%H:%M:%S') -> refrescado (uptime $(awk '{print int($1)}' /proc/uptime)s)"
    fi
}

# --- Umbrales ---
FASE1_DURATION=240   # 4 minutos
FASE1_INTERVAL=30    # 30 segundos
FASE2_INTERVAL=7200  # 2 horas

# --- Refrescar nada más empezar ---
do_refresh

# --- Bucle principal con dos fases ---
while true; do
    UPTIME=$(awk '{print int($1)}' /proc/uptime)

    if [ "$UPTIME" -lt "$FASE1_DURATION" ]; then
        # FASE 1: arranque → 4 minutos (cada 30s)
        SLEEP_FOR="$FASE1_INTERVAL"
        # No sobrepasar el límite de la fase 1
        REMAINING=$(( FASE1_DURATION - UPTIME ))
        [ "$REMAINING" -lt "$SLEEP_FOR" ] && SLEEP_FOR="$REMAINING"
    else
        # FASE 2: después de 4 minutos (cada 2h)
        SLEEP_FOR="$FASE2_INTERVAL"
    fi

    sleep "$SLEEP_FOR"
    do_refresh
done
EOF
chmod +x /usr/local/bin/firefox-refresh.sh

cat > /etc/systemd/system/firefox-refresh.service << 'EOF'
[Unit]
Description=Gavi Burger - refresco de Firefox (30s primeros 4min, luego 2h)
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

# ===========================================================================
# 7. ELIMINAR PROMPT "REMOVE INSTALLATION MEDIUM" DE CASPER
#    Crítico para kioscos desatendidos: sin esto el reboot se queda colgado
# ===========================================================================

# Habilitar sysrq permanentemente (para el reboot forzado del agente)
mkdir -p /etc/sysctl.d
echo "kernel.sysrq=1" > /etc/sysctl.d/99-gavi-sysrq.conf

# Modificar /etc/init.d/casper si existe (eliminar el prompt y el read)
if [ -f /etc/init.d/casper ]; then
    sed -i 's/.*[Pp]lease remove the installation medium.*/    true  # kiosk: prompt removed/' /etc/init.d/casper
    sed -i '/kiosk: prompt removed/{n;s/^\s*read.*/    true  # kiosk: read removed/}' /etc/init.d/casper
fi

# Buscar el prompt en scripts de shutdown de systemd
for dir in /lib/systemd/system-shutdown /usr/lib/systemd/system-shutdown /etc/systemd/system-shutdown; do
    if [ -d "$dir" ]; then
        for f in "$dir"/*; do
            [ -f "$f" ] && sed -i 's/.*[Pp]lease remove the installation medium.*/true/' "$f" 2>/dev/null
        done
    fi
done

# Buscar en cualquier script de casper
find /usr/share /etc /lib -name "*casper*" -type f 2>/dev/null | while read f; do
    sed -i 's/.*[Pp]lease remove the installation medium.*/true/' "$f" 2>/dev/null || true
done

# Reconstruir initramfs para aplicar cambios de casper
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u 2>/dev/null || true
fi

echo "build.sh completado correctamente"
