#!/bin/bash
# BLITZ - Fast command execution on multiple servers
# BLITZ - Schnelle Befehlsausführung auf mehreren Servern
# Usage/Verwendung: ./blitz.sh "command" hosts.txt [-p|-e password_var]

# Command to execute / Befehl zum Ausführen
CMD="$1"

# File with host list / Datei mit Hostliste
HOSTS="$2"

# Password options / Passwort-Optionen
PASSWORD_MODE="none"  # none, prompt, env
PASSWORD_ENV=""

# Parse optional arguments / Optionale Argumente verarbeiten
if [ "$3" == "-p" ]; then
    PASSWORD_MODE="prompt"
elif [ "$3" == "-e" ] && [ ! -z "$4" ]; then
    PASSWORD_MODE="env"
    PASSWORD_ENV="$4"
fi

# Check if command is provided / Prüfen ob Befehl angegeben wurde
[ -z "$CMD" ] && { echo "[ERROR] No command! Usage: $0 \"command\" hosts_file [-p|-e password_var]"; exit 1; }

# Check if hosts file exists / Prüfen ob Hosts-Datei existiert
[ -z "$HOSTS" -o ! -f "$HOSTS" ] && { echo "[ERROR] Missing hosts file! Usage: $0 \"command\" hosts_file [-p|-e password_var]"; exit 1; }

# Wrap command in bash -c for complex commands
# Befehl in bash -c einpacken für komplexe Befehle
FULL_CMD="bash -c '$CMD'"

# Password handling setup / Passwort-Handling einrichten
if [ "$PASSWORD_MODE" == "prompt" ]; then
    # Check if sshpass is installed / Prüfen ob sshpass installiert ist
    if ! command -v sshpass &> /dev/null; then
        echo "[ERROR] sshpass not found but required for password mode."
        echo "[ERROR] Install with: apt-get install sshpass, yum install sshpass, etc."
        exit 1
    fi
    
    # Create secure temp password file / Sichere temporäre Passwortdatei erstellen
    PASS_FILE=$(mktemp)
    chmod 600 "$PASS_FILE"
    
    # Ask for password once / Einmal nach Passwort fragen
    read -s -p "[INPUT] Enter SSH password: " SSH_PASSWORD
    echo "$SSH_PASSWORD" > "$PASS_FILE"
    echo "" # newline after password input
    
    echo "[INFO] Password will be used for all hosts"
elif [ "$PASSWORD_MODE" == "env" ]; then
    # Check if sshpass is installed / Prüfen ob sshpass installiert ist
    if ! command -v sshpass &> /dev/null; then
        echo "[ERROR] sshpass not found but required for password mode."
        echo "[ERROR] Install with: apt-get install sshpass, yum install sshpass, etc."
        exit 1
    fi
    
    # Get password from environment variable / Passwort aus Umgebungsvariable holen
    SSH_PASSWORD="${!PASSWORD_ENV}"
    if [ -z "$SSH_PASSWORD" ]; then
        echo "[ERROR] Environment variable $PASSWORD_ENV is empty or not set"
        exit 1
    fi
    
    # Create secure temp password file / Sichere temporäre Passwortdatei erstellen
    PASS_FILE=$(mktemp)
    chmod 600 "$PASS_FILE"
    echo "$SSH_PASSWORD" > "$PASS_FILE"
    
    echo "[INFO] Using password from environment variable $PASSWORD_ENV"
fi

echo "[INFO] Executing: $FULL_CMD on hosts from $HOSTS"
COUNTER=0

# Execute on each host / Auf jedem Host ausführen
for host in $(grep -v "^#" $HOSTS | grep -v "^$"); do
  # Show current host / Aktuellen Host anzeigen
  echo -e "\n[RUN] $host:"
  
  # Run command via SSH with appropriate password method
  # SSH-Befehl mit entsprechender Passwortmethode ausführen
  if [ "$PASSWORD_MODE" == "none" ]; then
    # Normal SSH (will prompt for password) / Normales SSH (fragt nach Passwort)
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 $host "$FULL_CMD"
  else
    # Use sshpass with password file / sshpass mit Passwortdatei verwenden
    sshpass -f "$PASS_FILE" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 $host "$FULL_CMD"
  fi
  
  # Check result / Ergebnis prüfen
  if [ $? -eq 0 ]; then
    echo "[OK] Command succeeded on $host"
    ((COUNTER++))
  else
    echo "[FAIL] Command failed on $host"
  fi
  echo "----------------------------------------"
done

# Clean up password file if it exists / Passwortdatei aufräumen, falls vorhanden
if [ "$PASSWORD_MODE" != "none" ]; then
    if command -v shred &> /dev/null; then
        shred -u "$PASS_FILE"  # Secure deletion / Sichere Löschung
    else
        rm -f "$PASS_FILE"
    fi
fi

# Show summary / Zusammenfassung anzeigen
echo "[DONE] Executed on $COUNTER hosts"
