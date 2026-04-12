# ET:Legacy Match Server

This Docker image will download the required ET:Legacy maps as specified in the
`MAPS` environment variable (from `REDIRECTURL`) and then spawn an ET:Legacy
server with latest snapshot, with configuration as defined in the environment variables or
their defaults (refer below).

If you want to avoid downloading maps over HTTP(s), you can mount a volume of
maps to `/maps/`.
By default all `.pk3` files found in `/maps/` are automatically copied into
the server — no need to list them in `MAPS`. Set `MAPS_AUTO=false` to disable
auto-scanning and rely on explicit `MAPS` entries only.

All logs are written to STDOUT so can be viewed from `docker logs` or run
without the `-d` Docker run switch.

A container using this image will always try and download the latest changes
from whatever `SETTINGSURL` is set to.
By default this is [legacy-configs](https://github.com/Oksii/legacy-configs)

### Notes
- Based on [msh100's rtcwpro repository](https://github.com/msh100/rtcw) with significant changes
- Tag `stable` is recommended for competitive play and actively maintained. 
- Automatic builds triggered by [ET:Legacy snapshot](https://www.etlegacy.com/workflow-files) releases
- Available tags listed on [Docker Hub](https://hub.docker.com/r/oksii/etlegacy)
- Includes a built-in `autorestart` daemon that periodically checks player count and sends a restart signal when the server is empty (or below the configured threshold). Enabled by default, runs every 2 hours. Can also be invoked as a one-shot command (e.g. via Watchtower lifecycle hook).
# Usage
## docker-compose (Recommended)
```yaml
services:
  etl-server:
    container_name: etl-server
    image: oksii/etlegacy:stable
    environment:
      - 'HOSTNAME=ET Legacy Docker' 
      - 'MAPS=adlernest:braundorf_b4:supply:sw_goldrush_te'
      - 'PASSWORD=etlserver'
    volumes:
      - ./maps:/maps
    ports:
      - '27960:27960/udp'
    stdin_open: true
    tty: true
    restart: unless-stopped
```
## docker cli 
```bash
docker run -d \
  -p "27960:27960/udp" \
  -e "MAPS=adlernest:te_escape2:frostbite" \
  -e "PASSWORD=war" \
  -e "REFEREEPASSWORD=pass123" \
  oksii/etlegacy:stable
```

## guided install script 
[docker-install-script.sh](https://github.com/Oksii/etlegacy/blob/main/example/docker-install-script.sh) script will install the required packages and docker, and guide you through a set of configuration options (see [Configuration](https://github.com/Oksii/etlegacy/edit/main/README.md#configuration)). 

Also features the optional setup of:
 * watchtower
 * a minimalistic webserver for REDIRECTURL and wwwDownloads
 * automatic restarts via cron to avoid performance degradation
 * a helper utility that interacts with the server and docker for easy manage ([``etl-server``](https://github.com/Oksii/etlegacy/edit/main/README.md#etl-server-helper-script))

Allows for single or multiple instances configuration. 

Install script uses the docker-compose method and will output to a directory of your choice, configuration can easily be edited by modifying ``settings.env`` post-install.

```bash
cd ~ && \
    curl -sSL https://raw.githubusercontent.com/Oksii/etlegacy/main/example/docker-install-script.sh \
        -o docker-install-script.sh && \
    chmod +x docker-install-script.sh && \
    sudo ./docker-install-script.sh
```

# Configuration
Available environment variables: 

Environment Variable  | Description                    | Defaults
--------------------- | ------------------------------ | ------------------------
REDIRECTURL           | URL of HTTP downloads          | ``https://dl.etl.lol/maps/et``
MAP_PORT              | Container port (internal)      | ``27960``
MAP_IP                | Override the server's public IP reported to stats APIs. Auto-detected via ipify if unset. | ``None``
MAXCLIENTS            | Maximum number of players      | ``32``
AUTO_UPDATE           | Update configurations on restart? | ``true``
SVTRACKER             | Set sv_tracker endpoint, defaults to ``et.trackbase.net:4444`` via ETL defaults, if none is set. | ``None``
ADVERT                | `sv_advert`: `0`=none, `1`=master server, `2`=tracker. Auto-set to `2` when `SVTRACKER` is set, otherwise `0`. | ``auto``
ASSETS                | Download optional assets to ``./legacy`` dir. e.g ``zzz_levelshots.pk3``. | ``false`` 
ASSETS_URL            | Provide direct link URL to download assets.pk3 | ``None`` 
SETTINGSURL           | The git URL (must be HTTP public) for the ETL settings repository. | ``https://github.com/Oksii/legacy-configs.git``
SETTINGSPAT           | Github PAT token for private repos | ``None``
SETTINGSBRANCH        | The git branch for the ETL settings repository. | ``main``
ADDITIONAL_CLI_ARGS   | Provide list of args to pass, ie: +set sv_tracker "et.trackbase.com:4444" +set sv_autodemo 2  | ``None``
OMNIBOT               | Enable Omnibot AI. `0` = disabled, `1` = enabled | ``0``
MAPS_AUTO             | Auto-copy all `.pk3` files from the `/maps` volume without requiring `MAPS=` | ``true``
AUTORESTART           | Enable the built-in autorestart daemon | ``true``
AUTORESTART_INTERVAL  | How often (in minutes) the daemon checks whether to restart. Set to `0` to disable the daemon | ``120``
AUTORESTART_PLAYERS   | Maximum number of active players that still allows a restart. `0` = only restart when completely empty | ``0``

## Configuration parameters for the default `SETTINGSURL`
Environment Variable  | Description                    | Defaults
--------------------- | ------------------------------ | ------------------------
MAPS                  | List of maps seperated by ':'. | Default 6 maps
STARTMAP              | Map server starts on.          | ``radar``
PASSWORD              | Server password.               | ``None``
RCONPASSWORD          | RCON password.                 | ``None``
REFPASSWORD           | Referee password.              | ``None``
SCPASSWORD            | Shoutcaster password.          | ``None``
HOSTNAME              | Server hostname.               | ``ET Docker Server``
CONF_MOTD             | MOTD line on connect. Use `\n` to indicate a new line or change in ``server_motd[%]`` | ``None``
SVAUTODEMO            | Enable/Disable autodemo record. 0 (off), 1 (on), 2 (only active with players) | ``0``
SVETLTVMAXSLAVES      | Maximum allowed ETLTV Server slaves | ``2``
SVETLTVPASSWORD       | Password used by ETLTV slaves to connect | ```3tltv```
SERVERCONF            | Server config to load on startup | ``legacy6``

## Configuration parameters for `stats.lua`
Environment Variable  | Description                    | Defaults
--------------------- | ------------------------------ | ------------------------
STATS_SUBMIT            | Enable stats collection and submission at round end | ``false``
STATS_API_TOKEN         | API bearer token for submission requests | ``None``
STATS_API_URL_SUBMIT    | Endpoint to POST the match report JSON to | ``None``
STATS_API_URL_MATCHID   | Endpoint to fetch match ID from (`<base>/<server_ip>/<port>`) | ``None``
STATS_API_URL_VERSION   | Endpoint for stats module version checks | ``None``
STATS_API_PATH          | Directory path for local JSON dumps and log file | `/legacy/homepath/legacy/stats/`
STATS_API_LOG           | Enable stats log file | ``false``
STATS_API_LOG_LEVEL     | Log verbosity: `info` or `debug` | ``info``
STATS_API_DUMPJSON      | Write indented JSON to `STATS_API_PATH` at round end | ``false``
STATS_API_GAMELOG       | Collect in-round event timeline (kills, damage, objectives, etc.) | ``true``
STATS_API_OBJSTATS      | Collect objective stats per player | ``true``
STATS_API_SHOVESTATS    | Collect shove events | ``true``
STATS_API_MOVEMENTSTATS | Collect movement distance stats | ``true``
STATS_API_STANCESTATS   | Collect stance time stats (prone, crouch, sprint, etc.) | ``true``
STATS_API_WEAPON_FIRE   | Collect every weapon fire event (very high volume, not recommended) | ``false``
STATS_GATHER_FEATURES        | (Gather only) Enable all gather features at once (rename, sort, start, map, config, scores). Overrides individual flags when ``true`` | ``false``
STATS_AUTO_RENAME            | (Gather only) Enforce team roster player names from gather API | ``false``
STATS_AUTO_SORT              | (Gather only) Auto-assign players to their gather teams on connect | ``false``
STATS_AUTO_START             | (Gather only) Automatically ready-up all players when gather teams are full | ``false``
STATS_AUTO_MAP               | (Gather only) Switch to next map in rotation after round 2 intermission | ``false``
STATS_AUTO_CONFIG            | (Gather only) Apply server config based on roster player count at match start | ``false``
STATS_AUTO_SCORES            | (Gather only) Track match scores across a best-of-3 series; embeds score state into each stats submission | ``false``
STATS_AUTO_START_WAIT_INITIAL | (Gather only) Seconds before force-start on map 1 round 1 | ``420``
STATS_AUTO_START_WAIT        | (Gather only) Seconds before force-start on all subsequent rounds | ``180``
STATS_AUTO_CONFIG_2          | (Gather only) Server config applied for ≤2-player matches (e.g. `legacy1`) | ``legacy1``
STATS_AUTO_CONFIG_4          | (Gather only) Server config applied for ≤4-player matches | ``legacy3``
STATS_AUTO_CONFIG_6          | (Gather only) Server config applied for ≤6-player matches | ``legacy3``
STATS_AUTO_CONFIG_10         | (Gather only) Server config applied for ≤10-player matches | ``legacy5``
STATS_AUTO_CONFIG_12         | (Gather only) Server config applied for ≤12-player matches | ``legacy6``
STATS_API_VERSION_CHECK      | Check for gamestats module updates on round start | ``true``

## Configuration parameters for `combinedfixes.lua`
Environment Variable      | Description                    | Defaults
------------------------- | ------------------------------ | ------------------------
CF_DEFAULT_CLASS          | Force players to Medic on team join if no class is selected (effectively bans Soldier SMG) | ``true``
CF_GUID_BLOCKER           | Enable the GUID blocker — moves matching players to spectator during warmup | ``true``
CF_GUID_BLOCKER_TARGETS   | Comma-separated list of GUIDs to block during warmup (merged with any hardcoded in source) | ``F2ECF20F3ED6A5A93F2C49EF239F4488``
CF_TECH_PAUSE             | Enable the `techpause` / `tp` and `techunpause` / `tup` commands | ``true``
CF_TECH_PAUSE_LENGTH      | Timeout (seconds) for a tech pause | ``600``
CF_TECH_PAUSE_COUNT       | Number of tech pauses allowed per team per half | ``1``
CF_PAUSE_LENGTH           | Timeout (seconds) for a regular pause | ``120``
CF_TEAM_LOCK              | Lock teams on round start in stopwatch; re-locks after unpause | ``true``
CF_COMMAND_LOGGING        | Log `callvote`, `vote`, and `ref` commands to the log file | ``true``
CF_COMMAND_LOG_VOTES      | Log `callvote` / `vote` commands (requires `CF_COMMAND_LOGGING=true`) | ``true``
CF_COMMAND_LOG_REF        | Log `ref` commands (requires `CF_COMMAND_LOGGING=true`) | ``true``
CF_SPAWN_INVUL_SECONDS    | Spawn shield duration in seconds (only active for configs containing `1on1`) | ``1``
CF_BAN_REASON             | Rejection message shown to banned players | ``Banned.``
CF_LOG_FILEPATH           | Override the log file path. Auto-detected (`<fs_homepath>/legacy/combinedfixes.log`) when empty | ``None``
CF_BANNED_GUIDS           | Comma-separated list of GUIDs rejected at connect (e.g. `AABBCC...,DDEEFF...`) | ``None``
CF_BANNED_IPS             | Comma-separated list of IPs or prefixes rejected at connect (e.g. `1.2.3.4,10.0.0.`) | ``None``
CF_VOTE_BANNED_GUIDS      | Comma-separated list of GUIDs blocked from calling votes | ``None``

Extra configuration can be prepended to the `etl_server.cfg` by mounting a
configuration at `/legacy/server/extra.cfg`.
This is generally not recommended, try to use the variables above where
possible or create a custom `SETTINGSURL`.

# Further examples: 
## watchtower integration
Automatic updates and restarts, ensuring servers are only restarted when no players are present.
By using watchtower's ``--enable-lifecycle-hooks`` and adding the following labels to your ET:L service.
The `autorestart` binary runs in one-shot mode when invoked as a lifecycle hook: it exits `0` (proceed with update) only if the player count is at or below `AUTORESTART_PLAYERS`, otherwise exits `1` (abort).

````yaml
  labels:
    - "com.centurylinklabs.watchtower.enable=true"
    - "com.centurylinklabs.watchtower.lifecycle.pre-update=/legacy/server/autorestart"

  watchtower:
    container_name: watchtower
    image: containrrr/watchtower
    command: --enable-lifecycle-hooks
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    labels:
      - "com.centurylinklabs.watchtower.enable=false"
      - "com.watchtower=watchtower"
````

## ETL-Server Helper Script

The `etl-server` helper script provides a convenient way to manage your ET:Legacy server instances through simple commands. This utility is automatically installed when using the guided install script.

## Usage

```bash
etl-server [start|stop|restart|status|logs|rcon|update] [instance_number] [command]
```

### Available Commands
Command     | Description           | Example
----------- | --------------------- | --------------------------------------------------
``start`` 	| Start servers 	      | ``etl-server start`` or ``etl-server start 2``
``stop`` 	  | Stop servers 	        | ``etl-server stop`` or ``etl-server stop 1``
``restart`` | Restart servers 	    | ``etl-server restart`` ``or etl-server restart 2``
``status`` 	| Show server status 	  | ``etl-server status`` or ``etl-server status 1``
``logs`` 	  | Show live logs 	      | ``etl-server logs 2``
``rcon`` 	  | Execute RCON commands | ``etl-server rcon 2 map supply``
``update``  |	Update Docker images 	| ``etl-server update`` or ``etl-server update 2``

### Status  Information
The status command displays detailed information about your servers:
  * Container status and uptime
  * Server name and current map
  * Active players
  * Port configuration
  * Password settings

### Update Safety Features
The update command includes safety checks:
  * Checks for active players before updating
  * Warns if servers have players connected
  * Provides --force option for urgent updates
  * Shows detailed server state before update

### Examples
```bash
etl-server start            # Start all server instances
etl-server stop 2           # Stop specific instance
etl-server status           # View status of all servers
etl-server update 2         # Update specific instance (checks for players first)
etl-server update 2 --force # Force update even with active players
etl-server rcon 1 map radar # Execute RCON command on instance 1
etl-server logs 2           # View live logs for instance 2
```

### Notes
  * The script requires Docker and docker-compose to be installed
  * Multiple instance support is configured during initial setup
  * All commands respect the configuration in your settings.env file
  * Updates check for active players by default to prevent disruption