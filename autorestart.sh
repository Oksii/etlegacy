#!/bin/sh

# Find the active UDP port in range 27960-27970 using /proc/net/udp
# Convert port range to hex for matching
active_port=$(cat /proc/net/udp | awk '$2 ~ /:6D38|:6D39|:6D3A|:6D3B|:6D3C|:6D3D|:6D3E|:6D3F|:6D40|:6D41|:6D42/ {split($2,a,":"); printf("%d\n", "0x" a[2])}' | head -1)

if [ -z "$active_port" ]; then
    echo "No active UDP port found in range 27960-27970. Exiting."
    exit 1
fi

echo "Found active port: $active_port"

# Execute quakestat command with the found port and retrieve XML output
xml_output=$(quakestat -xml -rws localhost:$active_port)

# Extract numplayers count from XML output
player_count=$(echo "$xml_output" | grep -oP '<numplayers>\K\d+')

# Check if player count was retrieved successfully
if [ -z "$player_count" ]; then
    echo "Failed to retrieve player count. Exiting."
    exit 1
fi

# Check if player count is less than or equal to 2
if [ "$player_count" -le 2 ]; then
    echo "2 or fewer players are active. Proceeding with update."
    # Issue the RCON command to quit the server using the found port
    timeout 5 icecon "localhost:$active_port" "${RCONPASSWORD}" -c "quit"
    exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo "RCON command issued successfully."
        exit 0
    else
        echo "Failed to issue RCON command. Exiting."
        exit 1
    fi
else
    echo "More than 2 players active ($player_count players). Exiting without update."
    exit 1
fi
