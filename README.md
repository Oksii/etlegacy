## Based on [msh100](https://github.com/msh100/rtcw)'s rtcwpro repository, adapted for ET Legacy and slightly simplified.

Slight key differences: We build two images, a :stable tag and :latest tag
We host our own reference files to be downloaded on build creation. By default 
tag :latest should always feature the latest snapshot available. Builds are 
automatically created on new snapshot releases. 
While tag :stable is intended to be used for specific versions. 

Dockerfiles are referring static files for this purpose respectively: 
"etlegacy-latest.tar.gz" and "etlegacy-stable.tar.gz"

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
SETTINGSURL          | The git URL (must be HTTP public) for the ETL settings repository. | https://github.com/Oksii/legacy-configs.git
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
TIMEOUTLIMIT         | Maximum number of pauses per map side | 1
SERVERCONF           | The value for RtcwPro's `g_customConfig` | `legacy6`.


Extra configuration can be prepended to the `etl_server.cfg` by mounting a
configuration at `/legacy/server/extra.cfg`.
This is generally not recommended, try to use the variables above where
possible or create a custom `SETTINGSURL`.


### Build history

Version change to hash: ace61bc4a84869e3fe2a9a77d25835eac15ba4e0 snapshot legacy_v2.82.0-38-gace61bc.pk3

Version change to hash: stable branch snapshot etlegacy-v2.82.0-34-gade91a7-x86_64.tar.gz

Version change to hash: stable branch snapshot etlegacy-v2.82.0-38-gace61bc-x86_64.tar.gz

Version change to hash: stable branch snapshot etlegacy-v2.82.0-38-gace61bc-x86_64.tar.gz

Version change to hash: stable snapshot 2.82.0-38

Version change to hash: stable snapshot 2.82.0-38

Version change to hash: stable snapshot 2.82.0-38

Version change to hash: stable snapshot 2.82.0-38

Version change to hash: stable snapshot 2.82.0-38

Version change to hash: stable snapshot 2.82.0-38

Version change to hash: stable snapshot 2.82.0-38

Version change to hash: stable snapshot 2.82.0-34

Version change to hash: stable snapshot 2.82.0-34

Version change to hash: stable snapshot 2.82.0-34

Version change to hash: stable snapshot 2.82.0-34

Version change to hash: stable snapshot 2.82.0-34

Version change to hash: stable snapshot 2.82.0-34

Version change to hash: stable snapshot 2.82.0-34
