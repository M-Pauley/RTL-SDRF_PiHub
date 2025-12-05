#!/usr/bin/env bash
#
# SDR/RF Hub setup script for Raspberry Pi B
# Features:
#  - Base dependencies and RTL-SDR setup
#  - rtl_tcp I/Q streaming service
#  - readsb ADS-B decoder + web map
#  - Additional rtl_tcp services for extra dongles
#  - Prometheus node exporter (prometheus-node-exporter)
#

set -e

#######################################
# Helpers
#######################################

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "This script must be run as root. Try: sudo $0"
    exit 1
  fi
}

press_enter() {
  echo
  read -rp "Press Enter to continue..." _
}

#######################################
# 1. Base install
#######################################

install_base() {
  echo "==> Updating apt and installing base packages..."
  apt update
  apt upgrade -y

  apt install -y \
    rtl-sdr \
    git \
    build-essential \
    debhelper \
    libusb-1.0-0-dev \
    librtlsdr-dev \
    curl \
    net-tools \
    sudo

  echo "==> Blacklisting DVB kernel modules for RTL-SDR..."
  local BLACKLIST_FILE="/etc/modprobe.d/blacklist-rtl.conf"

  if [[ ! -f "$BLACKLIST_FILE" ]]; then
    touch "$BLACKLIST_FILE"
  fi

  grep -q "dvb_usb_rtl28xxu" "$BLACKLIST_FILE" 2>/dev/null || echo "blacklist dvb_usb_rtl28xxu" >> "$BLACKLIST_FILE"
  grep -q "rtl2832"         "$BLACKLIST_FILE" 2>/dev/null || echo "blacklist rtl2832"         >> "$BLACKLIST_FILE"
  grep -q "rtl2830"         "$BLACKLIST_FILE" 2>/dev/null || echo "blacklist rtl2830"         >> "$BLACKLIST_FILE"

  echo
  echo "Base install done."
  echo "NOTE: A reboot is recommended after first run so the DVB modules are fully disabled."
  press_enter
}

#######################################
# 2. Configure rtl_tcp I/Q streaming
#######################################

configure_rtl_tcp() {
  echo "==> Configure rtl_tcp I/Q streaming service"
  echo
  read -rp "Port for primary rtl_tcp instance [1234]: " RTL_TCP_PORT
  RTL_TCP_PORT=${RTL_TCP_PORT:-1234}

  read -rp "RTL-SDR device index for this stream [0]: " RTL_TCP_DEV
  RTL_TCP_DEV=${RTL_TCP_DEV:-0}

  local SERVICE_FILE="/etc/systemd/system/rtl_tcp.service"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=RTL-SDR TCP Server (primary)
After=network.target

[Service]
ExecStart=/usr/bin/rtl_tcp -a 0.0.0.0 -p ${RTL_TCP_PORT} -d ${RTL_TCP_DEV}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable rtl_tcp
  systemctl restart rtl_tcp

  echo
  echo "rtl_tcp service configured:"
  echo "  Port:   ${RTL_TCP_PORT}"
  echo "  Device: ${RTL_TCP_DEV}"
  echo
  echo "You can verify with:"
  echo "  netstat -tnlp | grep ${RTL_TCP_PORT}"
  press_enter
}

#######################################
# 3. Install readsb (ADS-B decode + web map)
#######################################

