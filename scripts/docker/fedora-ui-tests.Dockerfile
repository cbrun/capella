FROM fedora:39

ENV LANG=en_US.UTF-8

RUN dnf -y update \
  && dnf -y install \
    bash \
    ca-certificates \
    coreutils \
    dbus-x11 \
    findutils \
    fontconfig \
    dejavu-sans-fonts \
    dejavu-serif-fonts \
    dejavu-sans-mono-fonts \
    grep \
    gtk3 \
    nss \
    libX11-xcb \
    libXcomposite \
    libXdamage \
    libXext \
    libXfixes \
    libXi \
    libXrandr \
    libXrender \
    libXtst \
    metacity \
    java-21-openjdk-headless \
    python3 \
    glibc-langpack-en \
    sed \
    tar \
    tigervnc-server-minimal \
    wmctrl \
    xrandr \
    xdpyinfo \
    xhost \
    xset \
    which \
  && dnf clean all

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
