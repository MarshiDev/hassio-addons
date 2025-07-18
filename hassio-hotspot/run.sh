#!/bin/bash

# SIGTERM-handler this funciton will be executed when the container receives the SIGTERM signal (when stopping)
reset_interfaces(){
    ip link set wlan0_ap down
    sleep 1
}

term_handler(){
    echo "Reseting interfaces and killing Servers"
    kill $DHCPD_PID $HOSTAPD_PID 2>/dev/null
    reset_interfaces
    iw dev wlan0_ap del 2>/dev/null
    echo "Stopping..."
    exit 0
}

# Setup signal handlers
trap 'term_handler' SIGTERM

echo "Starting..."

CONFIG_PATH=/data/options.json

SSID=$(jq --raw-output ".ssid" $CONFIG_PATH)
WPA_PASSPHRASE=$(jq --raw-output ".wpa_passphrase" $CONFIG_PATH)
INTERNET_IF=$(jq --raw-output ".internet_interface" $CONFIG_PATH)
HIDE_SSID=$(jq --raw-output ".hide_ssid" $CONFIG_PATH)

# Enforces required env variables
required_vars=(SSID WPA_PASSPHRASE INTERNET_IF)
for required_var in "${required_vars[@]}"; do
    if [[ -z ${!required_var} ]]; then
        echo >&2 "Error: $required_var env variable not set."
        exit 1
    fi
done

if ! (iw list | awk '/valid interface combinations:/,/^$/' | grep '#{ managed } <= 1' && iw list | awk '/valid interface combinations:/,/^$/' | grep '#{ AP } <= 1'); then
    echo >&2 "Wi-Fi adapter does not support simultaneous Access point and client mode (VIF)."
    echo >&2 "Please use a Wi-Fi adapter that supports concurrent interfaces (AP + STA) or disable VIF."
    exit 1
fi

# Ensure VIF exists
echo "Creating virtual interface wlan0_ap"
iw dev wlan0 interface add wlan0_ap type __ap
sleep 2

if ! ip link show wlan0_ap &>/dev/null; then
    echo "Interface wlan0_ap does not exist, hostapd will fail. Aborting."
    exit 1
fi

# Make wlan0 interface still show up in HA UI
nmcli connection delete "dummy-wifi"
nmcli connection add type wifi ifname wlan0 con-name dummy-wifi ssid "placeholder"
nmcli connection modify dummy-wifi connection.autoconnect no

echo "Set nmcli managed no"
nmcli dev set wlan0_ap managed no
nmcli connection delete "wlan0_ap" 2>/dev/null

echo "Network interface set to wlan0_ap"

# Setup hostapd.conf
HCONFIG="/hostapd.conf"

cat <<EOF > ${HCONFIG}
interface=wlan0_ap
ssid=${SSID}
wpa_passphrase=${WPA_PASSPHRASE}
channel=6
driver=nl80211
hw_mode=g
ieee80211n=1
wmm_enabled=0
macaddr_acl=0
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
logger_stdout=-1
logger_stdout_level=2
EOF

if test ${HIDE_SSID} = true; then
    echo "Hidding SSID"
    echo "ignore_broadcast_ssid=1" >> ${HCONFIG}
fi

# Setup interface
echo "Bringing up wlan0_ap"
ip link set wlan0_ap up
sleep 1
ip addr add 192.168.178.1/24 dev wlan0_ap

# Create leases directory and file
mkdir -p /var/lib/udhcpd
touch /var/lib/udhcpd/udhcpd.leases

# Setup hdhcpd.conf
UCONFIG="/etc/udhcpd.conf"

echo "Setup udhcpd.conf ..."
cat <<EOF > ${UCONFIG}
interface wlan0_ap
start 192.168.178.10
end 192.168.178.100
opt dns 8.8.8.8
opt subnet 255.255.255.0
opt router 192.168.178.1
opt domain local
lease_file /var/lib/udhcpd/udhcpd.leases
pidfile /var/run/udhcpd.pid
EOF

echo 1 > /proc/sys/net/ipv4/ip_forward

# Configure iptables to enable internet
echo "Configuring iptables for NAT"
iptables -t nat -A POSTROUTING -o ${INTERNET_IF} -j MASQUERADE
iptables -A FORWARD -i ${INTERNET_IF} -o wlan0_ap -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0_ap -o ${INTERNET_IF} -j ACCEPT

echo "Starting DHCP server..."
udhcpd -f & DHCPD_PID=$!

sleep 1

echo -e "\n==== Starting HostAP daemon ====\n"
hostapd ${HCONFIG} & HOSTAPD_PID=$!

sleep 2
if ! kill -0 $HOSTAPD_PID 2>/dev/null; then
    echo "hostapd failed to start. Exiting..."
    term_handler
fi
if ! kill -0 $DHCPD_PID 2>/dev/null; then
    echo "udhcpd failed to start. Exiting..."
    term_handler
fi

while true; do 
    echo "Interface stats:"
    ifconfig | grep wlan0_ap -A6
    sleep 3600
done
