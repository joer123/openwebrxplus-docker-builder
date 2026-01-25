# FreeDV KA9Q Support
This build includes **experimental** support for **FreeDV-U** and **FreeDV-L** modes using the `freedv-ka9q` decoder.
The build scripts automatically patch the OpenWebRX+ source code to enable the new modes and integrate the freedv-ka9q decoder.

To build the image:
```bash
git clone https://github.com/joer123/openwebrxplus-docker-builder.git
cd openwebrxplus-docker-builder
docker build -t slechev/openwebrxplus-freedv buildfiles
```
This command builds the Docker image using the scripts in the `buildfiles` folder and tags it as `slechev/openwebrxplus-freedv`.

# openwebrxplus-docker-builder
OpenWebRX+ docker images builder.  
Use this repo to build the official docker image and the SoftMBE image.  
The SoftMBE will use codecserver-softmbe (mbelib), enabling DMR, D-Star, YSF, FreeDV, DRM, NXDN and other Digital modes.

# Docker Hub
Check the [Docker Hub](https://hub.docker.com/r/slechev/openwebrxplus) page for the official image.  
Check the [Docker Hub](https://hub.docker.com/r/slechev/openwebrxplus-softmbe) page for the softmbe image.

# Install
See the [info of the official image](https://hub.docker.com/r/slechev/openwebrxplus).
