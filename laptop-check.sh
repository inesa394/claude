#!/usr/bin/env bash
# laptop-check.sh – prüft den Laptop auf Systemfehler und Netzwerkprobleme.
# Funktioniert unter Linux und macOS. Aufruf:  ./laptop-check.sh [-o report.txt]
# Hinweis: Mit sudo ausgeführt werden mehr Logs lesbar.

set -u
OUT=""
while getopts "o:h" opt; do
  case $opt in
    o) OUT="$OPTARG" ;;
    *) echo "Nutzung: $0 [-o berichtsdatei]"; exit 0 ;;
  esac
done
[ -n "$OUT" ] && exec > >(tee "$OUT") 2>&1

OS=$(uname -s)
PROBLEMS=0
have() { command -v "$1" >/dev/null 2>&1; }
hdr()  { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  [OK]   %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; PROBLEMS=$((PROBLEMS+1)); }
info() { printf '         %s\n' "$1"; }

# ---------------------------------------------------------------- System
hdr "System"
info "$(uname -srm) | Host: $(hostname) | $(date)"
if [ "$OS" = Darwin ]; then
  info "Laufzeit:$(uptime | sed 's/.*up/ up/; s/,.*user.*//')"
else
  info "$(uptime -p 2>/dev/null)"
fi

# ---------------------------------------------------------------- Ressourcen
hdr "CPU / Last"
CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
LOAD=$(uptime | awk -F'load averages?: ' '{print $2}' | awk -F'[ ,]+' '{print $1}')
info "Load 1min: $LOAD bei $CORES Kernen"
awk -v l="$LOAD" -v c="$CORES" 'BEGIN{exit !(l>c*1.5)}' && warn "Hohe CPU-Last" || ok "Last normal"

hdr "Arbeitsspeicher"
if [ "$OS" = Linux ] && [ -r /proc/meminfo ]; then
  awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}/SwapTotal/{st=$2}/SwapFree/{sf=$2}
       END{if(t==0||a==0){print "         RAM-Daten nicht lesbar"; exit 0} p=100-a*100/t; printf "         RAM belegt: %.0f%% (%.1f/%.1f GB)\n",p,(t-a)/1048576,t/1048576;
           if(p>90) exit 1}' && ok "RAM ok" || warn "RAM fast voll"
elif have vm_stat; then
  vm_stat | head -5 | sed 's/^/         /'
fi

hdr "Festplatten"
df -hP 2>/dev/null | awk 'NR>1 && $1 ~ /^\/dev\// {print}' | while read -r fs size used avail pct mnt; do
  p=${pct%\%}
  if [ "$p" -ge 90 ]; then warn "$mnt zu $pct voll ($avail frei)"; else ok "$mnt $pct belegt ($avail frei)"; fi
done

hdr "Festplatten-Gesundheit (SMART)"
if have smartctl; then
  for d in /dev/sd? /dev/nvme?n1 /dev/disk0; do
    [ -e "$d" ] || continue
    r=$(smartctl -H "$d" 2>&1 | grep -iE 'result|overall|SMART Status')
    case "$r" in *PASSED*|*Verified*|*OK*) ok "$d: $r";; "") info "$d: keine Daten (evtl. sudo nötig)";; *) warn "$d: $r";; esac
  done
else
  info "smartctl nicht installiert (Linux: smartmontools) – übersprungen"
fi

hdr "Temperatur"
if have sensors; then sensors 2>/dev/null | grep -iE 'core|temp1|Package' | head -6 | sed 's/^/         /'
else info "lm-sensors nicht installiert – übersprungen"; fi

hdr "Akku"
if [ "$OS" = Linux ]; then
  for b in /sys/class/power_supply/BAT*; do
    [ -d "$b" ] || continue
    cap=$(cat "$b/capacity" 2>/dev/null); st=$(cat "$b/status" 2>/dev/null)
    info "$(basename "$b"): ${cap}% ($st)"
    if [ -r "$b/energy_full" ] && [ -r "$b/energy_full_design" ]; then
      h=$(awk -v f="$(cat "$b/energy_full")" -v d="$(cat "$b/energy_full_design")" 'BEGIN{printf "%.0f", f*100/d}')
      [ "$h" -lt 60 ] && warn "Akku-Gesundheit nur $h%" || ok "Akku-Gesundheit $h%"
    fi
  done
elif have pmset; then pmset -g batt | sed 's/^/         /'; fi

hdr "Top-5 Prozesse (CPU)"
ps aux 2>/dev/null | sort -nrk3 | head -6 | awk '{printf "         %s%% CPU  %s%% MEM  %s\n",$3,$4,$11}'

