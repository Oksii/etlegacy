#!/bin/bash

# Base directories
GAME_BASE="/legacy/server"
SETTINGS_BASE="${GAME_BASE}/settings"

# Config defaults
declare -A CONF=(
    [REDIRECTURL]="${REDIRECTURL:-}"
    [MAP_PORT]="${MAP_PORT:-27960}"
    [STARTMAP]="${STARTMAP:-radar}"
    [HOSTNAME]="${HOSTNAME:-ET}"
    [MAXCLIENTS]="${MAXCLIENTS:-32}"
    [PASSWORD]="${PASSWORD:-}"
    [RCONPASSWORD]="${RCONPASSWORD:-}"
    [REFEREEPASSWORD]="${REFEREEPASSWORD:-}"
    [SVAUTODEMO]="${SVAUTODEMO:-0}"
    [ETLTVMAXSLAVES]="${SVETLTVMAXSLAVES:-2}"
    [ETLTVPASSWORD]="${SVETLTVPASSWORD:-3tltv}"
    [SCPASSWORD]="${SCPASSWORD:-}"
    [TIMEOUTLIMIT]="${TIMEOUTLIMIT:-1}"
    [SERVERCONF]="${SERVERCONF:-legacy6}"
    [SETTINGSURL]="${SETTINGSURL:-https://github.com/Oksii/legacy-configs.git}"
    [SETTINGSPAT]="${SETTINGSPAT:-}"
    [SETTINGSBRANCH]="${SETTINGSBRANCH:-main}"
    [SVTRACKER]="${SVTRACKER:-}"
)

# Fetch configs from repo
update_configs() {
    echo "Checking for configuration updates..."
    local auth_url="${CONF[SETTINGSURL]}"
    
    if [ -n "${CONF[SETTINGSPAT]}" ]; then
        auth_url="https://${CONF[SETTINGSPAT]}@$(echo "${CONF[SETTINGSURL]}" | sed 's~https://~~g')"
    fi

    if git clone --depth 1 --single-branch --branch "${CONF[SETTINGSBRANCH]}" "${auth_url}" "${SETTINGS_BASE}.new"; then
        rm -rf "${SETTINGS_BASE}"
        mv "${SETTINGS_BASE}.new" "${SETTINGS_BASE}"
    else
        echo "Configuration repo could not be pulled, using latest pulled version"
    fi
}

# Handle map downloads
download_maps() {
    IFS=':' read -ra MAP_ARRAY <<< "$MAPS"
    for map in "${MAP_ARRAY[@]}"; do
        [ -f "${GAME_BASE}/etmain/${map}.pk3" ] && continue

        echo "Attempting to download ${map}"
        if [ -f "/maps/${map}.pk3" ]; then
            echo "Map ${map} is sourcable locally, copying into place"
            cp "/maps/${map}.pk3" "${GAME_BASE}/etmain/${map}.pk3"
        else
            wget -O "${GAME_BASE}/etmain/${map}.pk3" "${CONF[REDIRECTURL]}/etmain/${map}.pk3" || {
                echo "Failed to download ${map}"
                rm -f "${GAME_BASE}/etmain/${map}.pk3"
                continue
            }
        fi
    done
}

# Copy assets
copy_game_assets() {
    # Create required directories
    mkdir -p "${GAME_BASE}/etmain/mapscripts/"
    mkdir -p "${GAME_BASE}/legacy/luascripts/"
    
    # Clean up existing mapscripts
    for mapscript in "${GAME_BASE}/etmain/mapscripts/"*.script; do
        [ -f "${mapscript}" ] || break
        rm -rf "${mapscript}"
    done
    
    # Copy mapscripts
    for mapscript in "${SETTINGS_BASE}/mapscripts/"*.script; do
        [ -f "${mapscript}" ] || break
        cp "${mapscript}" "${GAME_BASE}/etmain/mapscripts/"
    done
    
    # Copy luascripts
    for luascript in "${SETTINGS_BASE}/luascripts/"*.lua; do
        [ -f "${luascript}" ] || break
        cp "${luascript}" "${GAME_BASE}/legacy/luascripts/"
    done
    
    # Copy command maps
    for commandmap in "${SETTINGS_BASE}/commandmaps/"*.pk3; do
        [ -f "${commandmap}" ] || break
        cp "${commandmap}" "${GAME_BASE}/legacy/"
    done
    
    # Handle configs
    rm -rf "${GAME_BASE}/etmain/configs/"
    mkdir -p "${GAME_BASE}/etmain/configs/"
    cp "${SETTINGS_BASE}/configs/"*.config "${GAME_BASE}/etmain/configs/" 2>/dev/null || true
}

# Update server.cfg with CONF vars
update_server_config() {
    cp "${SETTINGS_BASE}/etl_server.cfg" "${GAME_BASE}/etmain/etl_server.cfg"
    
    # Set g_needpass if password is configured
    if [ -n "${CONF[PASSWORD]}" ]; then
        echo 'set g_needpass "1"' >> "${GAME_BASE}/etmain/etl_server.cfg"
    fi

    # Replace all configuration placeholders
    for key in "${!CONF[@]}"; do
        value=$(echo "${CONF[$key]}" | sed 's/\//\\\//g')
        sed -i "s/%CONF_${key}%/${value}/g" "${GAME_BASE}/etmain/etl_server.cfg"
    done
    
    # Clean up any remaining unreplaced placeholders
    sed -i 's/%CONF_[A-Z]*%//g' "${GAME_BASE}/etmain/etl_server.cfg"

    # Append extra configuration if it exists
    [ -f "${GAME_BASE}/extra.cfg" ] && cat "${GAME_BASE}/extra.cfg" >> "${GAME_BASE}/etmain/etl_server.cfg"
}

# Parse additional CLI arguments
parse_cli_args() {
    local args=()
    local IFS=$' \t\n'
    
    # If ADDITIONAL_CLI_ARGS is empty, return empty array
    [ -z "${ADDITIONAL_CLI_ARGS:-}" ] && echo "${args[@]}" && return

    # Read the string into an array maintaining quotes
    eval "args=($ADDITIONAL_CLI_ARGS)"
    echo "${args[@]}"
}

# Main
[ "${AUTO_UPDATE:-true}" = "true" ] && update_configs
download_maps
copy_game_assets
update_server_config

ADDITIONAL_ARGS=($(parse_cli_args))

# Start the game server
exec "${GAME_BASE}/etlded" \
    +set sv_maxclients "${CONF[MAXCLIENTS]}" \
    +set net_port "${CONF[MAP_PORT]}" \
    +set fs_basepath "${GAME_BASE}" \
    +set fs_homepath "/legacy/homepath" \
    +set sv_tracker "${CONF[SVTRACKER]}" \
    +exec "etl_server.cfg" \
    +map "${CONF[STARTMAP]}" \
    "${ADDITIONAL_ARGS[@]}" \
    "$@"