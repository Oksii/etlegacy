#!/bin/bash

# Set config defaults
CONF_REDIR=${REDIRECTURL:-""}
CONF_REDIR=${REDIRECTURL:-""}
CONF_PORT=${MAP_PORT:-27960}
CONF_STARTMAP=${STARTMAP:-radar}
CONF_HOSTNAME=${HOSTNAME:-ET}
CONF_MAXCLIENTS=${MAXCLIENTS:-32}
CONF_PASSWORD=${PASSWORD:-""}
CONF_RCONPASSWORD=${RCONPASSWORD:-""}
CONF_REFPASSWORD=${REFEREEPASSWORD:-""}
CONF_SVAUTODEMO=${SVAUTODEMO:-"0"}
CONF_ETLTVMAXSLAVES=${SVETLTVMAXSLAVES:-"2"}
CONF_ETLTVPASSWORD=${SVETLTVPASSWORD:-"SVETLTVPASSWORD"}
CONF_SCPASSWORD=${SCPASSWORD:-""}
CONF_TIMEOUTLIMIT=${TIMEOUTLIMIT:-1}
CONF_SERVERCONF=${SERVERCONF:-"legacy6"}
CONF_SETTINGSGIT=${SETTINGSURL:-"https://github.com/Oksii/legacy-configs.git"}
CONF_SETTINGSGITPAT=${SETTINGSPAT:-""}
CONF_SETTINGSBRANCH=${SETTINGSBRANCH:-"main"}
CONF_SVTRACKER=${SVTRACKER:-"tracker.etl.lol:4444"}

AUTO_UPDATE=${AUTO_UPDATE:-"true"}

GAME_BASE="/legacy/server"
SETTINGS_BASE="${GAME_BASE}/settings"

# Update the configs git directory
if [ "${AUTO_UPDATE}" == "true" ]; then
    echo "Checking if any configuration updates exist to pull"

    # If CONF_SETTINGSPAT is not empty, use it for authentication
    if [ -n "${CONF_SETTINGSGITPAT}" ]; then
        AUTH_URL="https://${CONF_SETTINGSGITPAT}@$(echo "${CONF_SETTINGSGIT}" | sed 's~https://~~g')"
    else
        AUTH_URL="${CONF_SETTINGSGIT}"
    fi

    if git clone --depth 1 --single-branch --branch "${CONF_SETTINGSBRANCH}" "${AUTH_URL}" "${SETTINGS_BASE}.new"; then
        rm -rf "${SETTINGS_BASE}"
        mv "${SETTINGS_BASE}.new" "${SETTINGS_BASE}"
    else
        echo "Configuration repo could not be pulled," \
            "using latest pulled version"
    fi
fi

declare -A default_maps=(
)

# Iterate over all maps and download them if necessary
export IFS=":"
for map in $MAPS; do
    if [ -n "${default_maps[$map]}" ]; then
        echo "${map} is a default map so we will not attempt to download"
        continue
    fi

    if [ ! -f "${GAME_BASE}/etmain/${map}.pk3" ]; then
        echo "Attempting to download ${map}"
        if [ -f "/maps/${map}.pk3" ]; then
            echo "Map ${map} is sourcable locally, copying into place"
            cp "/maps/${map}.pk3" "${GAME_BASE}/etmain/${map}.pk3.tmp"
        else
            # TODO: We make no effort to ensure this was successful, maybe we
            # should attempt to retry or at the very least try and skip the
            # mutations that happen further on in the loop.
            wget -O "${GAME_BASE}/etmain/${map}.pk3.tmp" "${CONF_REDIR}/etmain/$map.pk3"
        fi

        mv "${GAME_BASE}/etmain/${map}.pk3.tmp" "${GAME_BASE}/etmain/${map}.pk3"
    fi

    rm -rf "${GAME_BASE}/tmp/"
done

# We need to cleanup mapscripts on every invokation as we don't know what is
# going to exist in the settings directory.
for mapscript in "${GAME_BASE}/etmain/mapscripts/"*.script; do
    [ -f "${mapscript}" ] || break
    rm -rf "${mapscript}"
done

for mapscript in "${SETTINGS_BASE}/mapscripts/"*.script; do
    [ -f "${mapscript}" ] || break
    cp "${mapscript}" "${GAME_BASE}/etmain/mapscripts/"
done

# Copy luascripts over 
for luascript in "${SETTINGS_BASE}/luascripts/"*.lua; do
    [ -f "${luascript}" ] || break
    cp "${luascript}" "${GAME_BASE}/legacy/luascripts/"
done

# Only configs live within the config directory so we don't need to be careful
# about just recreating this directory.
rm -rf "${GAME_BASE}/etmain/configs/"
mkdir -p "${GAME_BASE}/etmain/configs/"
cp "${SETTINGS_BASE}/configs/"*.config "${GAME_BASE}/etmain/configs/"

# We need to set g_needpass if a password is set
if [ "${CONF_PASSWORD}" != "" ]; then
    CONF_NEEDPASS='set g_needpass "1"'
fi

# Iterate over all config variables and write them in place
cp "${SETTINGS_BASE}/etl_server.cfg" "${GAME_BASE}/etmain/etl_server.cfg"
for var in "${!CONF_@}"; do
    value=$(echo "${!var}" | sed 's/\//\\\//g')
    sed -i "s/%${var}%/${value}/g" "${GAME_BASE}/etmain/etl_server.cfg"
done
sed -i "s/%CONF_[A-Z]*%//g" "${GAME_BASE}/etmain/etl_server.cfg"

# Append extra.cfg if it exists
if [ -f "${GAME_BASE}/extra.cfg" ]; then
    cat "${GAME_BASE}/extra.cfg" >> "${GAME_BASE}/etmain/etl_server.cfg"
fi
# Rtcwpro uses a different binary which is provided in their package
binary="${GAME_BASE}/etlded"

# Exec into the game
exec "${binary}" \
    +set sv_maxclients "${CONF_MAXCLIENTS}" \
    +set net_port "${CONF_PORT}" \
    +set fs_basepath "${GAME_BASE}" \
    +set fs_homepath "/legacy/homepath" \
    +set sv_tracker "${CONF_SVTRACKER}" \
    +exec "etl_server.cfg" \
    +map "${CONF_STARTMAP}" \
    "${@}"
