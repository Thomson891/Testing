#!/bin/bash
# Lubuntu laaja järjestelmä- ja laitteistotietojen keräysskripti (tuottaa sysinfo.json)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="$SCRIPT_DIR/sysinfo.json"

echo "Kerätään järjestelmätietoja kohteeseen: $OUT_FILE ..."

python3 - << 'PYEOF' > "$OUT_FILE"
import json
import os
import platform
import socket
import subprocess
from datetime import datetime

def run(cmd):
    try:
        res = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=10)
        return res.stdout.strip()
    except Exception:
        return ""

# 1. Perustiedot & Käyttöjärjestelmä
os_release = {}
if os.path.exists("/etc/os-release"):
    with open("/etc/os-release") as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                os_release[k] = v.strip('"')

uptime_sec = 0
if os.path.exists("/proc/uptime"):
    with open("/proc/uptime") as f:
        uptime_sec = float(f.read().split()[0])

days = int(uptime_sec // 86400)
hours = int((uptime_sec % 86400) // 3600)
mins = int((uptime_sec % 3600) // 60)
uptime_str = f"{days} pv {hours} t {mins} min"

system_info = {
    "hostname": socket.gethostname(),
    "user": os.environ.get("USER", run("whoami")),
    "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "os_name": os_release.get("PRETTY_NAME", platform.platform()),
    "kernel": platform.release(),
    "architecture": platform.machine(),
    "uptime": uptime_str,
    "desktop_env": os.environ.get("XDG_CURRENT_DESKTOP", "LXQt / Lubuntu")
}

# 2. Prosessori (CPU)
cpu_model = "Tuntematon"
cpu_cores = os.cpu_count() or 1
cpu_mhz = ""
if os.path.exists("/proc/cpuinfo"):
    with open("/proc/cpuinfo") as f:
        for line in f:
            if "model name" in line and cpu_model == "Tuntematon":
                cpu_model = line.split(":", 1)[1].strip()
            if "cpu MHz" in line and not cpu_mhz:
                cpu_mhz = f"{float(line.split(':', 1)[1].strip()):.0f} MHz"

load_avg = run("cat /proc/loadavg | awk '{print $1", "$2", "$3}'")

cpu_info = {
    "model": cpu_model,
    "cores": cpu_cores,
    "frequency": cpu_mhz,
    "load_average": load_avg
}

# 3. Keskusmuisti (RAM & Swap)
mem_data = {}
if os.path.exists("/proc/meminfo"):
    with open("/proc/meminfo") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                mem_data[parts[0].rstrip(":")] = int(parts[1]) # kB

total_ram_mb = round(mem_data.get("MemTotal", 0) / 1024)
avail_ram_mb = round(mem_data.get("MemAvailable", 0) / 1024)
used_ram_mb = max(0, total_ram_mb - avail_ram_mb)
ram_percent = round((used_ram_mb / total_ram_mb) * 100, 1) if total_ram_mb > 0 else 0

total_swap_mb = round(mem_data.get("SwapTotal", 0) / 1024)
free_swap_mb = round(mem_data.get("SwapFree", 0) / 1024)
used_swap_mb = max(0, total_swap_mb - free_swap_mb)

memory_info = {
    "total_mb": total_ram_mb,
    "used_mb": used_ram_mb,
    "available_mb": avail_ram_mb,
    "percent": ram_percent,
    "swap_total_mb": total_swap_mb,
    "swap_used_mb": used_swap_mb
}

# 4. Laitteisto (Emolevy, Näytönohjain, USB, PCI)
board_vendor = run("cat /sys/devices/virtual/dmi/id/board_vendor 2>/dev/null")
board_name = run("cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null")
bios_ver = run("cat /sys/devices/virtual/dmi/id/bios_version 2>/dev/null")
gpu = run("lspci | grep -iE 'vga|3d|display' | cut -d':' -f3")
usb_devices = [line.strip() for line in run("lsusb").splitlines() if line.strip()]
pci_devices = [line.strip() for line in run("lspci").splitlines() if line.strip()]

hardware_info = {
    "motherboard": f"{board_vendor} {board_name}".strip() or "Virtuaalikone / Tuntematon",
    "bios": bios_ver or "Ei saatavilla",
    "gpu": gpu or "Ei erillistä näytönohjainta",
    "usb_devices": usb_devices,
    "pci_devices": pci_devices
}

# 5. Tallennustila (Levyt ja osiot)
disks = []
df_out = run("df -h -x tmpfs -x devtmpfs -x squashfs --output=source,fstype,size,used,avail,pcent,target | tail -n +2")
for line in df_out.splitlines():
    parts = line.split()
    if len(parts) >= 7:
        disks.append({
            "device": parts[0],
            "fstype": parts[1],
            "size": parts[2],
            "used": parts[3],
            "avail": parts[4],
            "percent": parts[5].rstrip("%"),
            "mount": " ".join(parts[6:])
        })

block_devices = run("lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT")

# 6. Verkkoasetukset
interfaces = []
ip_out = run("ip -brief address")
for line in ip_out.splitlines():
    parts = line.split()
    if len(parts) >= 2:
        interfaces.append({
            "name": parts[0],
            "state": parts[1],
            "addresses": ", ".join(parts[2:]) if len(parts) > 2 else "Ei IP-osoitetta"
        })

default_gw = run("ip route | grep default | awk '{print $3 " (" $5 ")"}'")
dns_servers = [line.split()[1] for line in run("grep '^nameserver' /etc/resolv.conf").splitlines() if len(line.split()) >= 2]
listening_ports = [line.strip() for line in run("ss -tuln | tail -n +2").splitlines() if line.strip()]

network_info = {
    "interfaces": interfaces,
    "gateway": default_gw or "Ei oletusyhdyskäytävää",
    "dns": dns_servers,
    "listening_ports": listening_ports
}

# 7. Aktiiviset prosessit (Top 15 muistin/CPU:n mukaan)
processes = []
ps_out = run("ps -eo pid,user,%cpu,%mem,comm --sort=-%mem | head -n 16 | tail -n +2")
for line in ps_out.splitlines():
    parts = line.split(None, 4)
    if len(parts) == 5:
        processes.append({
            "pid": parts[0],
            "user": parts[1],
            "cpu": parts[2],
            "mem": parts[3],
            "command": parts[4]
        })

# 8. Palvelut ja järjestelmäloki
running_services = [line.split()[0] for line in run("systemctl list-units --type=service --state=running --no-pager --no-legend").splitlines() if line.strip()]
recent_errors = [line.strip() for line in run("journalctl -p err -n 15 --no-pager 2>/dev/null").splitlines() if line.strip()]

# 9. Asennetut ohjelmat / paketit
packages = []
dpkg_out = run("dpkg-query -W -f='${Package}\t${Version}\t${Installed-Size}\n' | sort")
for line in dpkg_out.splitlines():
    parts = line.split("	")
    if len(parts) >= 2:
        size_kb = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
        packages.append({
            "name": parts[0],
            "version": parts[1],
            "size_mb": round(size_kb / 1024, 1)
        })

data = {
    "system": system_info,
    "cpu": cpu_info,
    "memory": memory_info,
    "hardware": hardware_info,
    "disks": disks,
    "block_devices": block_devices,
    "network": network_info,
    "processes": processes,
    "services": running_services,
    "recent_errors": recent_errors,
    "packages": packages
}

print(json.dumps(data, ensure_ascii=False, indent=2))
PYEOF

echo "Valmis! Tiedot tallennettu tiedostoon: $OUT_FILE"
