#!/bin/bash
# sonic.sh - Fast as a hedgehog command execution with smart sudo detection
# Usage: ./sonic.sh "command" hosts.txt [-p] [-l user]

# --- Configuration ---
CONNECT_TIMEOUT=5
COMMAND_TIMEOUT=60 # Timeout for the SSH command itself

# --- Argument Parsing ---
CMD=""
HOSTS_FILE=""
PASSWORD_MODE="key" # Default to key-based/agent auth
SSH_USER="$USER"    # Default to current user
SSH_PASSWORD=""
SUDO_PASSWORDS=()   # Associative array for sudo passwords per host
HOST_STATUS=()      # Track status for each host

# Simple argument parsing loop
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -p)
        PASSWORD_MODE="prompt"
        shift # past argument
        ;;
        -l)
        SSH_USER="$2"
        shift # past argument
        shift # past value
        ;;
        *)
        if [[ -z "$CMD" ]]; then
            CMD="$1"
        elif [[ -z "$HOSTS_FILE" ]]; then
            HOSTS_FILE="$1"
        else
            echo "[ERROR] Unknown argument: $1"
            exit 1
        fi
        shift # past argument
        ;;
    esac
done

# --- Input Validation ---
if [[ -z "$CMD" ]]; then
    echo "[ERROR] No command specified."
    echo "Usage: $0 \"command\" hosts.txt [-p] [-l user]"
    exit 1
fi
if [[ -z "$HOSTS_FILE" ]] || [[ ! -f "$HOSTS_FILE" ]]; then
    echo "[ERROR] Hosts file '$HOSTS_FILE' not found or not specified."
    echo "Usage: $0 \"command\" hosts.txt [-p] [-l user]"
    exit 1
fi

# --- Password Handling ---
if [[ "$PASSWORD_MODE" == "prompt" ]]; then
    if ! command -v sshpass &> /dev/null; then
        echo "[ERROR] sshpass not found but required for -p mode"
        echo "[ERROR] Install with: apt-get install sshpass, yum install sshpass, etc."
        exit 1
    fi
    echo "[INFO] SSH Key/Agent authentication is recommended over passwords."
    read -s -p "[INPUT] SSH password for user '$SSH_USER': " SSH_PASSWORD || exit 1 # Check read success
    echo "" # Newline after password
fi

echo "[INFO] Executing on hosts from $HOSTS_FILE as user '$SSH_USER'"
echo "[INFO] Command: $CMD"

# --- Host Processing ---
TOTAL_HOSTS=0
SUCCESS_COUNT=0

