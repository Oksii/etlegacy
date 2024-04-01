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
    exit 0
fi