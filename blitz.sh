#!/bin/bash
# BLITZ - Fast command execution on multiple servers
# BLITZ - Schnelle Befehlsausführung auf mehreren Servern
# Usage/Verwendung: ./blitz.sh "command" hosts.txt

# Command to execute / Befehl zum Ausführen
CMD="$1"

# File with host list / Datei mit Hostliste
HOSTS="$2"

# Check if command is provided / Prüfen ob Befehl angegeben wurde
[ -z "$CMD" ] && { echo "[ERROR] No command! Usage: $0 \"command\" hosts_file"; exit 1; }

# Check if hosts file exists / Prüfen ob Hosts-Datei existiert
[ -z "$HOSTS" -o ! -f "$HOSTS" ] && { echo "[ERROR] Missing hosts file! Usage: $0 \"command\" hosts_file"; exit 1; }

# Wrap command in bash -c for complex commands
# Befehl in bash -c einpacken für komplexe Befehle
FULL_CMD="bash -c '$CMD'"

echo "[INFO] Executing: $FULL_CMD on hosts from $HOSTS"
COUNTER=0

# Execute on each host / Auf jedem Host ausführen
for host in $(grep -v "^#" $HOSTS | grep -v "^$"); do
  # Show current host / Aktuellen Host anzeigen
  echo -n "[RUN] $host: "
  
  # Run command via SSH / Befehl über SSH ausführen
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 $host "$FULL_CMD" >/dev/null 2>&1
  
  # Check result / Ergebnis prüfen
  if [ $? -eq 0 ]; then
    echo "[OK]"
    ((COUNTER++))
  else
    echo "[FAIL]"
  fi
done

# Show summary / Zusammenfassung anzeigen
echo "[DONE] Executed on $COUNTER hosts"
