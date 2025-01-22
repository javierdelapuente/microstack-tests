#!/bin/bash
set -euo pipefail
set -x

ENABLE_VAULT=false

echo enable_vault: ${ENABLE_VAULT}

sunbeam configure -m microstack-manifest --openrc demo-openrc

. <(sunbeam openrc)
# This is to be able to attach directly instances to the external network.
openstack network set --share external-network
openstack subnet set --dns-nameserver 8.8.8.8 --dhcp external-subnet
#openstack flavor create --public m1.builder --ram 1024 --disk 20 --vcpus 2 --public

# VAULT
if ${ENABLE_VAULT}
then
    sunbeam enable vault
    sunbeam vault init 1 1 --format json > ~/vaultcreds.json
    # TODO this should be done on reboot again
    jq -r '.unseal_keys_hex.[0]' ~/vaultcreds.json | sunbeam vault unseal -
    jq -r '.root_token' ~/vaultcreds.json | sunbeam vault authorize-charm -

    juju switch openstack
    juju deploy traefik-k8s traefik-vault --channel latest/beta --trust
    juju deploy self-signed-certificates certificates-vault --channel latest/beta
    juju integrate certificates-vault:certificates traefik-vault:certificates
    juju integrate vault:send-ca-cert traefik-vault:receive-ca-cert
    juju integrate vault:ingress traefik-vault:ingress
    juju wait-for application certificates-vault
    juju wait-for application traefik-vault
    juju wait-for application vault
    SECRET_ID_CA_CERTIFICATE_VAULT=$(juju secrets --format=json | jq -r 'to_entries | .[] | select(.value.owner == "certificates-vault").key')
    juju show-secret ${SECRET_ID_CA_CERTIFICATE_VAULT} --reveal --format json | jq -r 'to_entries.[].value.content.Data."ca-certificate"' > ~/vault_ca.pem

    # to get vault url:
    # juju run traefik-vault/0 show-proxied-endpoints --format json | jq -r '.\"traefik-vault/0\".results.\"proxied-endpoints\"' | jq -r '.\"vault\".url'"
    # to get vault token:
    # jq -r '.root_token' ~/vaultcreds.json
fi

sunbeam enable images-sync

# For Telemetrh: ceph is required to install telemetry
# sunbeam enable telemetry

# Octavia
# sunbeam enable loadbalancer
