FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    dbus-x11 \
    findutils \
    fontconfig \
    fonts-dejavu-core \
    grep \
    libasound2t64 \
    libgbm1 \
    libgtk-3-0 \
    libnss3 \
    libx11-xcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxtst6 \
    metacity \
    openjdk-21-jre-headless \
    python3 \
    locales \
    sed \
    tar \
    tigervnc-standalone-server \
    wmctrl \
    x11-utils \
    x11-xserver-utils \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
  && locale-gen en_US.UTF-8

RUN cat <<'EOF' >/etc/fonts/local.conf
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>Segoe UI</family>
    <prefer>
      <family>DejaVu Sans</family>
    </prefer>
  </alias>
  <alias>
    <family>Teen</family>
    <prefer>
      <family>DejaVu Sans</family>
    </prefer>
  </alias>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>DejaVu Sans</family>
    </prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer>
      <family>DejaVu Serif</family>
    </prefer>
  </alias>
  <alias>
    <family>monospace</family>
    <prefer>
      <family>DejaVu Sans Mono</family>
    </prefer>
  </alias>
</fontconfig>
EOF

RUN fc-cache -f

WORKDIR /workspace/capella
