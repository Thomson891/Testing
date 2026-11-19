#!/bin/bash
# Lubuntu laaja järjestelmä-, laitteisto- ja vianmääritystietojen keräysskripti (tuottaa sysinfo.json)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="$SCRIPT_DIR/sysinfo.json"

echo "Kerätään järjestelmä- ja debug-tietoja kohteeseen: $OUT_FILE ..."

python3 - << 'PYEOF' > "$OUT_FILE"
import json
import os
import platform
import socket
import subprocess
from datetime import datetime

def run(cmd):
    try:
        res = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=12)
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

boot_time = run("uptime -s") or "Ei saatavilla"
boot_analyze = run("systemd-analyze 2>/dev/null | head -n 1") or "Ei saatavilla"
last_boots = [line.strip() for line in run("last -x reboot -n 5 2>/dev/null").splitlines() if line.strip() and not line.startswith("wtmp")]

system_info = {
    "hostname": socket.gethostname(),
    "user": os.environ.get("USER", run("whoami")),
    "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "os_name": os_release.get("PRETTY_NAME", platform.platform()),
    "kernel": platform.release(),
    "architecture": platform.machine(),
    "uptime": uptime_str,
    "boot_time": boot_time,
    "boot_analyze": boot_analyze,
    "desktop_env": os.environ.get("XDG_CURRENT_DESKTOP", "LXQt / Lubuntu"),
    "logged_in_users": [line.strip() for line in run("who").splitlines() if line.strip()],
    "last_boots": last_boots
}

# 2. Prosessori (CPU) & Kuormitus
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
                mem_data[parts[0].rstrip(":")] = int(parts[1])

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

# 4. Laitteisto, Lämpötilat & Ydinmoduulit
board_vendor = run("cat /sys/devices/virtual/dmi/id/board_vendor 2>/dev/null")
board_name = run("cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null")
bios_ver = run("cat /sys/devices/virtual/dmi/id/bios_version 2>/dev/null")
gpu = run("lspci | grep -iE 'vga|3d|display' | cut -d':' -f3")
usb_devices = [line.strip() for line in run("lsusb").splitlines() if line.strip()]
pci_devices = [line.strip() for line in run("lspci").splitlines() if line.strip()]

# Lämpötilat (/sys/class/thermal ja sensors)
thermals = []
thermal_base = "/sys/class/thermal"
if os.path.isdir(thermal_base):
    for entry in sorted(os.listdir(thermal_base)):
        if entry.startswith("thermal_zone"):
            t_type = run(f"cat {thermal_base}/{entry}/type 2>/dev/null") or entry
            t_val = run(f"cat {thermal_base}/{entry}/temp 2>/dev/null")
            if t_val.isdigit():
                thermals.append(f"{t_type}: {round(int(t_val) / 1000.0, 1)} °C")

sensors_out = run("sensors 2>/dev/null")
if sensors_out:
    thermals.extend([line.strip() for line in sensors_out.splitlines() if "°C" in line])

# Akku / virta (jos kannettava)
power_supplies = []
ps_base = "/sys/class/power_supply"
if os.path.isdir(ps_base):
    for entry in sorted(os.listdir(ps_base)):
        status = run(f"cat {ps_base}/{entry}/status 2>/dev/null")
        cap = run(f"cat {ps_base}/{entry}/capacity 2>/dev/null")
        online = run(f"cat {ps_base}/{entry}/online 2>/dev/null")
        if cap:
            power_supplies.append(f"{entry}: {cap}% ({status})")
        elif online:
            power_supplies.append(f"{entry}: {'Kytketty' if online == '1' else 'Ei kytketty'}")

kernel_modules = [line.split()[0] for line in run("lsmod | tail -n +2 | sort").splitlines() if line.strip()]

hardware_info = {
    "motherboard": f"{board_vendor} {board_name}".strip() or "Virtuaalikone / Tuntematon",
    "bios": bios_ver or "Ei saatavilla",
    "gpu": gpu or "Ei erillistä näytönohjainta",
    "thermals": thermals or ["Ei lämpötila-antureita (esim. virtuaalikone)"],
    "power": power_supplies or ["Verkkovirta / Ei akkutietoja"],
    "usb_devices": usb_devices,
    "pci_devices": pci_devices,
    "kernel_modules_count": len(kernel_modules),
    "kernel_modules": kernel_modules
}

# 5. Tallennustila (Levyt, osiot ja inodet)
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

