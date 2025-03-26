#docker/dockerfile:1
FROM riscv64/ubuntu:24.04 as base
# install app dependencies
ENV DEBIAN_FRONTEND="noninteractive"

RUN apt-get update && apt-get install -y --no-install-recommends \
apt-utils \
&& apt-get upgrade -y \
&& rm -rf /var/lib/apt/lists/*

# make the "en_US.UTF-8" locale so postgres will be utf-8 enabled by default
RUN apt-get update && apt-get install -y locales && rm -rf /var/lib/apt/lists/* \
        && localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG en_US.utf8

RUN apt-get update && apt-get install -y --no-install-recommends \
autoconf \
automake \
autotools-dev \
bluez \
build-essential \
cmake \
ffmpeg \
libavcodec-dev \
libavformat-dev \
libavutil-dev \
libavdevice-dev \
libavfilter-dev \
libffi-dev \
libssl-dev \
libjpeg-dev \
libopenjp2-7 \
libtiff6 \
libturbojpeg0-dev \
liblapack3 \
liblapack-dev \
libatlas-base-dev \
libswscale-dev \
libopenblas-dev \
pkg-config \
python3 \
python3-dev \
python3-venv \
python3-pip \
tzdata \
zlib1g-dev \
&& rm -rf /var/lib/apt/lists/*

#TODO work under root user
RUN useradd -rm homeassistant -d /srv/homeassistant -G dialout,tty

WORKDIR /srv/homeassistant

FROM base as builder

RUN apt-get update && apt-get install -y --no-install-recommends \
curl \
git \
&& rm -rf /var/lib/apt/lists/*

USER homeassistant

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

ENV PATH="/srv/homeassistant/.cargo/bin:$PATH"

RUN python3 -m venv .
ENV PATH="/srv/homeassistant/bin:$PATH"

RUN python3 -m pip install wheel

# Эти - дополнительно, нужны для корректной работы
# Не встают сами нормально
RUN python3 -m pip install numpy==1.26.0 PyTurboJPEG==1.7.5
RUN python3 -m pip install josepy==1.15.0
RUN python3 -m pip install zlib_ng isal libpcap pyatv==0.16.0

RUN git clone https://github.com/PaTara43/py-bindings-wheels-risc-v && \
cd py-bindings-wheels-risc-v && \
pip3 install *

RUN python3 -m pip install homeassistant==2025.1.3
RUN python3 -m pip install robonomics-interface~=1.6
RUN python3 -m pip install paho-mqtt~=2.1
RUN python3 -m pip install crust-interface-patara==0.1.1

FROM base as runner

RUN mkdir config

#TODO copy files to /usr/local/bin directory
COPY --from=builder /srv/homeassistant/bin  /srv/homeassistant/bin
COPY --from=builder /srv/homeassistant/include  /srv/homeassistant/include
COPY --from=builder /srv/homeassistant/lib  /srv/homeassistant/lib
COPY --from=builder /srv/homeassistant/lib64  /srv/homeassistant/lib64
COPY --from=builder /srv/homeassistant/pyvenv.cfg  /srv/homeassistant/pyvenv.cfg

COPY go2rtc /usr/bin

ENV PATH="/srv/homeassistant/bin:$PATH"

CMD ["hass", "-c", "config"]
