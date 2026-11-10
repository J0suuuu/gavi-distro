#!/bin/bash
# ==============================================================================
# 1. CONEXIÓN WI-FI, LÍMITE DE CPU Y SSH (Configuraciones nuevas)
# ==============================================================================

# Conectar a la red Wi-Fi automáticamente al arrancar
nmcli radio wifi on
nmcli dev wifi connect "Telecable_feNq" password "m3F9C3YA"

# Limitar la CPU (Intel P-State)
if [ -f /sys/devices/system/cpu/intel_pstate/max_perf_pct ]; then
    echo 650000 | tee /sys/devices/system/cpu/intel_pstate/max_perf_pct
fi

# Habilitar e iniciar el servidor SSH
systemctl enable ssh
systemctl start ssh


# ==============================================================================
# 2. AGENTE DE REINICIO POR API (Python y Systemd)
# ==============================================================================

# Crear el script de Python con protección contra bucles infinitos
cat << 'EOF' > /usr/local/bin/reboot-agent.py
#!/usr/bin/env python3
import json
import time
import urllib.request
import urllib.parse
import os

API = "https://supermercadosalacasa.es/api.php"
SCREEN = "Poligono entrada"
STATE_FILE = "/var/lib/reboot-agent-state"

def api_request(action):
    params = urllib.parse.urlencode({
        "action": action,
        "screen": SCREEN
    })
    url = API + "?" + params
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.loads(response.read().decode())

def get_last_reboot():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE, "r") as f:
            return f.read().strip()
    return None

def save_last_reboot(requested_at):
    with open(STATE_FILE, "w") as f:
        f.write(str(requested_at))

while True:
    try:
        ping = api_request("ping_reboot")
        status = api_request("get_reboot")
        pending = status.get('pending')
        requested_at = status.get('requested_at')
        
        print(f"Conectado | Ping: {ping} | Reinicio pendiente: {pending}", flush=True)
        
        if pending and requested_at:
            last_processed = get_last_reboot()
            if str(requested_at) != last_processed:
                print(f"Nueva orden de reinicio recibida ({requested_at}). Reiniciando...", flush=True)
                save_last_reboot(requested_at)
                os.system("systemctl reboot -i")
                break
            else:
                print("Orden de reinicio ya procesada. Esperando...", flush=True)
            
    except Exception as error:
        print(f"Error de conexión: {error}", flush=True)
        
    time.sleep(5)
EOF

chmod +x /usr/local/bin/reboot-agent.py

# Crear servicio systemd para el agente
cat << 'EOF' > /etc/systemd/system/reboot-agent.service
[Unit]
Description=Viridian Reboot Agent
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/reboot-agent.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable reboot-agent.service
systemctl start reboot-agent.service


# ==============================================================================
# 3. REFRESCO DE FIREFOX (Tu código original intacto)
# ==============================================================================

# Asegúrate de que aquí esté la primera parte de tu bucle original 
# (la que define el sleep o la búsqueda de la ventana). 
# Esta es la estructura unida para que no pise nada:

(
    # --- INICIO DE TU CÓDIGO ORIGINAL (Pega aquí si faltaba algo del while) ---
    while true; do
        WINDOW=$(xdotool search --onlyvisible --class firefox 2>/dev/null | head -n 1)
        
        # Esta es la parte que me pasaste y que se mantiene igual:
        if [ -n "$WINDOW" ]; then
            xdotool key --window "$WINDOW" ctrl+r
        fi
        
        sleep 60 # O el tiempo de espera que tuvieras originalmente
    done
) >/tmp/firefox-refresh.log 2>&1 &
