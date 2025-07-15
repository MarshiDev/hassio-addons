#!/bin/bash

# -- Signal handler
cleanup(){
    echo "Cleaning up..."
    ip link set br0 down 2>/dev/null
    brctl delbr br0 2>/dev/null
    ip link set ${INTERFACE_AP} down 2>/dev/null
    iw dev ${INTERFACE_AP} del 2>/dev/null
    iptables -t nat -D POSTROUTING -o ${INTERNET_IF} -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -i ${INTERNET_IF} -o ${INTERFACE_AP} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i ${INTERFACE_AP} -o ${INTERNET_IF} -j ACCEPT 2>/dev/null
    echo "Done cleanup"
    exit 0
}
trap cleanup SIGTERM

echo "Starting..."

CONFIG_PATH=/data/options.json

SSID=$(jq -r ".ssid" $CONFIG_PATH)
WPA_PASSPHRASE=$(jq -r ".wpa_passphrase" $CONFIG_PATH)
CHANNEL=$(jq -r ".channel" $CONFIG_PATH)
ADDRESS=$(jq -r ".address" $CONFIG_PATH)
NETMASK=$(jq -r ".netmask" $CONFIG_PATH)
BROADCAST=$(jq -r ".broadcast" $CONFIG_PATH)
INTERFACE=$(jq -r ".interface" $CONFIG_PATH)
INTERNET_IF=$(jq -r ".internet_interface" $CONFIG_PATH)
HIDE_SSID=$(jq -r ".hide_ssid" $CONFIG_PATH)

DHCP_START=$(jq -r ".dhcp_start" $CONFIG_PATH)
DHCP_END=$(jq -r ".dhcp_end" $CONFIG_PATH)
DHCP_DNS=$(jq -r ".dhcp_dns" $CONFIG_PATH)
DHCP_SUBNET=$(jq -r ".dhcp_subnet" $CONFIG_PATH)
DHCP_ROUTER=$(jq -r ".dhcp_router" $CONFIG_PATH)
LEASE_TIME=$(jq -r ".lease_time" $CONFIG_PATH)
STATIC_LEASES=$(jq -r '.static_leases[] | "\(.mac),\(.ip),\(.name)"' $CONFIG_PATH)

# Sanity check
for VAR in SSID WPA_PASSPHRASE CHANNEL ADDRESS NETMASK BROADCAST INTERFACE INTERNET_IF DHCP_START DHCP_END DHCP_DNS DHCP_SUBNET DHCP_ROUTER; do
  if [[ -z "${!VAR}" ]]; then
    echo >&2 "Error: $VAR not set in options.json"
    exit 1
  fi
done

# VIF setup (always enabled)
INTERFACE_AP="${INTERFACE}_ap"
if ! iw dev | grep -q "${INTERFACE_AP}"; then
    echo "Creating AP VIF: ${INTERFACE_AP}"
    iw dev ${INTERFACE} interface add ${INTERFACE_AP} type __ap
fi

# Bring up interfaces
ip link set ${INTERFACE} up
ip link set ${INTERFACE_AP} up
ip link set ${INTERNET_IF} up

# Always use bridge mode
echo "Creating bridge br0"
brctl addbr br0
brctl addif br0 ${INTERFACE_AP}
brctl addif br0 ${INTERNET_IF}
ip link set br0 up

# Setup IP on bridge (optional, mostly for DHCP server's use)
ip addr add ${ADDRESS}/${NETMASK} brd ${BROADCAST} dev br0

# Hostapd config
HCONFIG="/hostapd.conf"
cat <<EOF > ${HCONFIG}
interface=${INTERFACE_AP}
bridge=br0
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

[[ "$HIDE_SSID" == "true" ]] && echo "ignore_broadcast_ssid=1" >> ${HCONFIG}

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# Configure NAT
iptables -t nat -A POSTROUTING -o ${INTERNET_IF} -j MASQUERADE
iptables -A FORWARD -i ${INTERNET_IF} -o ${INTERFACE_AP} -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i ${INTERFACE_AP} -o ${INTERNET_IF} -j ACCEPT

# DHCP setup
UCONFIG="/etc/udhcpd.conf"
mkdir -p /var/lib/udhcpd
touch /var/lib/udhcpd/udhcpd.leases

START_OCTET=$(echo ${DHCP_START} | cut -d. -f4)
END_OCTET=$(echo ${DHCP_END} | cut -d. -f4)
MAX_LEASES=$((END_OCTET - START_OCTET + 1))

cat <<EOF > ${UCONFIG}
interface    ${INTERFACE_AP}
start        ${DHCP_START}
end          ${DHCP_END}
max_leases   ${MAX_LEASES}
opt dns      ${DHCP_DNS}
opt subnet   ${DHCP_SUBNET}
opt router   ${DHCP_ROUTER}
opt lease    ${LEASE_TIME}
EOF

# Static leases
while IFS=, read -r mac ip name; do
    [[ -n "$mac" && -n "$ip" ]] && echo "static_lease ${mac} ${ip} # ${name}" >> ${UCONFIG}
done <<< "${STATIC_LEASES}"

# Start DHCP and AP
echo "Starting DHCP..."
udhcpd -f &

echo "Starting hostapd..."
hostapd ${HCONFIG} &

# Monitor loop
while true; do
    echo "Interface ${INTERFACE_AP} status:"
    ifconfig ${INTERFACE_AP}
    sleep 3600
done
