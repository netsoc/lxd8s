#!/bin/sh
set -ex

IFACE_VM_INET="vm-inet"
IFACE_VM_LXD="vm-lxd"
IFACE_LXD_BRIDGE="lxd-bridge"

random_mac() {
    printf '%02x' $((0x$(od /dev/urandom -N1 -t x1 -An | cut -c 2-) & 0xFE | 0x02)); od /dev/urandom -N5 -t x1 -An | sed 's/ /:/g'
}

b64() {
    base64 - | tr -d '\n'
}

extract_secret() {
    printf '%s' $1 | jq -r .data[\"$2\"] | base64 -d
}

ensure_link_gone() {
    (ip link show "$1" > /dev/null 2>&1 && ip link del "$1") || true
}

# Get the address part of an IP network (e.g. 192.168.1.1/24 -> 192.168.1.1)
ip_net_addr() {
    echo "$1" | sed -r 's|(.+)/.+|\1|'
}

get_link_mtu() {
    ip link show dev "$1" | grep mtu | awk '{ print $5 }'
}

setup_network() {
    CMDLINE="$CMDLINE hostname=$(hostname)"

    iface_host_inet="$(ip route | grep default | awk '{ print $5 }')"
    inet_mtu="$(get_link_mtu $iface_host_inet)"

    # Set up host side of VM internet interface
    ensure_link_gone "$IFACE_VM_INET"
    ip tuntap add "$IFACE_VM_INET" mode tap
    ip link set dev "$IFACE_VM_INET" up
    ip link set dev "$IFACE_VM_INET" mtu "$inet_mtu"
    ip addr add "$INET_HOST" dev "$IFACE_VM_INET"
    inet_host_addr="$(ip_net_addr $INET_HOST)"
    inet_vm_addr="$(ip_net_addr $INET_VM)"
    CMDLINE="$CMDLINE inet_mtu=$inet_mtu inet_addr=$INET_VM inet_gw=$inet_host_addr"

    # Create host side of VM LXD interface
    ensure_link_gone "$IFACE_VM_LXD"
    ip tuntap add "$IFACE_VM_LXD" mode tap
    ip link set dev "$IFACE_VM_LXD" up

    # Set up NAT so that LXD requests go to the VM's internet interface and traffic coming from the VM's internet
    # interface is routed properly
    iptables -t nat -F
    iptables -t nat -A POSTROUTING -s "$inet_vm_addr" -j SNAT --to-source "$(hostname -i)"
    iptables -t nat -A PREROUTING -d "$(hostname)" -p tcp --dport 443 -j DNAT --to-destination "$inet_vm_addr"

    # If we're using kubelan, wait until it's up and snatch the VXLAN interface name and MTU
    ([ -z "$KUBELAN" ] || [ "$KUBELAN" = "no" ]) && return
    until curl -f -s localhost:8181/health > /dev/null; do sleep 0.5; done
    overlay_iface="$(curl -s localhost:8181/config | jq -r .VXLAN.Interface)"
    lxd_mtu="$(get_link_mtu $overlay_iface)"

    # Set up bridge across kubelan and host side of VM LXD bridge
    ensure_link_gone "$IFACE_LXD_BRIDGE"
    ip link add "$IFACE_LXD_BRIDGE" type bridge
    ip link set dev "$IFACE_LXD_BRIDGE" up
    ip link set dev "$IFACE_LXD_BRIDGE" mtu "$lxd_mtu"
    ip link set dev "$overlay_iface" master "$IFACE_LXD_BRIDGE"
    ip link set dev "$IFACE_VM_LXD" master "$IFACE_LXD_BRIDGE"
    CMDLINE="$CMDLINE lxd_mtu=$lxd_mtu"
}

make_overlay() {
    mkdir /tmp/overlay

    mkdir -p /tmp/overlay/etc
    sed 's|^nameserver 127..*|nameserver 1.1.1.1|' < /etc/resolv.conf > /tmp/overlay/etc/resolv.conf

    if [ -n "$CERT_SECRET_BASE" ]; then
        set +x
        source k8s.sh
        INDEX="$(hostname | sed -r 's|^.*-([0-9]+)|\1|')"
        data="$(k8s_get "api/v1/namespaces/$K8S_NAMESPACE/secrets/${CERT_SECRET_BASE}${INDEX}")"

        mkdir -p /tmp/overlay/var/lib/lxd
        extract_secret "$data" "ca.crt" > /tmp/overlay/var/lib/lxd/ca.crt
        extract_secret "$data" "tls.crt" > /tmp/overlay/var/lib/lxd/server.crt
        extract_secret "$data" "tls.key" > /tmp/overlay/var/lib/lxd/server.key
        set -x
    fi

    tar -C /tmp/overlay -cf overlay.tar .
    rm -r /tmp/overlay
}

mkdir -p /dev/net
[ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200

CMDLINE="console=ttyS0 noapic reboot=k panic=1"

setup_network
make_overlay

[ -e "$LXD_DATA" ] || truncate -s 4G "$LXD_DATA"
[ -e "$LXD_STORAGE" ] || truncate -s 16G "$LXD_STORAGE"


rm -f /run/firecracker.sock
exec firectl \
    --socket-path /run/firecracker.sock \
    --ncpus $CPUS \
    --memory $MEM \
    --tap-device "$IFACE_VM_INET/$(random_mac)" \
    --tap-device "$IFACE_VM_LXD/$(random_mac)" \
    --kernel ./vmlinux \
    --kernel-opts "$CMDLINE" \
    --root-drive ./rootfs.img \
    --add-drive "$LXD_DATA:rw" \
    --add-drive "./overlay.tar:ro" \
    --add-drive "$LXD_STORAGE:rw"
