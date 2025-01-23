lxc exec bastion -- su --login ubuntu


## DEPLOY COS. TODO REMOVE NGINX AND USE TRAEFIK OR IT WILL NOT WORK :(
juju add-model cos mymicrok8s

curl -L https://raw.githubusercontent.com/canonical/cos-lite-bundle/main/overlays/offers-overlay.yaml -O
curl -L https://raw.githubusercontent.com/canonical/cos-lite-bundle/main/overlays/storage-small-overlay.yaml -O

juju deploy cos-lite \
  --trust \
  --overlay ./offers-overlay.yaml \
  --overlay ./storage-small-overlay.yaml
# this is bad, I should put some security... but...
juju config traefik external_hostname=gh.delapuente.es 
juju offer traefik:ingress



## DEPLOY GH RUNNERS

juju add-model gh localhost

# create a base image
BASE_IMAGE=jammy
WEBHOOK_SECRET=supersecret

# the m1.builder flavor is needed. grrr..
# openstack flavor create --public m1.builder --ram 1024 --disk 20 --vcpus 2 --public
juju deploy github-runner-image-builder lxd-github-runner-image-builder --channel=edge --revision=45 \
--config base-image=$BASE_IMAGE \
--config openstack-auth-url=$OS_AUTH_URL \
--config openstack-password=$OS_PASSWORD \
--config openstack-project-domain-name=$OS_PROJECT_DOMAIN_NAME \
--config openstack-project-name=$OS_PROJECT_NAME \
--config openstack-user-domain-name=$OS_USER_DOMAIN_NAME \
--config openstack-user-name=$OS_USERNAME \
--config experimental-external-build=true \
--config experimental-external-build-flavor=m1.builder \
--config experimental-external-build-network=external-network \
--config app-channel="edge"


export REPOSITORY=??
export TOKEN=??

# be careful not to use clouds.yaml name.
cat << EOF >myclouds.yaml
clouds:
  cloud:
    auth:
      auth_url: $OS_AUTH_URL
      project_name: $OS_PROJECT_NAME
      username: $OS_USERNAME
      password: $OS_PASSWORD
      user_domain_name: $OS_USER_DOMAIN_NAME
      project_domain_name: $OS_PROJECT_DOMAIN_NAME
    region_name: RegionOne
EOF

juju deploy github-runner lxd-small --channel=latest/stable --config path=$REPOSITORY --config virtual-machines=1 --config openstack-clouds-yaml=@myclouds.yaml --config openstack-flavor=m1.small --config openstack-network=external-network --config token=$TOKEN  --config labels="lxd-small,stg-reactive"  --config reconcile-interval=30 --config virtual-machines=1

# mongodb in the same model for now
juju deploy mongodb --channel 6/edge --revision 188 

juju expose mongodb
juju offer mongodb:database

juju integrate small mongodb
# sadly, sometimes this fails, and it is necessary to remove the relation and recreate it again
juju integrate lxd-small lxd-github-runner-image-builder


juju deploy grafana-agent --channel latest/edge

juju consume admin/cos.loki-logging
juju consume admin/cos.prometheus-receive-remote-write
juju consume admin/cos.grafana-dashboards

juju integrate grafana-agent grafana-dashboards
juju integrate grafana-agent loki-logging
juju integrate grafana-agent prometheus-receive-remote-write
juju integrate lxd-small grafana-agent


## ROUTER
juju add-model router mymicrok8s

cat <<EOF > routing_table.yaml 
- lxd-small: [stg-reactive]
EOF

juju deploy github-runner-webhook-router --channel latest/edge --config flavours=@routing_table.yaml --config default-flavour=lxd-small --config webhook-secret=$WEBHOOK_SECRET
juju consume admin/gh.mongodb
juju integrate github-runner-webhook-router mongodb

# observability
juju deploy grafana-agent-k8s --channel=latest/edge --revision 80

juju integrate grafana-agent-k8s:send-remote-write admin/cos.prometheus-receive-remote-write
juju integrate grafana-agent-k8s:logging-consumer admin/cos.loki-logging
juju integrate grafana-agent-k8s:grafana-dashboards-provider admin/cos.grafana-dashboards

juju integrate github-runner-webhook-router grafana-agent-k8s:logging-provider
juju integrate github-runner-webhook-router grafana-agent-k8s:metrics-endpoint
juju integrate github-runner-webhook-router grafana-agent-k8s:grafana-dashboards-consumer


# sudo microk8s enable ingress
# juju deploy nginx-ingress-integrator --trust --channel latest/edge --revision 133 --config path-routes='/' --config service-hostname='gh.delapuente.es' --config trust=True
# juju integrate nginx-ingress-integrator github-runner-webhook-router
juju integrate github-runner-webhook-router admin/cos.traefik

# with traefik the endpoint is something like: https://gh.delapuente.es/router-github-runner-webhook-router/webhook
juju run traefik/0 show-proxied-endpoints -m cos 


