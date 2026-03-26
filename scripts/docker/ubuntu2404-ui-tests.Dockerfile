FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    findutils \
    fontconfig \
    fonts-dejavu-core \
    fonts-liberation \
    fonts-noto-core \
    git \
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
    openjdk-21-jre-headless \
    python3 \
    sed \
    tar \
    ttf-mscorefonts-installer \
    tigervnc-standalone-server \
  && rm -rf /var/lib/apt/lists/*

RUN cat <<'EOF' >/etc/fonts/local.conf
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>Segoe UI</family>
    <prefer>
      <family>Liberation Sans</family>
      <family>Arial</family>
    </prefer>
  </alias>
  <alias>
    <family>Teen</family>
    <prefer>
      <family>Liberation Sans</family>
      <family>Arial</family>
    </prefer>
  </alias>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Liberation Sans</family>
      <family>Arial</family>
    </prefer>
  </alias>
</fontconfig>
EOF

RUN fc-cache -f

WORKDIR /workspace/capella
