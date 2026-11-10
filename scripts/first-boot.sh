#!/bin/bash
# ==============================================================================
# 1. CONEXIÓN WI-FI (Inyección directa en NetworkManager)
# ==============================================================================

# Generar UUID para la conexión
UUID=$(cat /proc/sys/kernel/random/uuid)

# Crear archivo de conexión persistente
cat << EOF > /etc/NetworkManager/system-connections/Telecable_feNq.nmconnection
[connection]
id=Telecable_feNq
uuid=$UUID
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

# Permisos obligatorios para que NetworkManager lo lea
chmod 600 /etc/NetworkManager/system-connections/Telecable_feNq.nmconnection

# Recargar NetworkManager y conectar
nmcli connection reload
nmcli connection up Telecable_feNq

# ==============================================================================
# 2. LÍMITE DE CPU (Intel P-State)
# ==============================================================================

if [ -f /sys/devices/system/cpu/intel_pstate/max_perf_pct ]; then
    echo 650000 | tee /sys/devices/system/cpu/intel_pstate/max_perf_pct
fi

# ==============================================================================
# 3. SERVIDOR SSH
# ==============================================================================

systemctl enable ssh
systemctl start ssh

# ==============================================================================
# 4. CAMBIAR CONTRASEÑA DEL USUARIO "live"
# ==============================================================================

echo "live:holakase" | chpasswd

# ==============================================================================
# 5. AGENTE DE REINICIO POR API (Python mejorado y Systemd)
# ==============================================================================

cat << 'EOF' > /usr/local/bin/reboot-agent.py
#!/usr/bin/env python3
import json
import time
import urllib.request
import urllib.parse
import os
import sys

API = "https://supermercadosalacasa.es/api.php"
SCREEN = "Poligono entrada"
STATE_FILE = "/var/lib/reboot-agent-state"

def log(msg):
    print(f"[reboot-agent] {msg}", flush=True)

def api_request(action):
    params = urllib.parse.urlencode({
        "action": action,
        "screen": SCREEN
    })
    url = API + "?" + params
    req = urllib.request.Request(url, headers={'User-Agent': 'RebootAgent/1.0'})
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.loads(response.read().decode())

def get_last_reboot():
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE, "r") as f:
                return f.read().strip()
    except Exception as e:
        log(f"Error reading state: {e}")
    return None

def save_last_reboot(requested_at):
    try:
        with open(STATE_FILE, "w") as f:
            f.write(str(requested_at))
    except Exception as e:
        log(f"Error saving state: {e}")

def main():
    log(f"Starting reboot agent for screen: {SCREEN}")
    
    while True:
        try:
            # Hacer ping para mantener el estado online
            ping = api_request("ping_reboot")
            log(f"Ping response: {ping}")
            
            # Consultar si hay reinicio pendiente
            status = api_request("get_reboot")
            pending = status.get('pending', False)
            requested_at = status.get('requested_at')
            
            log(f"Reboot status: pending={pending}, requested_at={requested_at}")
            
            if pending and requested_at:
                last_processed = get_last_reboot()
                
                if str(requested_at) != str(last_processed):
                    log(f"New reboot request detected: {requested_at} (last: {last_processed})")
                    save_last_reboot(requested_at)
                    log("Executing reboot...")
                    os.system("systemctl reboot -i")
                    sys.exit(0)
                else:
                    log("Reboot request already processed, waiting...")
            else:
                log("No pending reboot request")
                
        except urllib.error.URLError as e:
            log(f"Network error: {e}")
        except json.JSONDecodeError as e:
            log(f"JSON parse error: {e}")
        except Exception as e:
            log(f"Unexpected error: {e}")
            
        time.sleep(5)

if __name__ == "__main__":
    main()
EOF

chmod +x /usr/local/bin/reboot-agent.py

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
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable reboot-agent.service
systemctl start reboot-agent.service

# ==============================================================================
# 6. REFRESCO DE FIREFOX (Tu código original intacto)
# ==============================================================================

# Pega aquí tu bucle completo de refresco. Ejemplo de estructura:
(
    while true; do
        WINDOW=$(xdotool search --onlyvisible --class firefox 2>/dev/null | head -n 1)
        
        if [ -n "$WINDOW" ]; then
            xdotool key --window "$WINDOW" ctrl+r
        fi
        
        sleep 60  # Ajusta este valor si tu script original usaba otro tiempo
    done
) >/tmp/firefox-refresh.log 2>&1 &
