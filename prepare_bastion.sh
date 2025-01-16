#!/bin/bash

set -x
set -euo pipefail

RAM_MEMORY=14GiB
PROXY_IP=192.168.20.1
ROOT_DISK_SIZE=100GiB
export PROXY_IP

. .secrets


DEBIAN_FRONTEND=noninteractive sudo apt-get update
DEBIAN_FRONTEND=noninteractive sudo apt-get install retry -y

lxc delete bastion --force || :

# not sure if all of this is necessary, but...
# sudo ufw route allow in on  basbr0
# sudo ufw route allow in on basbr0
# sudo ufw route allow out on basbr0


lxc init ubuntu:22.04 bastion --vm -c limits.cpu=6 -c limits.memory=${RAM_MEMORY} -d root,size=${ROOT_DISK_SIZE}  --config=user.user-data="$(cat ./bastion-user-data  | envsubst '$TOKEN,$PROXY_IP,$REPOSITORY')"
# it may be necessary to adjust the mtu in the bridge.
lxc network set lxdbr0 bridge.mtu=1400
# lxc config device add bastion eth0 nic nictype=bridged parent=basbr0 name=eth0

lxc start bastion

retry -d 5 -t 5 lxc exec bastion  -- true
lxc exec bastion -- cloud-init status --wait
# Add flavor m1.builder
. <( ssh ubuntu@192.168.20.2 sunbeam openrc )
openstack flavor show m1.builder || openstack flavor create --public m1.builder --ram 1024 --disk 20 --vcpus 2 --public
# prepare to attach things to the external network
openstack network set --share external-network
openstack subnet set --dns-nameserver 8.8.8.8 --dhcp external-subnet || : # could be already created

# put openstack credentials in .bashrc file
ssh ubuntu@192.168.20.2 cat demo-openrc | lxc exec bastion --user 1000 --group 1000 -- tee -a /home/ubuntu/.bashrc

## it is necessary to expose the url... You need to configure the repo webhook, and redirect to the ingress some way... one of the steps, in the host to the vm, could be to use a proxy, that is basically iptables..
## IN THE HOST
IPHOST=$(ip -4 -j route get 2.2.2.2 | jq -r '.[] | .prefsrc')
IPVM=$(lxc exec bastion -- ip -4 -j route get 2.2.2.2 | jq -r '.[] | .prefsrc')
lxc config device override bastion eth0 ipv4.address=$IPVM
lxc config device add bastion proxyingress proxy nat=true listen=tcp:${IPHOST}:8080 connect=tcp:${IPVM}:80 


# lxc config device add bastion github disk readonly=false source=/home/jpuente/github path=/home/ubuntu/github
# lxc config device add bastion terraform disk readonly=false source="$(realpath ./terraform)" path=/home/ubuntu/terraform
# lxc file push demo-openrc bastion/home/ubuntu/demo-openrc
# lxc file push admin-openrc bastion/home/ubuntu/admin-openrc

# lxc exec bastion -- su --login ubuntu