inode_out = run("df -i -x tmpfs -x devtmpfs -x squashfs --output=source,itotal,iused,iavail,ipcent,target | tail -n +2")
block_devices = run("lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL")

# 6. Verkkoasetukset, Reititys & Palomuuri
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

default_gw = run("ip route | grep default | awk '{print $3, $5}'")
dns_servers = [line.split()[1] for line in run("grep '^nameserver' /etc/resolv.conf").splitlines() if len(line.split()) >= 2]
routing_table = run("ip route")
listening_ports = [line.strip() for line in run("ss -tulnp 2>/dev/null | tail -n +2").splitlines() if line.strip()]
ufw_status = run("ufw status 2>/dev/null") or "Ei käytössä tai vaatii pääkäyttäjän oikeudet"

network_info = {
    "interfaces": interfaces,
    "gateway": default_gw or "Ei oletusyhdyskäytävää",
    "dns": dns_servers,
    "routing_table": routing_table,
    "ufw_status": ufw_status,
    "listening_ports": listening_ports
}

# 7. Aktiiviset prosessit (Top 20 muistin ja Top 10 CPU:n mukaan)
top_mem_processes = []
for line in run("ps -eo pid,user,%cpu,%mem,state,comm --sort=-%mem | head -n 21 | tail -n +2").splitlines():
    parts = line.split(None, 5)
    if len(parts) == 6:
        top_mem_processes.append({
            "pid": parts[0],
            "user": parts[1],
            "cpu": parts[2],
            "mem": parts[3],
            "state": parts[4],
            "command": parts[5]
        })

top_cpu_processes = []
for line in run("ps -eo pid,user,%cpu,%mem,state,comm --sort=-%cpu | head -n 11 | tail -n +2").splitlines():
    parts = line.split(None, 5)
    if len(parts) == 6:
        top_cpu_processes.append({
            "pid": parts[0],
            "user": parts[1],
            "cpu": parts[2],
            "mem": parts[3],
            "state": parts[4],
            "command": parts[5]
        })

# 8. Palvelut, Ajastukset (Cron/Timers) ja Debug-lokit
running_services = [line.split()[0] for line in run("systemctl list-units --type=service --state=running --no-pager --no-legend").splitlines() if line.strip()]
failed_services = [line.strip() for line in run("systemctl list-units --state=failed --no-pager --no-legend").splitlines() if line.strip()]
systemd_timers = [line.strip() for line in run("systemctl list-timers --all --no-pager --no-legend").splitlines() if line.strip()]
user_crontab = run("crontab -l 2>/dev/null") or "Ei käyttäjän omia cron-ajastuksia"
system_cron = run("ls -1 /etc/cron.d /etc/cron.daily /etc/cron.hourly 2>/dev/null")

# Debug- ja vikatilaviestit
journal_errors = [line.strip() for line in run("journalctl -p err..emerg -n 40 --no-pager 2>/dev/null").splitlines() if line.strip()]
journal_warnings = [line.strip() for line in run("journalctl -p warning -n 30 --no-pager 2>/dev/null").splitlines() if line.strip()]
dmesg_errors = [line.strip() for line in run("dmesg -T --level=emerg,alert,crit,err,warn 2>/dev/null | tail -n 40").splitlines() if line.strip()]
oom_kills = [line.strip() for line in run("dmesg -T 2>/dev/null | grep -iE 'killed process|out of memory|oom' | tail -n 15").splitlines() if line.strip()]

debug_info = {
    "failed_services": failed_services,
    "journal_errors": journal_errors,
    "journal_warnings": journal_warnings,
    "dmesg_errors": dmesg_errors,
    "oom_kills": oom_kills,
    "systemd_timers": systemd_timers,
    "user_crontab": user_crontab,
    "system_cron": system_cron
}

# 9. Asennetut ohjelmat / paketit
packages = []
dpkg_out = run("dpkg-query -W -f='${Package}\t${Version}\t${Installed-Size}\n' | sort")
for line in dpkg_out.splitlines():
    parts = line.split("\t")
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
    "inodes": inode_out,
    "block_devices": block_devices,
    "network": network_info,
    "processes_mem": top_mem_processes,
    "processes_cpu": top_cpu_processes,
    "services": running_services,
    "debug": debug_info,
    "packages": packages
}

print(json.dumps(data, ensure_ascii=False, indent=2))
PYEOF

echo "Valmis! Laajat tiedot tallennettu tiedostoon: $OUT_FILE"
