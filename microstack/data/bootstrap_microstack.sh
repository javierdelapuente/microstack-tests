#!/bin/bash
set -euo pipefail
set -x

echo RISK $RISK
echo ENABLE_CEPH $ENABLE_CEPH

sunbeam prepare-node-script --bootstrap | bash -x

cd "${HOME}"
export EXTERNAL_IFNAME="$(ip --json a | jq '.[] | select(.address == "00:14:4f:f8:00:02")' | jq -r '.ifname')"
export LOCAL_IPADDR=$(ip -4 -j route get 2.2.2.2 | jq -r '.[] | .prefsrc') && echo LOCAL_IPADDR $LOCAL_IPADDR
export LOCAL_MANAGEMENT_CIDR="${LOCAL_IPADDR%.*}.0/24" && echo MANAGEMENT_CIDR $LOCAL_MANAGEMENT_CIDR
cat ~/base-microstack-manifest | envsubst '$EXTERNAL_IFNAME,$LOCAL_IPADDR,$LOCAL_MANAGEMENT_CIDR' > ~/base-microstack-manifest.temp1
cp /snap/openstack/current/etc/manifests/${RISK}.yml .
yq eval-all '. as $item ireduce ({}; . * $item)' ./${RISK}.yml ./base-microstack-manifest.temp1 > ~/base-microstack-manifest.temp2

# storage requires ceph
if ${ENABLE_CEPH}
then
    cat ~/base-microstack-manifest.temp2 > ~/microstack-manifest
    ROLES="control,compute,storage"    
else
    cat ~/base-microstack-manifest.temp2 | yq 'del(.core.config.microceph_config)' > ~/microstack-manifest
    ROLES="control,compute"
fi

sunbeam cluster bootstrap --role ${ROLES} -m /home/ubuntu/microstack-manifest || sunbeam cluster bootstrap --role ${ROLES} -m /home/ubuntu/microstack-manifest
