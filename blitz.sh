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

# Initialize arrays to track results
TOTAL_HOSTS=0
declare -a HOST_LIST
declare -a EXIT_CODES

# Execute on each host / Auf jedem Host ausführen
for host in $(grep -v "^#" $HOSTS | grep -v "^$"); do
  # Count total hosts
  TOTAL_HOSTS=$((TOTAL_HOSTS + 1))
  HOST_LIST+=("$host")
  
  # Show current host / Aktuellen Host anzeigen
  echo -e "\n[RUN] $host:"
  
  # Run command via SSH with appropriate password method
  # SSH-Befehl mit entsprechender Passwortmethode ausführen
  if [ "$PASSWORD_MODE" == "none" ]; then
    # Normal SSH (will prompt for password) / Normales SSH (fragt nach Passwort)
    # Added -t flag to force TTY allocation for sudo / -t-Flag hinzugefügt, um TTY-Zuweisung für sudo zu erzwingen
    ssh -t -o StrictHostKeyChecking=no -o ConnectTimeout=5 $host "$FULL_CMD"
    EXIT_CODE=$?
  else
    # Use sshpass with password file / sshpass mit Passwortdatei verwenden
    # Added -t flag to force TTY allocation for sudo / -t-Flag hinzugefügt, um TTY-Zuweisung für sudo zu erzwingen
    sshpass -f "$PASS_FILE" ssh -t -o StrictHostKeyChecking=no -o ConnectTimeout=5 $host "$FULL_CMD"
    EXIT_CODE=$?
  fi
  
  # Store exit code for summary
  EXIT_CODES+=($EXIT_CODE)
  
  # Show exit code status
  if [ $EXIT_CODE -eq 0 ]; then
    echo "[EXIT: $EXIT_CODE] Command completed (SUCCESS)"
  else
    echo "[EXIT: $EXIT_CODE] Command completed (WITH CODE $EXIT_CODE)"
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

# Show detailed summary / Detaillierte Zusammenfassung anzeigen
echo -e "\n[SUMMARY] Results for all hosts:"
echo "----------------------------------------"
SUCCESS_COUNT=0
NONZERO_COUNT=0

for ((i=0; i<$TOTAL_HOSTS; i++)); do
  host="${HOST_LIST[$i]}"
  exit_code="${EXIT_CODES[$i]}"
  
  if [ $exit_code -eq 0 ]; then
    echo "[OK] $host (exit code: 0)"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo "[CODE: $exit_code] $host"
    NONZERO_COUNT=$((NONZERO_COUNT + 1))
  fi
done

echo "----------------------------------------"
echo "[DONE] Executed on $TOTAL_HOSTS hosts ($SUCCESS_COUNT with exit code 0, $NONZERO_COUNT with non-zero exit code)"
