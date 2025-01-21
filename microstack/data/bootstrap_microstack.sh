#!/bin/bash
set -euo pipefail
set -x

echo ENABLE_CEPH $ENABLE_CEPH

if ${ENABLE_CEPH}
then
    ROLES="control,compute,storage"
else
    ROLES="control,compute"
fi

sunbeam cluster bootstrap --role ${ROLES} -m /home/ubuntu/openstack-manifest || sunbeam cluster bootstrap --role ${ROLES} -m /home/ubuntu/openstack-manifest

