#!/bin/bash
set -x
set -euo pipefail

. .secrets

export RAM_MEMORY=18GiB
export ROOT_DISK_SIZE=100GiB
export REMOTE_ACCESS_LOCATION=false
export ENABLE_CEPH=false
export ENABLE_VAULT=false
export ENABLE_IMAGES_SYNC=false

bash ./microstack/prepare_openstack.sh

lxc exec openstack -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install retry squid build-essential python3-dev -y"
lxc exec openstack -- sed -i 's/http_access allow localhost/http_access allow all/' /etc/squid/squid.conf
lxc exec openstack -- systemctl restart squid
lxc exec openstack -- snap install jhack
lxc exec openstack -- snap install charmcraft --classic
lxc exec openstack -- snap connect jhack:dot-local-share-juju snapd
lxc exec openstack -- sudo -iu ubuntu pipx install tox
lxc exec openstack -- sudo -iu ubuntu pipx ensurepath

lxc exec openstack -- sudo -i -u ubuntu bash -c 'echo export PROXY_IP="$(ip -4 -j route get 2.2.2.2 | jq -r ".[] | .prefsrc")" >> ~/.bashrc'
lxc exec openstack -- sudo -i -u ubuntu bash -c "echo export GITHUB_REPOSITORY=${GITHUB_REPOSITORY} >> ~/.bashrc"
lxc exec openstack -- sudo -i -u ubuntu bash -c "echo export GITHUB_TOKEN=${GITHUB_TOKEN} >> ~/.bashrc"
lxc exec openstack -- sudo -i -u ubuntu bash -c "echo '. <( cat ~/demo-openrc )' >> ~/.bashrc"
lxc exec openstack -- sudo -i -u ubuntu bash -c "echo export REGION=RegionOne >> ~/.bashrc"


# # lxd for the integration tests
# There is already a controllers called localstack-localstack with
# no models created by sunbeam :)
lxc exec openstack -- sudo -iu ubuntu juju switch localhost-localhost

# get into the machine with:
# lxc exec openstack -- su --login ubuntu
