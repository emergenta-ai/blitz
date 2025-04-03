#!/bin/bash
# sonic.sh - Fast as a hedgehog command execution with smart sudo detection
# Usage: ./sonic.sh "command" hosts.txt -p

CMD="$1"                               # Command to execute
HOSTS="$2"                             # File with host list
PASSWORD_MODE="none"                   # Default: no password mode

# Parse password options
if [ "$3" == "-p" ]; then              # Check if -p flag is provided
    PASSWORD_MODE="prompt"              # We'll prompt for SSH password
    read -s -p "[INPUT] SSH password: " SSH_PASSWORD  # Get password securely
    echo ""                            # Newline after password
fi

# Validate input
[ -z "$CMD" ] && { echo "[ERROR] No command! Usage: $0 \"command\" hosts.txt [-p]"; exit 1; }
[ -z "$HOSTS" -o ! -f "$HOSTS" ] && { echo "[ERROR] Missing hosts file! Usage: $0 \"command\" hosts.txt [-p]"; exit 1; }

echo "[INFO] Executing: $CMD on hosts from $HOSTS"

# Check if sshpass is installed (if password mode is used)
if [ "$PASSWORD_MODE" == "prompt" ]; then
    if ! command -v sshpass &> /dev/null; then
        echo "[ERROR] sshpass not found but required for password mode"
        echo "[ERROR] Install with: apt-get install sshpass, yum install sshpass, etc."
        exit 1
    fi
fi

# Host success tracking
declare -A SUDO_PASSWORDS               # Associative array for sudo passwords
declare -A HOST_STATUS                  # Track status for each host

# Counters for statistics
TOTAL_HOSTS=0                          # Total hosts processed
SUCCESS_COUNT=0                         # Successful commands

# Process each host from the file
for host in $(grep -v "^#" $HOSTS | grep -v "^$"); do
    TOTAL_HOSTS=$((TOTAL_HOSTS + 1))    # Increment hosts counter
    echo -e "\n[RUN] $host:"            # Show current host
    
    # Set SSH command based on password mode
    if [ "$PASSWORD_MODE" == "prompt" ]; then
        SSH_BASE="sshpass -p '$SSH_PASSWORD' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5"
    else
        SSH_BASE="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5"
    fi
    
    # Check if we can connect to the host
    if ! eval "$SSH_BASE -o BatchMode=yes $host 'exit'" &>/dev/null; then
        echo "[FAIL] Cannot connect to $host"
        HOST_STATUS["$host"]="Connection failed"
        echo "----------------------------------------"
        continue
    fi
    
    # Check if command needs sudo
    if [[ "$CMD" == *"sudo "* ]]; then
        # First time connecting to this host with sudo?
        if [ -z "${SUDO_PASSWORDS["$host"]}" ]; then
            echo "[INFO] Command contains sudo, testing password..."
            
            # Try SSH password for sudo first
            SUDO_TEST=$(eval "$SSH_BASE $host 'echo $SSH_PASSWORD | sudo -S echo SUDO_OK 2>/dev/null || echo SUDO_FAIL'")
            
            if [[ "$SUDO_TEST" == *"SUDO_OK"* ]]; then
                echo "[INFO] SSH password works for sudo on $host"
                SUDO_PASSWORDS["$host"]="$SSH_PASSWORD"
            else
                echo "[INFO] Need separate sudo password for $host"
                read -s -p "[INPUT] Sudo password for $host: " SUDO_PASS
                echo ""  # Newline after password input
                SUDO_PASSWORDS["$host"]="$SUDO_PASS"
            fi
        fi
        
        # Create a script with sudo handling
        SCRIPT=$(cat <<EOSCRIPT
#!/bin/bash
# Auto-generated script for sudo handling

# Save the sudo password
SUDO_PASS="${SUDO_PASSWORDS["$host"]}"

# Override sudo to auto-input password
sudo() {
    echo "\$SUDO_PASS" | command sudo -S "\$@"
}

# Run the actual command with working sudo
$CMD

# Exit with the same status as the command
exit \$?
EOSCRIPT
)
        
        # Execute the script via SSH (all in one line for cleaner output)
        OUTPUT=$(eval "$SSH_BASE -t $host 'bash -s'" <<< "$SCRIPT" 2>&1)
        EXIT_CODE=$?
        
        # Display the output
        echo "$OUTPUT"
    else
        # Execute command directly if no sudo needed
        OUTPUT=$(eval "$SSH_BASE $host '$CMD'" 2>&1)
        EXIT_CODE=$?
        
        # Display the output
        echo "$OUTPUT"
    fi
    
    # Process exit code
    if [ $EXIT_CODE -eq 0 ]; then
        echo "[OK] Command succeeded on $host (exit code: 0)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        HOST_STATUS["$host"]="Success"
    else
        echo "[CODE: $EXIT_CODE] Command completed with non-zero exit code on $host"
        HOST_STATUS["$host"]="Failed with code $EXIT_CODE"
    fi
    
    echo "----------------------------------------"
done

# Show final summary
echo -e "\n[SUMMARY] Results for all hosts:"
echo "----------------------------------------"
for host in $(grep -v "^#" $HOSTS | grep -v "^$"); do
    STATUS="${HOST_STATUS["$host"]:-Not processed}"
    if [[ "$STATUS" == "Success" ]]; then
        echo "[OK] $host"
    else
        echo "[FAIL] $host - $STATUS"
    fi
done
echo "----------------------------------------"
echo "[DONE] Executed on $TOTAL_HOSTS hosts ($SUCCESS_COUNT succeeded, $((TOTAL_HOSTS - SUCCESS_COUNT)) with non-zero exit code)"
