#!/bin/bash
# Este script se ejecuta automáticamente como root en el primer arranque

# 1. Conectar a la red Wi-Fi automáticamente
nmcli radio wifi on
nmcli dev wifi connect "Telecable_feNq" password "m3F9C3YA"

# 2. Limitar la CPU (Intel P-State) al valor deseado
if [ -f /sys/devices/system/cpu/intel_pstate/max_perf_pct ]; then
    echo 650000 | tee /sys/devices/system/cpu/intel_pstate/max_perf_pct
fi

# 3. Habilitar e iniciar el servidor SSH
systemctl enable ssh
systemctl start ssh

# 4. Crear el script de Python mejorado para el agente de reinicio
cat << 'EOF' > /usr/local/bin/reboot-agent.py
#!/usr/bin/env python3
import json
import time
import urllib.request
import urllib.parse
import os

API = "https://gaviburger.com/api.php"
SCREEN = "pantalla 1"
STATE_FILE = "/var/lib/reboot-agent-state" # Archivo para evitar reinicios en bucle

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
        
        # Si hay un reinicio pendiente y la marca de tiempo es nueva
        if pending and requested_at:
            last_processed = get_last_reboot()
            if str(requested_at) != last_processed:
                print(f"Nueva orden de reinicio recibida ({requested_at}). Reiniciando...", flush=True)
                save_last_reboot(requested_at)
                os.system("systemctl reboot -i") # -i ignora inhibidores como el kiosco
                break
            else:
                print("Orden de reinicio ya procesada. Esperando...", flush=True)
            
    except Exception as error:
        print(f"Error de conexión: {error}", flush=True)
        
    time.sleep(5)
EOF

chmod +x /usr/local/bin/reboot-agent.py

# 5. Crear el servicio de systemd para que el agente arranque siempre
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
