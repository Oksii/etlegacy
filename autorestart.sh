#!/bin/sh

MAP_PORT=${MAP_PORT:-27960}
echo "Using port: $MAP_PORT"

xml_output=$(quakestat -xml -rws localhost:$MAP_PORT)

if [ $? -ne 0 ]; then
    echo "Failed to query server on port $MAP_PORT. Server may not be running."
    exit 1
fi

player_count=$(echo "$xml_output" | grep -oP '<numplayers>\K\d+')

if [ -z "$player_count" ]; then
    echo "Failed to retrieve player count from server response. Exiting."
    exit 1
fi

echo "Current player count: $player_count"

if [ "$player_count" -le 2 ]; then
    echo "2 or fewer players are active. Proceeding with server restart."
    timeout 5 icecon "localhost:$MAP_PORT" "${RCONPASSWORD}" -c "quit"
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo "RCON command issued successfully. Server will restart."
        exit 0
    else
        echo "Failed to issue RCON command. Exit code: $exit_code"
        exit 1
    fi
else
    echo "More than 2 players active ($player_count players). Skipping restart to avoid disruption."
    exit 1
fi
