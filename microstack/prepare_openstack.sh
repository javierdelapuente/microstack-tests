#!/bin/bash
set -x
set -euo pipefail

RISK=${RISK:-candidate}
RAM_MEMORY=${RAM_MEMORY:-42GiB}
ROOT_DISK_SIZE=${ROOT_DISK_SIZE:-500GiB}

REMOTE_ACCESS_LOCATION=${REMOTE_ACCESS_LOCATION:-true}

ENABLE_CEPH=${ENABLE_CEPH:-true}
CEPH_DISK_SIZE=${CEPH_DISK_SIZE:-500GiB}

ENABLE_VAULT=${ENABLE_VAULT:-true}
ENABLE_IMAGES_SYNC=${ENABLE_IMAGES_SYNC:-true}

echo RISK $RISK
echo RAM_MEMORY $RAM_MEMORY
echo ROOT_DISK_SIZE $ROOT_DISK_SIZE
echo REMOTE_ACCESS_LOCATION $REMOTE_ACCESS_LOCATION
echo ENABLE_CEPH $ENABLE_CEPH
echo CEPH_DISK_SIZE $CEPH_DISK_SIZE
echo ENABLE_VAULT $ENABLE_VAULT
echo ENABLE_IMAGES_SYNC $ENABLE_IMAGES_SYNC

export RISK
export ENABLE_CEPH

DATA_DIR="$(dirname "$0")/data"

DEBIAN_FRONTEND=noninteractive sudo apt-get update
DEBIAN_FRONTEND=noninteractive sudo apt-get install retry -y

# enable ipv4 forwarding in the host...
sudo sysctl -w net.ipv4.ip_forward=1

lxc delete openstack --force || :

init_args=( --config=user.user-data="$(cat "${DATA_DIR}/openstack-user-data" | envsubst '$RISK,$ENABLE_CEPH' )" )
if "${REMOTE_ACCESS_LOCATION}"
then
    init_args+=( --config=user.network-config="$(cat "${DATA_DIR}/openstack-network-config" )" )
    # not sure if all of this is necessary, but...
    sudo ufw route allow in on osbr0
    sudo ufw route allow in on osbr0
    sudo ufw route allow out on osbr0
    lxc network delete osbr0 || :
    # dns.mode to assign to the same bridge. We could have two bridges instead.
    lxc network create osbr0 ipv6.address=none ipv4.address=192.168.20.1/24 ipv4.dhcp.ranges=192.168.20.200-192.168.20.240 ipv4.firewall=false ipv4.nat=false dns.mode=none || :
fi

lxc init ubuntu:24.04 openstack --vm -c limits.cpu=12 -c limits.memory=${RAM_MEMORY} -d root,size=${ROOT_DISK_SIZE} "${init_args[@]}"
if "${REMOTE_ACCESS_LOCATION}"
then
    lxc config device add openstack eth0 nic nictype=bridged parent=osbr0 name=eth0 hwaddr=00:14:4F:F8:00:01
    lxc config device add openstack eth1 nic nictype=bridged parent=osbr0 name=eth1 hwaddr=00:14:4F:F8:00:02
fi

# This is for ceph. There has to be a lxcpool storage defined.
if ${ENABLE_CEPH}
then
    lxc storage volume delete lxcpool ceph-vol || :
    lxc storage volume create lxcpool ceph-vol size=${CEPH_DISK_SIZE} --type=block
    lxc config device add openstack ceph-vol disk pool=lxcpool source=ceph-vol
fi

echo "Starting at $(date)"
lxc start openstack
# Besides at start, sometimes we get a websocket: close, not sure why.
time retry -d 5 -t 10 lxc exec openstack -- sh -c "cloud-init status --wait"

echo "cloud-init finished $(date)"

if "${REMOTE_ACCESS_LOCATION}"
then
    lxc file push "${DATA_DIR}/base-microstack-manifest" openstack/home/ubuntu/base-microstack-manifest --uid 1000
else
    lxc file push "${DATA_DIR}/base-microstack-manifest-local" openstack/home/ubuntu/base-microstack-manifest --uid 1000
fi
lxc file push "${DATA_DIR}/bootstrap_microstack.sh" openstack/home/ubuntu/bootstrap_microstack.sh --uid 1000
lxc file push "${DATA_DIR}/configure_microstack.sh" openstack/home/ubuntu/configure_microstack.sh --uid 1000

lxc exec openstack -- adduser ubuntu snap_daemon
lxc exec openstack -- su --login ubuntu -c "bash -l -c \"RISK=$RISK ENABLE_CEPH=$ENABLE_CEPH bash bootstrap_microstack.sh\""
echo "microstack bootstrapped $(date)"
lxc exec openstack -- su --login ubuntu -c "bash -l -c \"ENABLE_IMAGES_SYNC=$ENABLE_IMAGES_SYNC ENABLE_VAULT=$ENABLE_VAULT bash configure_microstack.sh\""
echo "microstack configured $(date)"

lxc exec openstack -- sudo -iu ubuntu sunbeam openrc
lxc exec openstack -- sudo -iu ubuntu cat /home/ubuntu/demo-openrc
lxc exec openstack -- sudo -iu ubuntu sunbeam dashboard-url
lxc exec openstack -- sudo -iu ubuntu sunbeam openrc > admin-openrc
echo "End at $(date)"

# lxc file pull openstack/home/ubuntu/demo-openrc .
# lxc exec openstack -- su --login ubuntu
