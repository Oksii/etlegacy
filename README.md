# ET:Legacy Match Server

This Docker image will download the required ET:Legacy maps as specified in the
`MAPS` environment variable (from `REDIRECTURL`) and then spawn an ET:Legacy
server with latest snapshot, with configuration as defined in the environment variables or
their defaults (refer below).

If you want to avoid downloading maps over HTTP(s), you can mount a volume of
maps to `/maps/`.
The container will first try to copy from pk3s from this directory before
attempting an HTTP(s) download.

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
- Includes `autorestart.sh` for performance maintenance. Will check for active players before restarting:
  ```bash
  # Example cron setup
  0 */2 * * * docker exec etl-server ./autorestart
  ```
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
MAXCLIENTS            | Maximum number of players      | ``32``
AUTO_UPDATE           | Update configurations on restart? | ``true``
SVTRACKER             | Set sv_tracker endpoint, defaults to ``et.trackbase.net:4444`` via ETL defaults, if none is set. | ``None``
ASSETS                | Download optional assets to ``./legacy`` dir. e.g ``zzz_levelshots.pk3``. | ``false`` 
ASSETS_URL            | Provide direct link URL to download assets.pk3 | ``None`` 
SETTINGSURL           | The git URL (must be HTTP public) for the ETL settings repository. | ``https://github.com/Oksii/legacy-configs.git``
SETTINGSPAT           | Github PAT token for private repos | ``None``
SETTINGSBRANCH        | The git branch for the ETL settings repository. | ``main``
ADDITIONAL_CLI_ARGS   | Provide list of args to pass, ie: +set sv_tracker "et.trackbase.com:4444" +set sv_autodemo 2  | ``None``


## Configuration parameters for the default `SETTINGSURL`
Environment Variable  | Description                    | Defaults
--------------------- | ------------------------------ | ------------------------
MAPS                  | List of maps seperated by ':'. | Default 6 maps
STARTMAP              | Map server starts on.          | ``radar``
PASSWORD              | Server password.               | ``None``
RCONPASSWORD          | RCON password.                 | ``None``
REFEREEPASSWORD       | Referee password.              | ``None``
SCPASSWORD            | Shoutcaster password.          | ``None``
HOSTNAME              | Server hostname.               | ``ET Docker Server``
CONF_MOTD             | MOTD line on connect. Use `\n` to indicate a new line or change in ``server_motd[%]`` | ``None``
SVAUTODEMO            | Enable/Disable autodemo record. 0 (off), 1 (on), 2 (only active with players) | ``0``
SVETLTVMAXSLAVES      | Maximum allowed ETLTV Server slaves | ``2``
SVETLTVPASSWORD       | Password used by ETLTV slaves to connect | ```3tltv```
TIMEOUTLIMIT          | Maximum number of pauses per map side | ``1``
SERVERCONF            | Server config to load on startup | ``legacy6``
STATS_SUBMIT          | Submit match reports using game-stats-web.lua at end of every round | ``false`` 
STATS_API_TOKEN       | API Token to be used in request | ``None``
STATS_API_PATH        | Path to to save logfile to     | `/legacy/homepath/legacy/stats/`
STATS_API_URL_SUBMIT  | Sets endpoint for the API to SUBMIT match_report to | ``None``
STATS_API_URL_MATCHID | Gather Automation. Will fetch matchID from specified base_url/server_ip/server_port endpoint | ``None``
STATS_API_DUMPJSON    | Debug, dump stats json to file before sending | ``false``
STATS_API_OBJDEBUG    | Debug, print debug logs in STATS_API_LOG for objective related events | ``false``
STATS_API_LOG         | Enable logging in game-stats-web.lua | ``false``
STATS_API_OBITUARIES  | Collect and submit Obituaries in json report  | ``true``
STATS_API_DAMAGESTAT  | Collect and submit damage events in json report | ``false``
STATS_API_OBJSTATS    | Collect and submit objective stats in json report | ``true``
STATS_API_MESSAGELOG  | Collect and submit server messages in json report | ``false``

Extra configuration can be prepended to the `etl_server.cfg` by mounting a
configuration at `/legacy/server/extra.cfg`.
This is generally not recommended, try to use the variables above where
possible or create a custom `SETTINGSURL`.

# Further examples: 
## watchtower integration
Automatic updates and restarts, ensuring servers are only restarted with no players are present.
By using watchtower's ``--enable-lifecycle-hooks`` and adding the following labels to your ET:L service.

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