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
SVTRACKER            | Set sv_tracker endpoint        | None
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
SVTRACKER            | Set sv_tracker endpoint        | tracker.etl.lol:4444
SVAUTODEMO           | Enable/Disable autodemo record | 0 (disabled)
SVETLTVMAXSLAVES     | sv_etltv_maxslaves             | 2
SVETLTVPASSWORD      | sv_etltv_password              | 3tltv
TIMEOUTLIMIT         | Maximum number of pauses per map side | 1
SERVERCONF           | The value for RtcwPro's `g_customConfig` | `legacy6`.
ADDITIONAL_CLI_ARGS  | Provide list of args to pass, ie: +set sv_tracker "et.trackbase.com:4444" +set sv_autodemo 2  | None.


Extra configuration can be prepended to the `etl_server.cfg` by mounting a
configuration at `/legacy/server/extra.cfg`.
This is generally not recommended, try to use the variables above where
possible or create a custom `SETTINGSURL`.


### Build history
```
Version change: v2.82.0-34 || etlegacy-v2.82.0-34-gade91a7-x86_64.tar.gz || hash: ade91a75f3fb756a088f9a77d6c680d200158e68
Version change: v2.82.0-49 || etlegacy-v2.82.0-49-g28fa3bb-x86_64.tar.gz || hash: 28fa3bb7be74b766f31cbdeacff866769f5f1dcd
Version change: v2.82.0-50 || etlegacy-v2.82.0-50-gdc1ac4a-x86_64.tar.gz || hash: dc1ac4a1f1bf9f974b2cf8e7a614679d0514c8cf
Version change: v2.82.0-58 || etlegacy-v2.82.0-58-g48087c6-x86_64.tar.gz || hash: 48087c66152fc81a1a13ba69fa918d8cbb1a10ce
Version change: v2.82.0-68 || etlegacy-v2.82.0-68-g2ae1f90-x86_64.tar.gz || hash: 2ae1f90dc50a68a49a475f9d11743b10cdac7b89
Version change: v2.82.0-71 || etlegacy-v2.82.0-71-gad6c5cf-x86_64.tar.gz || hash: ad6c5cfce623699c9106617678559d3c7b5025d5
Version change: v2.82.1    || etlegacy-v2.82.1-x86_64.tar.gz             || hash: 1d1261573792c81bee5bcdb92d4ac76f
Version change: v2.82.1-11 || etlegacy-v2.82.1-11-g7d6f6f6-x86_64.tar.gz || hash: 7d6f6f687af6d36704e9cf0fd63aaf8c6016e792
Version change: v2.82.1-15 || etlegacy-v2.82.1-15-g3f3f8c5-x86_64.tar.gz || hash: 3f3f8c5e182eeed533fbfb12ac1f66a51f695f5c
Version change: v2.82.1-21 || etlegacy-v2.82.1-21-g1564f8b-x86_64.tar.gz || hash: 1564f8b2613dbce5c481360fddd878a29230b397
Version change: v2.82.1-22 || etlegacy-v2.82.1-22-g48dfda3-x86_64.tar.gz || hash: 48dfda3f230b9e52de70a2c4cf98e9891073bd6a
Version change: v2.82.1-23 || etlegacy-v2.82.1-23-g61fc087-x86_64.tar.gz || hash: 61fc087b5e938cbe6983b408607f11310f8a1679
Version change: v2.82.1-26 || etlegacy-v2.82.1-26-ga82a203-x86_64.tar.gz || hash: a82a2036c4b225426108f6d875584a14aa5f9f4d
Version change: v2.82.1-37 || etlegacy-v2.82.1-37-g6c052a6-x86_64.tar.gz || hash: 6c052a6d310dbc400ba7f2d3cd2b17ce2a745b46
Version change: v2.82.1-38 || etlegacy-v2.82.1-38-g6cb533d-x86_64.tar.gz || hash: 6cb533d1c28eaa2bacab31b672a80f85f3bd9d5d
Version change: v2.82.1-43 || etlegacy-v2.82.1-43-g6935de0-x86_64.tar.gz || hash: 6935de0c07596db0fcbf9243999fb7ecc4e7a1b4
Version change: v2.82.1-70 || etlegacy-v2.82.1-70-g52f1f5b-x86_64.tar.gz || hash: 52f1f5bb341a6e7c7e0f43b7fd6daa89548ffa3d
Version change: 2.82.1-71 || etlegacy-v2.82.1-71-gac4b2de-x86_64.tar.gz || hash: ac4b2deeccd6cdbb9cea4e6ba87400dbf602ab87
Version change: 2.82.1-74 || etlegacy-v2.82.1-74-g956e441-x86_64.tar.gz || hash: 956e441929d2f853ef4fbcbcf41799b253d3ab55
Version change: 2.82.1-80 || etlegacy-v2.82.1-80-g247d7fd-x86_64.tar.gz || hash: 247d7fd270a9ba8f1d4f8b4fff8b70c70e5d16c0
Version change: 2.82.1-83 || etlegacy-v2.82.1-83-g0624beb-x86_64.tar.gz || hash: 0624bebf691756b5fb05cba75cf1bf50dafebc00
Version change: 2.82.1-86 || etlegacy-v2.82.1-86-g3921510-x86_64.tar.gz || hash: 39215108429b11ef7848fed84d6c5391d0691289
Version change: 2.82.1-96 || etlegacy-v2.82.1-96-gb3e34ce-x86_64.tar.gz || hash: b3e34cea85371f4c26a809c4f460e2250533dadf
Version change: 2.82.1-102 || etlegacy-v2.82.1-102-g1d2692c-x86_64.tar.gz || hash: 1d2692c9b1b636ef7acaaa6ec54f3dc816f9d638
Version change: 2.82.1-124 || etlegacy-v2.82.1-124-gb4b47c7-x86_64.tar.gz || hash: b4b47c7ae8f2b839794f795049a82c4fc6a28292
Version change: 2.82.1-96 || etlegacy-v2.82.1-96-gb3e34ce-x86_64.tar.gz || hash: b3e34cea85371f4c26a809c4f460e2250533dadf
Version change: 2.82.1-143 || etlegacy-v2.82.1-143-g604420c-x86_64.tar.gz || hash: 604420c48f6dc3df1de08dab79b0f164e7bb1dc7
Version change: 2.82.1-148 || etlegacy-v2.82.1-148-g2230fc2-x86_64.tar.gz || hash: 2230fc25ff4a34259e612f2b843fb8034d6d00ad
Version change: 2.82.1-151 || etlegacy-v2.82.1-151-gd8eeaa0-x86_64.tar.gz || hash: d8eeaa0629e282f32a5c2256783fa9addc82b0d2
Version change: 2.82.1-156 || etlegacy-v2.82.1-156-g609fdca-x86_64.tar.gz || hash: 609fdcad2e082a1b62817f55d043b928c3789931
Version change: 2.82.1-219 || etlegacy-v2.82.1-219-ge963afd-x86_64.tar.gz || hash: e963afdc83c50db1df6761e6ede737171f6b2711
Version change: 2.82.1-253 || etlegacy-v2.82.1-253-geb38490-x86_64.tar.gz || hash: eb384903d3a42b5583e8b24ce07de38ecc97d6f1
Version change: 2.82.1-269 || etlegacy-v2.82.1-269-gcf348cb-x86_64.tar.gz || hash: cf348cb6ef5af6f71a877e627af69b594b586169
Version change: 2.82.1-276 || etlegacy-v2.82.1-276-g457a1ae-x86_64.tar.gz || hash: 457a1ae0080bf8296ab4e9a61cf754241d5d1460
Version change: 2.82.1-286 || etlegacy-v2.82.1-286-g0f31f07-x86_64.tar.gz || hash: 0f31f07ac2b2207499e1670ca5ef4370054a6995
Version change: 2.82.1-287 || etlegacy-v2.82.1-287-g4e3ea51-x86_64.tar.gz || hash: 4e3ea515d3e2161d01c26202bf20f2251669cf69
Version change: 2.82.1-291 || etlegacy-v2.82.1-291-gd8d0053-x86_64.tar.gz || hash: d8d00536b43dc4b092826ce7f65fdb76e6f4a261
Version change: 2.82.1-294 || etlegacy-v2.82.1-294-gf765002-x86_64.tar.gz || hash: f76500248e78fcf9ec13827138c4976668a4cfa1
Version change: 2.82.1-296 || etlegacy-v2.82.1-296-g0944c67-x86_64.tar.gz || hash: 0944c6757ed293b91a17cc2533ea6338b94ce474
Version change: 2.82.1-297 || etlegacy-v2.82.1-297-ga5de3cc-x86_64.tar.gz || hash: a5de3ccb510aa7615c8ef7e8e49622114f223430
Version change: 2.82.1-219 || etlegacy-v2.82.1-219-ge963afd-x86_64.tar.gz || hash: e963afdc83c50db1df6761e6ede737171f6b2711
Version change: 2.82.1-306 || etlegacy-v2.82.1-306-g7cf4f61-x86_64.tar.gz || hash: 7cf4f61cf1a9b79b75d1afe02d52afca991ec0bd
Version change: 2.82.1-310 || etlegacy-v2.82.1-310-ge411806-x86_64.tar.gz || hash: e41180623b98125f99c0c83f283c67fea46d947b
Version change: 2.82.1-315 || etlegacy-v2.82.1-315-g23df723-x86_64.tar.gz || hash: 23df72370d60632c898b9a5e67f7547aa1afdf7c
Version change: 2.82.1-332 || etlegacy-v2.82.1-332-gb6727a9-x86_64.tar.gz || hash: b6727a981243f0aab23267dfe24d673714b36b99
Version change: 2.82.1-333 || etlegacy-v2.82.1-333-g1569153-x86_64.tar.gz || hash: 1569153d2bd5dd084f78ff076206c5b38bcb73fd
Version change: 2.82.1-351 || etlegacy-v2.82.1-351-gfca1d03-x86_64.tar.gz || hash: fca1d0346177eaa448be3934b39dfa102ef2e63f
Version change: 2.82.1-353 || etlegacy-v2.82.1-353-gcb37ed7-x86_64.tar.gz || hash: cb37ed7e228909c86717cc935d97fe931ae328b8
Version change: 2.82.1-368 || etlegacy-v2.82.1-368-ge1d40d2-x86_64.tar.gz || hash: e1d40d200ffe9748f4e3ac737505b6669275cc51
Version change: 2.82.1-393 || etlegacy-v2.82.1-393-gc0066e4-x86_64.tar.gz || hash: c0066e423c7be7af1511c5748773aa58e610097f
Version change: 2.82.1-400 || etlegacy-v2.82.1-400-g78b4aef-x86_64.tar.gz || hash: 78b4aefe05ab9e2568e89b25111be56f85875183
Version change: 2.82.1-402 || etlegacy-v2.82.1-402-g8389390-x86_64.tar.gz || hash: 838939067f82a3c30ef22e1c8345474138c7480d
Version change: 2.82.1-411 || etlegacy-v2.82.1-411-gb746ee8-x86_64.tar.gz || hash: b746ee8f3183c9cece8554c584944f3331a70d15
Version change: 2.83.0     || etlegacy-v2.83.0-x86_64.tar.gz              || hash: 24c9f2b58c3f4c5e3bacdc89c475e7c
Version change: 2.83.1     || etlegacy-v2.83.1-x86_64.tar.gz              || hash: 96610ba015e468b73cf3017d6d11ccc1
Version change: 2.83.1-2 || etlegacy-v2.83.1-2-g039174c-x86_64.tar.gz || hash: 039174cb82de2172b64d6265e6c520ae9bfb7717
Version change: 2.83.1-9 || etlegacy-v2.83.1-9-g043fa19-x86_64.tar.gz || hash: 043fa19510e570a15dfbe905f58f2ff55c79adc2
Version change: 2.83.1-12 || etlegacy-v2.83.1-12-g2c26b58-x86_64.tar.gz || hash: 2c26b58b770f1f68f65d07240849ba0c631bcd4b
Version change: 2.83.1-13 || etlegacy-v2.83.1-13-g474871e-x86_64.tar.gz || hash: 474871ebd84217c8b1f5862b99f75bf04fc74bcd
Version change: 2.83.1-15 || etlegacy-v2.83.1-15-g511f45f-x86_64.tar.gz || hash: 511f45fc60504aa501922cda6105270a784ac6fd
Version change: 2.83.1-17 || etlegacy-v2.83.1-17-gfaeb5b7-x86_64.tar.gz || hash: faeb5b71696fbf9a65ec8dfbf9636b9d10050d55
```
