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
CHANNEL=$(jq --raw-output ".channel" $CONFIG_PATH)
ADDRESS=$(jq --raw-output ".address" $CONFIG_PATH)
NETMASK=$(jq --raw-output ".netmask" $CONFIG_PATH)
BROADCAST=$(jq --raw-output ".broadcast" $CONFIG_PATH)
INTERNET_IF=$(jq --raw-output ".internet_interface" $CONFIG_PATH)
ALLOW_INTERNET=$(jq --raw-output ".allow_internet" $CONFIG_PATH)
HIDE_SSID=$(jq --raw-output ".hide_ssid" $CONFIG_PATH)

DHCP_SERVER=$(jq --raw-output ".dhcp_enable" $CONFIG_PATH)
DHCP_START=$(jq --raw-output ".dhcp_start" $CONFIG_PATH)
DHCP_END=$(jq --raw-output ".dhcp_end" $CONFIG_PATH)
DHCP_DNS=$(jq --raw-output ".dhcp_dns" $CONFIG_PATH)
DHCP_SUBNET=$(jq --raw-output ".dhcp_subnet" $CONFIG_PATH)
DHCP_ROUTER=$(jq --raw-output ".dhcp_router" $CONFIG_PATH)

LEASE_TIME=$(jq --raw-output ".lease_time" $CONFIG_PATH)
STATIC_LEASES=$(jq -r '.static_leases // [] | .[] | "\(.mac),\(.ip),\(.name)"' $CONFIG_PATH)

# Enforces required env variables
required_vars=(SSID WPA_PASSPHRASE CHANNEL ADDRESS NETMASK BROADCAST)
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

# Configure iptables to enable/disable internet
RULE_3="POSTROUTING -o ${INTERNET_IF} -j MASQUERADE"
RULE_4="FORWARD -i ${INTERNET_IF} -o wlan0_ap -m state --state RELATED,ESTABLISHED -j ACCEPT"
RULE_5="FORWARD -i wlan0_ap -o ${INTERNET_IF} -j ACCEPT"

echo "Deleting iptables"
iptables -v -t nat -D $(echo ${RULE_3})
iptables -v -D $(echo ${RULE_4})
iptables -v -D $(echo ${RULE_5})

iptables -A INPUT -p udp --dport 5353 -j ACCEPT
iptables -A INPUT -p udp --dport 1900 -j ACCEPT

if test ${ALLOW_INTERNET} = true; then
    echo "Configuring iptables for NAT"
    iptables -v -t nat -A $(echo ${RULE_3})
    iptables -v -A $(echo ${RULE_4})
    iptables -v -A $(echo ${RULE_5})
fi


# Setup hostapd.conf
HCONFIG="/hostapd.conf"

cat <<EOF > ${HCONFIG}
interface=wlan0_ap
ssid=${SSID}
wpa_passphrase=${WPA_PASSPHRASE}
channel=${CHANNEL}
driver=nl80211
hw_mode=g
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

if test ${HIDE_SSID} = true; then
    echo "Hidding SSID"
    echo "ignore_broadcast_ssid=1" >> ${HCONFIG}
fi

# Setup interface
ip addr add ${ADDRESS}/${NETMASK} broadcast ${BROADCAST} dev wlan0_ap
echo "Bringing up wlan0_ap"
ip link set wlan0_ap up
sleep 1

if test ${DHCP_SERVER} = true; then
    # Create leases directory and file
    mkdir -p /var/lib/udhcpd
    touch /var/lib/udhcpd/udhcpd.leases

    # Calculate max leases from DHCP range
    START_IP_LAST_OCTET=$(echo ${DHCP_START} | cut -d. -f4)
    END_IP_LAST_OCTET=$(echo ${DHCP_END} | cut -d. -f4)
    MAX_LEASES=$((END_IP_LAST_OCTET - START_IP_LAST_OCTET + 1))

    # Setup hdhcpd.conf
    UCONFIG="/etc/udhcpd.conf"

    echo "Setup udhcpd.conf ..."
    cat <<EOF > ${UCONFIG}
interface    wlan0_ap
start        ${DHCP_START}
end          ${DHCP_END}
max_leases   ${MAX_LEASES}
opt dns      ${DHCP_DNS}
opt subnet   ${DHCP_SUBNET}
opt router   ${DHCP_ROUTER}
opt lease    ${LEASE_TIME}
EOF

    # Add static leases
    while IFS=, read -r mac ip name; do
        if [ ! -z "$mac" ] && [ ! -z "$ip" ]; then
            echo "static_lease ${mac} ${ip}  # ${name}" >> ${UCONFIG}
        fi
    done <<< "${STATIC_LEASES}"

    echo "Starting DHCP server..."
    udhcpd -f & DHCPD_PID=$!
fi

sleep 1

echo -e "\n==== Starting HostAP daemon ====\n"
hostapd ${HCONFIG} & HOSTAPD_PID=$!

sleep 2
if ! kill -0 $HOSTAPD_PID 2>/dev/null; then
    echo "hostapd failed to start. Exiting..."
    term_handler
fi

while true; do 
    echo "Interface stats:"
    ifconfig | grep wlan0_ap -A6
    echo "DHCP Leases:"
    cat /var/lib/udhcpd/udhcpd.leases
    sleep 3600
done
