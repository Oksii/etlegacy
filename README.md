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
```
Version change to etlegacy-v2.82.0-34-gade91a7-x86_64.tar.gz || hash: ade91a75f3fb756a088f9a77d6c680d200158e68
Version change to etlegacy-v2.82.0-49-g28fa3bb-x86_64.tar.gz || hash: 28fa3bb7be74b766f31cbdeacff866769f5f1dcd
Version change to etlegacy-v2.82.0-50-gdc1ac4a-x86_64.tar.gz || hash: dc1ac4a1f1bf9f974b2cf8e7a614679d0514c8cf
Version change to etlegacy-v2.82.0-58-g48087c6-x86_64.tar.gz || hash: 48087c66152fc81a1a13ba69fa918d8cbb1a10ce
Version change to etlegacy-v2.82.0-68-g2ae1f90-x86_64.tar.gz || hash: 2ae1f90dc50a68a49a475f9d11743b10cdac7b89
Version change to etlegacy-v2.82.0-71-gad6c5cf-x86_64.tar.gz || hash: ad6c5cfce623699c9106617678559d3c7b5025d5
Version change to etlegacy-v2.82.1-x86_64.tar.gz || hash: 1d1261573792c81bee5bcdb92d4ac76f
Version change to etlegacy-v2.82.1-11-g7d6f6f6-x86_64.tar.gz || hash: 7d6f6f687af6d36704e9cf0fd63aaf8c6016e792[0m
Version change to etlegacy-v2.82.1-11-g7d6f6f6-x86_64.tar.gz || hash: 7d6f6f687af6d36704e9cf0fd63aaf8c6016e792[0m
Version change to etlegacy-v2.82.1-15-g3f3f8c5-x86_64.tar.gz || hash: 3f3f8c5e182eeed533fbfb12ac1f66a51f695f5c[0m
Version change to etlegacy-v2.82.1-21-g1564f8b-x86_64.tar.gz || hash: 1564f8b2613dbce5c481360fddd878a29230b397[0m
Version change to etlegacy-v2.82.1-22-g48dfda3-x86_64.tar.gz || hash: 48dfda3f230b9e52de70a2c4cf98e9891073bd6a[0m
Version change to etlegacy-v2.82.1-22-g48dfda3-x86_64.tar.gz || hash: 48dfda3f230b9e52de70a2c4cf98e9891073bd6a[0m
Version change to etlegacy-v2.82.1-22-g48dfda3-x86_64.tar.gz || hash: 48dfda3f230b9e52de70a2c4cf98e9891073bd6a
```
