#!/bin/bash
set -euo pipefail
set -x

echo RISK $RISK
echo ENABLE_CEPH $ENABLE_CEPH

cd "${HOME}"
export EXTERNAL_IFNAME="$(ip --json a | jq '.[] | select(.address == "00:14:4f:f8:00:02")' | jq -r '.ifname')"
cat ~/microstack-manifest | envsubst '$EXTERNAL_IFNAME' > openstack-manifest-deployment
cp /snap/openstack/current/etc/manifests/${RISK}.yml .
yq eval-all '. as $item ireduce ({}; . * $item)' ./${RISK}.yml ./openstack-manifest-deployment > combined-openstack-manifest

# storage requires ceph
if ${ENABLE_CEPH}
then
    cat combined-openstack-manifest > openstack-manifest
else
    cat combined-openstack-manifest | yq 'del(.core.config.microceph_config)' > openstack-manifest
fi
