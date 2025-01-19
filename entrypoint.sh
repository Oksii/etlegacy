#!/bin/bash

# Base directories
GAME_BASE="/legacy/server"
SETTINGS_BASE="${GAME_BASE}/settings"
ETMAIN_DIR="${GAME_BASE}/etmain"
LEGACY_DIR="${GAME_BASE}/legacy"
HOMEPATH="/legacy/homepath"

# Helper functions for common operations
log_info() {
    echo "$1"
}

log_warning() {
    echo "WARNING: $1"
}

ensure_directory() {
    mkdir -p "$1"
}

safe_copy() {
    local src="$1"
    local dest="$2"
    [ -f "$src" ] && cp -f "$src" "$dest"
}

# Config defaults
declare -A CONF=(
    # Server settings
    [HOSTNAME]="${HOSTNAME:-ET}"
    [MAP_PORT]="${MAP_PORT:-27960}"
    [REDIRECTURL]="${REDIRECTURL:-}"
    [MAXCLIENTS]="${MAXCLIENTS:-32}"
    [STARTMAP]="${STARTMAP:-radar}"
    [TIMEOUTLIMIT]="${TIMEOUTLIMIT:-1}"
    [SERVERCONF]="${SERVERCONF:-legacy6}"
    [SVTRACKER]="${SVTRACKER:-}"

    # Passwords
    [PASSWORD]="${PASSWORD:-}"
    [RCONPASSWORD]="${RCONPASSWORD:-}"
    [REFPASSWORD]="${REFPASSWORD:-}"
    [SCPASSWORD]="${SCPASSWORD:-}"
    
    # ETLTV
    [SVAUTODEMO]="${SVAUTODEMO:-0}"
    [ETLTVMAXSLAVES]="${SVETLTVMAXSLAVES:-2}"
    [ETLTVPASSWORD]="${SVETLTVPASSWORD:-3tltv}"
    
    # Repository
    [SETTINGSURL]="${SETTINGSURL:-https://github.com/Oksii/legacy-configs.git}"
    [SETTINGSPAT]="${SETTINGSPAT:-}"
    [SETTINGSBRANCH]="${SETTINGSBRANCH:-main}"

    # Stats API settings
    [STATS_SUBMIT]="${STATS_SUBMIT:-false}"
    [STATS_API_LOG]="${STATS_API_LOG:-false}"
    [STATS_API_TOKEN]="${STATS_API_TOKEN:-}"
    [STATS_API_PATH]="${STATS_API_PATH:-/legacy/homepath/legacy/stats/}"
    [STATS_API_URL_SUBMIT]="${STATS_API_URL_SUBMIT:-}"
    [STATS_API_URL_MATCHID]="${STATS_API_URL_MATCHID:-}"
    [STATS_API_OBITUARIES]="${STATS_API_OBITUARIES:-true}"
    [STATS_API_MESSAGELOG]="${STATS_API_MESSAGELOG:-false}"
    [STATS_API_DAMAGESTAT]="${STATS_API_DAMAGESTAT:-false}"
    [STATS_API_DUMPJSON]="${STATS_API_DUMPJSON:-false}"

    # XMAS settings
    [XMAS]="${XMAS:-false}"
    [XMAS_URL]="${XMAS_URL:-}"
)


# Enable/Disable STATS_API. Use a separate branch rather than edit every *.config file 
STATS_ENABLED=false
if [ "${CONF[STATS_SUBMIT]}" = "true" ]; then
    STATS_ENABLED=true
    # Set branch if using default branch
    if [ "${CONF[SETTINGSBRANCH]}" = "main" ]; then
        CONF[SETTINGSBRANCH]="etl-stats-api"
    fi
fi

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
    local maps_to_download=()
    
    # First pass - handle existing and local maps
    for map in "${MAP_ARRAY[@]}"; do
        # Skip if map already exists
        [ -f "${ETMAIN_DIR}/${map}.pk3" ] && continue

        log_info "Checking map ${map}"
        if [ -f "/maps/${map}.pk3" ]; then
            log_info "Map ${map} is sourcable locally, copying into place"
            cp "/maps/${map}.pk3" "${ETMAIN_DIR}/${map}.pk3"
        else
            maps_to_download+=("${map}")
        fi
    done
    
    # If we have maps to download, use parallel
    if [ ${#maps_to_download[@]} -gt 0 ]; then
        log_info "Attempting to download ${#maps_to_download[@]} maps in parallel"
        printf '%s\n' "${maps_to_download[@]}" | \
            parallel -j 30 \
            'wget -O "${ETMAIN_DIR}/{}.pk3" "${CONF[REDIRECTURL]}/etmain/{}.pk3" || { 
                log_warning "Failed to download {}"; 
                rm -f "${ETMAIN_DIR}/{}.pk3"; 
            }'
    fi
}

