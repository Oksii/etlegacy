## Based on [msh100](https://github.com/msh100/rtcw)'s rtcwpro repository, adapted for ET Legacy and slightly simplified.

Slight key differences: We build two images, a `:stable` tag and `:latest` tag
By default tag `:latest` should always feature the latest snapshot available. 
Builds are automatically created on new snapshot releases. 
While tag `:stable` is intended to be used for specific versions. 
Typically the snapshot version the competitive ETL communities are using.

For a detailed list of available tags see: [Docker Hub Repository](https://hub.docker.com/repository/docker/oksii/etlegacy).

We've configured [watchtower](https://containrrr.dev/watchtower/) to accept 
HTTP requests to trigger an update on running containers. 
See example docker-compose file. 

For that purpose we include a `playercount.sh` script inside the container, 
this allows us to perform pre-update checks for activity on running containers.
If playercount > 0 we skip restarting. 

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


## Example

```
docker run -d \
  -p "10.0.0.1:27960:27960/udp" \
  -e "MAPS=adlernest:te_escape2:frostbite" \
  -e "PASSWORD=war" \
  -e "REFEREEPASSWORD=pass123" \
  oksii/etlegacy
Version change: 2.83.1-58 || etlegacy-v2.83.1-58-g79bb2fa-x86_64.tar.gz || hash: 79bb2fa6f071ee34ddf5189afc847e3ed06e956e
```

## Configuration Options

Environment Variable | Description                    | Defaults
-------------------- | ------------------------------ | ------------------------
MAPS                 | List of maps seperated by ':'. | Default 6 maps
STARTMAP             | Map server starts on.          | "radar".
REDIRECTURL          | URL of HTTP downloads          | https://index.example.com/et/
MAP_PORT             | Container port (internal)      | 27960
MAXCLIENTS           | Maximum number of players      | 32
AUTO_UPDATE          | Update configurations on restart? | Enabled, set to `false` to enable.
SVTRACKER            | Set sv_tracker endpoint        | tracker.etl.lol:4444
XMAS                 | Use optional XMAS pk3          | Disabled, set to `true` to enable. 
XMAS_URL             | Provide URL to download xmas.pk3 | None 
SETTINGSURL          | The git URL (must be HTTP public) for the ETL settings repository. | https://github.com/Oksii/legacy-configs.git
SETTINGSPAT          | Github PAT token for private repos | None
SETTINGSBRANCH       | The git branch for the ETL settings repository. | `main`


### Configuration parameters for the default `SETTINGSURL`

Environment Variable | Description                    | Defaults
-------------------- | ------------------------------ | ------------------------
PASSWORD             | Server password.               | No password.
RCONPASSWORD         | RCON password.                 | No password (disabled).
REFEREEPASSWORD      | Referee password.              | No password (disabled).
SCPASSWORD           | Shoutcaster password.          | No password (disabled).
HOSTNAME             | Server hostname.               | ET
CONF_MOTD            | MOTD line on connect           | Empty.
SVAUTODEMO           | Enable/Disable autodemo record | 0 (disabled)
SVETLTVMAXSLAVES     | sv_etltv_maxslaves             | 2
SVETLTVPASSWORD      | sv_etltv_password              | 3tltv
TIMEOUTLIMIT         | Maximum number of pauses per map side | 1
SERVERCONF           | The value for RtcwPro's `g_customConfig` | `legacy6`.
ADDITIONAL_CLI_ARGS  | Provide list of args to pass, ie: +set sv_tracker "et.trackbase.com:4444" +set sv_autodemo 2  | None.
STATS_SUBMIT         | Submit match reports using game-stats-web.lua at end of every round | Disabled, set to `true` to enable. 
STATS_API_URL        | Sets endpoint for the API      | None
STATS_API_TOKEN      | API Token to be used in request | None
STATS_API_LOG        | Enable logging in game-stats-web.lua | Disabled, set to `true` to enable. 
STATS_API_PATH       | Input directory for `matchid.txt` | `/legacy/homepath/legacy/stats/`


Extra configuration can be prepended to the `etl_server.cfg` by mounting a
configuration at `/legacy/server/extra.cfg`.
This is generally not recommended, try to use the variables above where
possible or create a custom `SETTINGSURL`.