# ---------------------------------------------------------------- Fehler-Logs
hdr "Systemfehler (letzte 24h)"
if [ "$OS" = Linux ]; then
  if have systemctl; then
    f=$(systemctl --failed --no-legend 2>/dev/null)
    [ -n "$f" ] && { warn "Fehlgeschlagene Dienste:"; echo "$f" | sed 's/^/         /'; } || ok "Keine fehlgeschlagenen systemd-Dienste"
  fi
  if have journalctl; then
    n=$(journalctl -p err --since "24 hours ago" --no-pager -q 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
      warn "$n Fehlereinträge im Journal (Top-Quellen):"
      journalctl -p err --since "24 hours ago" --no-pager -q -o short 2>/dev/null \
        | awk '{print $5}' | sed 's/\[.*//; s/:$//' | sort | uniq -c | sort -nr | head -5 | sed 's/^/         /'
    else ok "Keine Fehler im Journal"; fi
  fi
  k=$(dmesg --level=err,crit,alert,emerg 2>/dev/null | tail -5)
  [ -n "$k" ] && { warn "Kernel-Fehler (dmesg):"; echo "$k" | sed 's/^/         /'; }
  dmesg 2>/dev/null | grep -qi 'out of memory' && warn "OOM-Killer wurde ausgelöst"
  dmesg 2>/dev/null | grep -qiE 'I/O error|ata[0-9.]+: .*error' && warn "Festplatten-I/O-Fehler im Kernel-Log"
elif [ "$OS" = Darwin ]; then
  n=$(log show --last 24h --predicate 'messageType == error' 2>/dev/null | wc -l)
  info "$n Fehlermeldungen im Unified Log (24h)"
  ls ~/Library/Logs/DiagnosticReports 2>/dev/null | tail -3 | sed 's/^/         Crash-Report: /'
fi

# ---------------------------------------------------------------- Netzwerk
hdr "Netzwerk-Schnittstellen"
if [ "$OS" = Linux ] && have ip; then
  ip -brief addr 2>/dev/null | sed 's/^/         /'
  ip -brief addr | awk '$1!="lo" && $2=="UP" && $3!=""' | grep -q . && ok "Aktive Verbindung vorhanden" || warn "Keine aktive Netzwerkschnittstelle mit IP"
else
  ifconfig 2>/dev/null | awk '/^[a-z]/{i=$1} /inet /{print "         " i " " $2}'
fi

have ping || echo "  Hinweis: 'ping' fehlt – Ping-Tests liefern WARN."
hdr "Gateway"
if [ "$OS" = Linux ]; then GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
else GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}'); fi
if [ -z "${GW:-}" ]; then warn "Kein Standard-Gateway"
else
  if ping -c 3 -W 2 "$GW" >/dev/null 2>&1 || ping -c 3 -t 6 "$GW" >/dev/null 2>&1; then ok "Gateway $GW erreichbar"
  else warn "Gateway $GW antwortet nicht (WLAN/Router prüfen)"; fi
fi

hdr "Internet (IP-Ebene)"
for ip in 1.1.1.1 8.8.8.8; do
  out=$(ping -c 4 -W 2 "$ip" 2>&1 || ping -c 4 -t 8 "$ip" 2>&1)
  loss=$(echo "$out" | grep -oE '[0-9.]+% packet loss' | head -1)
  avg=$(echo "$out" | awk -F'/' '/min\/avg|round-trip/{print $5}')
  if echo "$out" | grep -qE ' 0(\.0)?% packet loss'; then ok "$ip erreichbar (Ø ${avg:-?} ms)"
  else warn "$ip: ${loss:-keine Antwort}"; fi
done

hdr "DNS"
HOSTS="google.com cloudflare.com github.com"
resolve() {
  if have getent; then getent hosts "$1" >/dev/null 2>&1
  elif have dscacheutil; then dscacheutil -q host -a name "$1" | grep -q ip_address
  elif have nslookup; then nslookup "$1" >/dev/null 2>&1; else return 1; fi
}
for h in $HOSTS; do resolve "$h" && ok "DNS löst $h auf" || warn "DNS kann $h nicht auflösen"; done
if [ -r /etc/resolv.conf ]; then info "Nameserver: $(awk '/^nameserver/{printf "%s ",$2}' /etc/resolv.conf)"; fi

hdr "HTTP/HTTPS"
if have curl; then
  for u in https://www.google.com https://github.com http://neverssl.com; do
    r=$(curl -s -o /dev/null -m 8 -w '%{http_code} %{time_total}s' "$u" 2>/dev/null)
    case "$r" in 2*|3*) ok "$u -> $r";; *) warn "$u -> ${r:-Fehler/Timeout}";; esac
  done
else info "curl fehlt – übersprungen"; fi

hdr "WLAN"
if [ "$OS" = Linux ]; then
  if have nmcli; then nmcli -t -f ACTIVE,SSID,SIGNAL,RATE dev wifi 2>/dev/null | grep '^yes' | sed 's/^/         /'; fi
  if have iwconfig; then iwconfig 2>/dev/null | grep -E 'ESSID|Quality|Bit Rate' | sed 's/^/         /'; fi
elif [ -x /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport ]; then
  /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I | sed 's/^/         /'
fi

hdr "Latenz / Paketverlust (20 Pings an 1.1.1.1)"
if have ping; then
  out=$(ping -c 20 -i 0.2 1.1.1.1 2>&1 || true)
  loss=$(echo "$out" | grep -oE '[0-9.]+%' | head -1)
  stats=$(echo "$out" | tail -1)
  info "Verlust: ${loss:-?} | $stats"
  l=${loss%\%}; awk -v l="${l:-0}" 'BEGIN{exit !(l>2)}' && warn "Paketverlust über 2%"
fi

hdr "Offene Verbindungen (Listening)"
if have ss; then ss -tlnH 2>/dev/null | awk '{print $4}' | sort -u | head -10 | sed 's/^/         /'
elif have lsof; then lsof -iTCP -sTCP:LISTEN -nP 2>/dev/null | head -10 | sed 's/^/         /'; fi

# ---------------------------------------------------------------- Ergebnis
hdr "Ergebnis"
if [ "$PROBLEMS" -eq 0 ]; then echo "  Alles in Ordnung – keine Probleme gefunden."
else echo "  $PROBLEMS Warnung(en) gefunden – siehe [WARN]-Zeilen oben."; fi
exit $((PROBLEMS > 0))