# Copy assets
copy_game_assets() {
    # Create required directories
    ensure_directory "${ETMAIN_DIR}/mapscripts/"
    ensure_directory "${LEGACY_DIR}/luascripts/"
    
    # Clean and copy mapscripts
    rm -f "${ETMAIN_DIR}/mapscripts/"*.script
    for mapscript in "${SETTINGS_BASE}/mapscripts/"*.script; do
        safe_copy "$mapscript" "${ETMAIN_DIR}/mapscripts/"
    done
    
    # Copy luascripts and command maps
    for luascript in "${SETTINGS_BASE}/luascripts/"*.lua; do
        safe_copy "$luascript" "${LEGACY_DIR}/luascripts/"
    done
    
    for commandmap in "${SETTINGS_BASE}/commandmaps/"*.pk3; do
        safe_copy "$commandmap" "${LEGACY_DIR}/"
    done
    
    # Handle configs
    rm -rf "${ETMAIN_DIR}/configs/"
    ensure_directory "${ETMAIN_DIR}/configs/"
    cp "${SETTINGS_BASE}/configs/"*.config "${ETMAIN_DIR}/configs/" 2>/dev/null || true
}

# Update server.cfg with CONF vars
update_server_config() {
    cp "${SETTINGS_BASE}/etl_server.cfg" "${ETMAIN_DIR}/etl_server.cfg"
    
    [ -n "${CONF[PASSWORD]}" ] && echo 'set g_needpass "1"' >> "${ETMAIN_DIR}/etl_server.cfg"

    # Replace all configuration placeholders
    for key in "${!CONF[@]}"; do
        value=$(echo "${CONF[$key]}" | sed 's/\//\\\//g')
        sed -i "s/%CONF_${key}%/${value}/g" "${ETMAIN_DIR}/etl_server.cfg"
    done
    
    sed -i 's/%CONF_[A-Z]*%//g' "${ETMAIN_DIR}/etl_server.cfg"
    
    # Handle MOTD configuration if set
    if [ -n "${CONF[MOTD]:-}" ]; then
        # Remove any existing server_motd lines to prevent duplicates
        sed -i '/^set server_motd[0-9]/d' "${ETMAIN_DIR}/etl_server.cfg"
        
        local motd_lines=()
        while IFS= read -r line; do
            motd_lines+=("$line")
        done < <(printf '%s' "${CONF[MOTD]}" | sed 's/\\n/\n/g')
        
        # Append the MOTD lines
        local line_num=0
        for line in "${motd_lines[@]}"; do
            echo "set server_motd${line_num}          \"${line}\"" >> "${ETMAIN_DIR}/etl_server.cfg"
            ((line_num++))
        done
        
        # Fill remaining slots with empty strings (up to server_motd5)
        while [ $line_num -lt 6 ]; do
            echo "set server_motd${line_num}          \"\"" >> "${ETMAIN_DIR}/etl_server.cfg"
            ((line_num++))
        done
    fi
    
    [ -f "${GAME_BASE}/extra.cfg" ] && cat "${GAME_BASE}/extra.cfg" >> "${ETMAIN_DIR}/etl_server.cfg"
}

# Download XMAS content if enabled
handle_xmas_content() {
    [ "${CONF[XMAS]}" = "true" ] || return 0
    
    local xmas_file="${LEGACY_DIR}/z_xmas.pk3"
    [ -f "$xmas_file" ] && return 0
    
    log_info "Downloading XMAS assets..."
    wget -q --show-progress -O "$xmas_file" "${CONF[XMAS_URL]}" ||
        { rm -f "$xmas_file"; log_warning "Failed to download XMAS assets"; return 1; }
}

# Update the game-stats-web.lua configuration
configure_stats_api() {
    local lua_file="${LEGACY_DIR}/luascripts/game-stats-web.lua"
    [ -f "$lua_file" ] || return 0
    
    # Replace configuration placeholders
    sed -i "s/%CONF_STATS_API_LOG%/${CONF[STATS_API_LOG]}/g" "$lua_file"
    sed -i "s|%CONF_STATS_API_URL_SUBMIT%|${CONF[STATS_API_URL_SUBMIT]}|g" "$lua_file"
    sed -i "s|%CONF_STATS_API_URL_MATCHID%|${CONF[STATS_API_URL_MATCHID]}|g" "$lua_file"
    sed -i "s|%CONF_STATS_API_PATH%|${CONF[STATS_API_PATH]}|g" "$lua_file" 
    sed -i "s/%CONF_STATS_API_TOKEN%/${CONF[STATS_API_TOKEN]}/g" "$lua_file"   
    sed -i "s/%CONF_STATS_API_OBITUARIES%/${CONF[STATS_API_OBITUARIES]}/g" "$lua_file"
    sed -i "s/%CONF_STATS_API_MESSAGELOG%/${CONF[STATS_API_MESSAGELOG]}/g" "$lua_file"
    sed -i "s/%CONF_STATS_API_DAMAGESTAT%/${CONF[STATS_API_DAMAGESTAT]}/g" "$lua_file"
    sed -i "s/%CONF_STATS_API_DUMPJSON%/${CONF[STATS_API_DUMPJSON]}/g" "$lua_file"
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
handle_xmas_content
$STATS_ENABLED && configure_stats_api

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