install_readsb() {
  echo "==> Installing readsb (ADS-B decoder + web map)..."
  echo "This may take a while on a Pi 1."

  # Build and install readsb from source using debhelper
  cd /tmp
  if [[ -d readsb ]]; then
    rm -rf readsb
  fi

  git clone https://github.com/wiedehopf/readsb.git
  cd readsb

  dpkg-buildpackage -b
  cd ..
  dpkg -i ./readsb_*.deb || apt -f install -y

  echo
  echo "readsb installed."
  echo "By default, it will try to use an RTL-SDR directly."
  echo "If you have multiple dongles, you will likely want:"
  echo "  - Device 0 for rtl_tcp (general I/Q hub)"
  echo "  - Device 1 for readsb (ADS-B)."
  echo
  echo "You can adjust readsb options in /etc/default/readsb (or /etc/readsb.conf, depending on version)."
  echo "Typical extra options to set in the config file:"
  echo
  echo "  --device-type rtlsdr --device-index 1 --lat <your_lat> --lon <your_lon>"
  echo
  echo "Starting and enabling readsb service..."
  systemctl enable readsb
  systemctl restart readsb

  echo
  echo "Once running, you should get a web map at:"
  echo "  http://<pi-ip>/readsb/"
  echo "or sometimes on port 8080 depending on your config."
  press_enter
}

#######################################
# 4. Configure additional rtl_tcp services
#######################################

configure_additional_rtl_tcp() {
  echo "==> Configure an additional rtl_tcp service"
  echo "This is useful for extra dongles / frequencies."
  echo

  read -rp "Name suffix for this instance (e.g. 2, adsb, airband): " SUFFIX
  if [[ -z "$SUFFIX" ]]; then
    echo "Suffix cannot be empty."
    press_enter
    return
  fi

  read -rp "Port for this rtl_tcp instance [1235]: " ADD_PORT
  ADD_PORT=${ADD_PORT:-1235}

  read -rp "RTL-SDR device index for this instance [1]: " ADD_DEV
  ADD_DEV=${ADD_DEV:-1}

  local SERVICE_FILE="/etc/systemd/system/rtl_tcp_${SUFFIX}.service"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=RTL-SDR TCP Server (${SUFFIX})
After=network.target

[Service]
ExecStart=/usr/bin/rtl_tcp -a 0.0.0.0 -p ${ADD_PORT} -d ${ADD_DEV}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "rtl_tcp_${SUFFIX}.service"
  systemctl restart "rtl_tcp_${SUFFIX}.service"

  echo
  echo "Additional rtl_tcp service configured:"
  echo "  Service name: rtl_tcp_${SUFFIX}.service"
  echo "  Port:         ${ADD_PORT}"
  echo "  Device index: ${ADD_DEV}"
  echo
  echo "Verify with:"
  echo "  netstat -tnlp | grep ${ADD_PORT}"
  press_enter
}

#######################################
# 5. Install Prometheus node exporter
#######################################

install_prometheus_node_exporter() {
  echo "==> Installing Prometheus node exporter (via apt)..."
  echo "This exposes system metrics on port 9100 for your Prometheus server."

  apt update
  apt install -y prometheus-node-exporter

  systemctl enable prometheus-node-exporter
  systemctl restart prometheus-node-exporter

  echo
  echo "Prometheus node exporter installed and running."
  echo "Scrape endpoint (from your Prometheus server):"
  echo "  http://<pi-ip>:9100/metrics"
  press_enter
}

#######################################
# Main menu
#######################################

show_menu() {
  clear
  echo "==============================================="
  echo "   SDR / RF Hub Setup - Raspberry Pi"
  echo "==============================================="
  echo
  echo "1) Install base dependencies (RTL-SDR, tools, blacklist DVB)"
  echo "2) Configure primary I/Q stream (rtl_tcp service)"
  echo "3) Install ADS-B decoder + web map (readsb)"
  echo "4) Configure an additional rtl_tcp service"
  echo "5) Install Prometheus node exporter"
  echo "6) Exit"
  echo
  read -rp "Select an option [1-6]: " CHOICE
}

main() {
  require_root

  while true; do
    show_menu
    case "$CHOICE" in
      1) install_base ;;
      2) configure_rtl_tcp ;;
      3) install_readsb ;;
      4) configure_additional_rtl_tcp ;;
      5) install_prometheus_node_exporter ;;
      6) echo "Exiting."; exit 0 ;;
      *) echo "Invalid choice." ; press_enter ;;
    esac
  done
}

main "$@"