# Use process substitution and while read for robust line handling
while IFS= read -r host || [[ -n "$host" ]]; do
    # Skip comments and blank lines
    [[ "$host" =~ ^# ]] || [[ -z "$host" ]] && continue

    TOTAL_HOSTS=$((TOTAL_HOSTS + 1))
    echo -e "\n[RUN] $host:"
    HOST_STATUS["$host"]="Processing" # Initial status

    SSH_TARGET="${SSH_USER}@${host}"
    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=$CONNECT_TIMEOUT -o BatchMode=yes" # BatchMode for non-interactive checks

    # Build base SSH command parts in an array for safer handling
    SSH_CMD_ARRAY=()
    if [[ "$PASSWORD_MODE" == "prompt" ]]; then
        SSH_CMD_ARRAY+=("sshpass" "-p" "$SSH_PASSWORD")
    fi
    SSH_CMD_ARRAY+=("ssh" ${SSH_OPTS})

    # 1. Check Connectivity (without BatchMode for actual command)
    CONN_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=$CONNECT_TIMEOUT -o BatchMode=yes"
    CONN_SSH_CMD_ARRAY=()
    if [[ "$PASSWORD_MODE" == "prompt" ]]; then
       CONN_SSH_CMD_ARRAY+=("sshpass" "-p" "$SSH_PASSWORD")
    fi
    CONN_SSH_CMD_ARRAY+=("ssh" ${CONN_SSH_OPTS} "$SSH_TARGET" "exit")

    if ! "${CONN_SSH_CMD_ARRAY[@]}" &>/dev/null; then
        echo "[FAIL] Cannot connect to $host (user: $SSH_USER)"
        HOST_STATUS["$host"]="Connection failed"
        echo "----------------------------------------"
        continue
    fi

    # 2. Prepare for actual command execution (remove BatchMode)
    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=$CONNECT_TIMEOUT" # No BatchMode
    SSH_CMD_ARRAY=("ssh" ${SSH_OPTS}) # Rebuild without BatchMode
     if [[ "$PASSWORD_MODE" == "prompt" ]]; then
        # Insert sshpass at the beginning
        SSH_CMD_ARRAY=("sshpass" "-p" "$SSH_PASSWORD" "${SSH_CMD_ARRAY[@]}")
    fi
    SSH_CMD_ARRAY+=("$SSH_TARGET") # Add target

    # 3. Handle sudo
    NEEDS_SUDO=false
    # Refined check: starts with sudo or contains /sudo (adjust regex if needed)
    if [[ "$CMD" =~ ^sudo\s+ ]] || [[ "$CMD" =~ \ /sudo\s+ ]]; then
         NEEDS_SUDO=true
         SUDO_PASS=""
         # Check if we already have a sudo pass for this host
         if [[ -v SUDO_PASSWORDS["$host"] ]]; then
             SUDO_PASS="${SUDO_PASSWORDS["$host"]}"
             echo "[INFO] Using stored sudo password for $host"
         else
            # Try SSH password for sudo first? Only if -p was used.
            if [[ "$PASSWORD_MODE" == "prompt" ]]; then
                 echo "[INFO] Testing if SSH password works for sudo..."
                 # Use printf for safer password piping than echo
                 if printf "%s\n" "$SSH_PASSWORD" | "${SSH_CMD_ARRAY[@]}" "sudo -S -p '' echo SUDO_OK" 2>/dev/null | grep -q "SUDO_OK"; then
                     echo "[INFO] SSH password works for sudo on $host."
                     SUDO_PASS="$SSH_PASSWORD"
                     SUDO_PASSWORDS["$host"]="$SUDO_PASS"
                 fi
            fi

            # If SSH pass didn't work or wasn't tried, prompt
            if [[ -z "$SUDO_PASS" ]]; then
                 echo "[INFO] Need sudo password for $host"
                 # Loop until password works? (Optional, adds complexity)
                 read -s -p "[INPUT] Sudo password for $SSH_USER@$host: " SUDO_PASS_INPUT || { echo "[WARN] Failed to read sudo password."; SUDO_PASS_INPUT=""; }
                 echo ""
                 SUDO_PASS="$SUDO_PASS_INPUT"
                 SUDO_PASSWORDS["$host"]="$SUDO_PASS" # Store even if potentially wrong, try it once
            fi
         fi

         # Prepare command for sudo -S
         CMD_WITHOUT_SUDO="${CMD#*sudo }" # Basic removal, might need refinement
         # Use printf for safer password injection
         REMOTE_CMD="printf '%s\n' '$SUDO_PASS' | sudo -S -p '' -- $CMD_WITHOUT_SUDO"
    else
        # Command does not appear to need sudo
        REMOTE_CMD="$CMD"
    fi

    # 4. Execute the command
    echo "[EXEC] $REMOTE_CMD"
    # Add timeout command
    OUTPUT=$(timeout "${COMMAND_TIMEOUT}s" "${SSH_CMD_ARRAY[@]}" "$REMOTE_CMD" 2>&1)
    EXIT_CODE=$?

    # 5. Process result
    echo "$OUTPUT"
    if [[ $EXIT_CODE -eq 0 ]]; then
        echo "[OK] Command succeeded on $host (exit code: 0)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        HOST_STATUS["$host"]="Success"
    elif [[ $EXIT_CODE -eq 124 ]]; then # Timeout exit code
        echo "[FAIL] Command timed out on $host (>${COMMAND_TIMEOUT}s)"
        HOST_STATUS["$host"]="Timeout"
    else
        echo "[CODE: $EXIT_CODE] Command completed with non-zero exit code on $host"
        HOST_STATUS["$host"]="Failed with code $EXIT_CODE"
    fi

    echo "----------------------------------------"

done < <(grep -v -e "^#" -e "^$" "$HOSTS_FILE") # Filter comments/blanks robustly


# --- Final Summary ---
echo -e "\n[SUMMARY] Results for all hosts:"
echo "----------------------------------------"
# Re-read hosts file just for the summary order, using the stored status
while IFS= read -r host || [[ -n "$host" ]]; do
    [[ "$host" =~ ^# ]] || [[ -z "$host" ]] && continue
    STATUS="${HOST_STATUS["$host"]:-Not processed}" # Default if somehow missed
    if [[ "$STATUS" == "Success" ]]; then
        echo "[OK]   $host"
    elif [[ "$STATUS" == "Processing" ]]; then # Should not happen if script completes
         echo "[WARN] $host - Still processing?"
    else
        echo "[FAIL] $host - $STATUS"
    fi
done < <(grep -v -e "^#" -e "^$" "$HOSTS_FILE")
echo "----------------------------------------"
FAIL_COUNT=$((TOTAL_HOSTS - SUCCESS_COUNT))
echo "[DONE] Processed $TOTAL_HOSTS hosts ($SUCCESS_COUNT succeeded, $FAIL_COUNT failed/non-zero)"
