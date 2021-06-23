FROM ubuntu:20.04 AS xorg

ENV DEBIAN_FRONTEND=noninteractive 
ENV TZ="Europe/London"
ENV DISPLAY :0

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Video driver taken from https://github.com/mviereck/x11docker/wiki/Hardware-acceleration#hardware-acceleration-with-open-source-drivers-mesa
    mesa-utils mesa-utils-extra \
    # X11 taken from https://github.com/Kry07/docker-xorg/blob/xonly/Dockerfile
    xz-utils unzip avahi-utils dbus \
	xserver-xorg-core libgl1-mesa-glx libgl1-mesa-dri libglu1-mesa xfonts-base \
	x11-session-utils x11-utils x11-xfs-utils x11-xserver-utils xauth x11-common \
    # Input drivers
    xserver-xorg-input-libinput \
    && rm -rf /var/lib/apt/lists/*


COPY configs/xorg.conf /usr/share/X11/xorg.conf.d/20-sunshine.conf
COPY scripts/xorg_startup.sh /xorg_startup.sh

FROM xorg AS base 

ENV UNAME retro

RUN apt-get update -y && \
    apt-get install -y \
    libssl-dev libavdevice-dev libboost-thread-dev libboost-filesystem-dev libboost-log-dev libpulse-dev libopus-dev libxtst-dev libx11-dev libxrandr-dev libxfixes-dev libevdev-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev

######################################
FROM base AS sunshine-builder

# Pulling Sunshine v0.7 with fixes for https://github.com/loki-47-6F-64/sunshine/issues/97
ARG SUNSHINE_SHA=23b09e3d416cc57b812544c097682060be5b3dd3
ENV SUNSHINE_SHA=${SUNSHINE_SHA}

RUN apt-get install -y git build-essential cmake

RUN git clone https://github.com/loki-47-6F-64/sunshine.git && \
    cd sunshine && \
    # Fix the SHA commit
    git checkout $SUNSHINE_SHA && \
    # Just printing out git info so that I can double check on CI if the right version as been picked up
    git show && \
    # Recursively download submodules
    git submodule update --init --recursive && \
    # Normal compile
    mkdir build && cd build && \
    cmake .. && \
    make -j ${nproc}

######################################
FROM base as pulseaudio

# Taken from https://github.com/jessfraz/dockerfiles/blob/master/pulseaudio/
RUN apt-get update && apt-get install -y --no-install-recommends \
    alsa-utils \
    libasound2 \
    libasound2-plugins \
    pulseaudio \
    pulseaudio-utils \
    && rm -rf /var/lib/apt/lists/*

COPY configs/pulseaudio/default.pa /etc/pulse/default.pa
COPY configs/pulseaudio/client.conf /etc/pulse/client.conf
COPY configs/pulseaudio/daemon.conf /etc/pulse/daemon.conf

######################################
FROM pulseaudio AS sunshine-retroarch

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Install retroarch
    software-properties-common && \
    add-apt-repository ppa:libretro/stable && \
    apt-get install -y retroarch libretro-* && \
    # Cleanup
    apt-get remove -y software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# Get compiled sunshine
COPY --from=sunshine-builder /sunshine/build/ /sunshine/
COPY --from=sunshine-builder /sunshine/assets/ /sunshine/assets

# Config files
COPY configs/sunshine.conf /sunshine/sunshine.conf
COPY configs/apps.json /sunshine/apps.json

COPY scripts/startup-gpu.sh /startup.sh
COPY ensure-nvidia-xorg-driver.sh /ensure-nvidia-xorg-driver.sh

COPY configs/retroarch.cfg /retroarch.cfg
COPY configs/xorg-nvidia.conf /usr/share/X11/xorg.conf.d/09-nvidia-custom-location.conf

# Set up the user
# Taken from https://github.com/TheBiggerGuy/docker-pulseaudio-example
RUN export UNAME=$UNAME UID=1000 GID=1000 && \
    mkdir -p "/home/${UNAME}" && \
    echo "${UNAME}:x:${UID}:${GID}:${UNAME} User,,,:/home/${UNAME}:/bin/bash" >> /etc/passwd && \
    echo "${UNAME}:x:${UID}:" >> /etc/group && \
    mkdir -p /etc/sudoers.d && \
    echo "${UNAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${UNAME} && \
    chmod 0440 /etc/sudoers.d/${UNAME} && \
    chown ${UID}:${GID} -R /home/${UNAME} && \
    chown ${UID}:${GID} -R /sunshine/ && \
    gpasswd -a ${UNAME} audio && \
    # Attempt to fix permissions
    usermod -a -G systemd-resolve,audio,video,render ${UNAME}

USER root
WORKDIR /sunshine/

# Port configuration taken from https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide#manual-port-forwarding-advanced
EXPOSE 47984-47990/tcp
EXPOSE 48010
EXPOSE 48010/udp 
EXPOSE 47998-48000/udp


CMD /bin/bash /startup.sh
