#!/bin/sh

# Execute quakestat command and retrieve XML output
xml_output=$(quakestat -xml -rws localhost)

# Extract numplayers count from XML output
player_count=$(echo "$xml_output" | grep -oP '<numplayers>\K\d+')

# Check if player count is greater than 0
if [ -z "$player_count" ]; then
    echo "Failed to retrieve player count. Exiting."
    exit 1
fi

# Check if player count is greater than 0
if [ "$player_count" -gt 0 ]; then
    echo "Players are currently active. Exiting without update."
    exit 1
else
    echo "No players are currently active. Proceeding with update."

    # Issue the RCON command to quit the server
    timeout 5 icecon "localhost:27960" "${RCONPASSWORD}" -c "quit"
    exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo "RCON command issued successfully."
        exit 0
    else
        echo "Failed to issue RCON command. Exiting."
        exit 1
    fi
fi