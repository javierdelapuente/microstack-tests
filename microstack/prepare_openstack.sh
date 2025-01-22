#!/bin/bash

set -x
set -euo pipefail

RISK=candidate
RAM_MEMORY=42GiB
ROOT_DISK_SIZE=500GiB

REMOTE_ACCESS_LOCATION=true

ENABLE_CEPH=true
CEPH_DISK_SIZE=500GiB

export RISK
export ENABLE_CEPH

DEBIAN_FRONTEND=noninteractive sudo apt-get update
DEBIAN_FRONTEND=noninteractive sudo apt-get install retry -y

# enable ipv4 forwarding in the host...
sudo sysctl -w net.ipv4.ip_forward=1

# not sure if all of this is necessary, but...
sudo ufw route allow in on osbr0
sudo ufw route allow in on osbr0
sudo ufw route allow out on osbr0

lxc delete openstack --force || :
lxc network delete osbr0 || :

# dns.mode to assign to the same bridge. We could have two bridges instead.
lxc network create osbr0 ipv6.address=none ipv4.address=192.168.20.1/24 ipv4.dhcp.ranges=192.168.20.200-192.168.20.240 ipv4.firewall=false ipv4.nat=false dns.mode=none || :

if ${REMOTE_ACCESS_LOCATION}
then
    :
else
    :
fi
    
lxc init ubuntu:24.04 openstack --vm -c limits.cpu=12 -c limits.memory=${RAM_MEMORY} -d root,size=${ROOT_DISK_SIZE} --config=user.network-config="$(cat ./data/openstack-network-config)" --config=user.user-data="$(cat ./data/openstack-user-data | envsubst '$RISK,$ENABLE_CEPH' )"
lxc config device add openstack eth0 nic nictype=bridged parent=osbr0 name=eth0 hwaddr=00:14:4F:F8:00:01
lxc config device add openstack eth1 nic nictype=bridged parent=osbr0 name=eth1 hwaddr=00:14:4F:F8:00:02

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
time retry -d 5 -t 5 lxc exec openstack -- cloud-init status --wait

echo "cloud-init finished $(date)"

lxc file push ./data/base-microstack-manifest openstack/home/ubuntu/base-microstack-manifest --uid 1000
lxc file push ./data/bootstrap_microstack.sh openstack/home/ubuntu/bootstrap_microstack.sh --uid 1000
lxc file push ./data/configure_microstack.sh openstack/home/ubuntu/configure_microstack.sh --uid 1000

lxc exec openstack -- adduser ubuntu snap_daemon
lxc exec openstack -- su --login ubuntu -c "bash -l -c \"RISK=$RISK ENABLE_CEPH=$ENABLE_CEPH bash bootstrap_microstack.sh\""
echo "microstack bootstrapped $(date)"
lxc exec openstack -- su --login ubuntu -c 'bash -l -c "bash configure_microstack.sh"'
echo "microstack configured $(date)"

lxc exec openstack -- sudo -iu ubuntu sunbeam openrc
lxc exec openstack -- sudo -iu ubuntu cat /home/ubuntu/demo-openrc
lxc exec openstack -- sudo -iu ubuntu sunbeam dashboard-url
lxc exec openstack -- sudo -iu ubuntu sunbeam openrc > admin-openrc
echo "End at $(date)"

# lxc file pull openstack/home/ubuntu/demo-openrc .
# lxc exec openstack -- su --login ubuntu
