openstack configuration
=======================

# Use the demo project for the bastion, and the demo-router router for everything we create, so it is easier to have connectivity.
. <( ssh ubuntu@192.168.20.2 cat demo-openrc )

openstack keypair create --public-key ~/.ssh/id_ed25519.pub javi-key

# default security group in demo allows ssh and icmp
openstack server create --flavor m1.tiny --image ubuntu --nic net-id=demo-network --security-group default --key-name javi-key bastion
# create a floating ip so we can connect to it
openstack floating ip create external-network
BASTION_FLOATING_IP=$(openstack floating ip list --format json | jq -r 'if (length == 1) then .[0]."Floating IP Address" else error("Array must contain exactly one element") end') && echo floating ip: $BASTION_FLOATING_IP
openstack server add floating ip bastion $BASTION_FLOATING_IP

openstack server list
sleep 30


ssh ubuntu@192.168.20.2 cat demo-openrc | ssh ubuntu@${BASTION_FLOATING_IP} 'cat > demo-openrc'
ssh ubuntu@192.168.20.2 sunbeam openrc | ssh ubuntu@${BASTION_FLOATING_IP} 'cat > openrc'
scp register_controller.expect ubuntu@${BASTION_FLOATING_IP}:
ssh "ubuntu@${BASTION_FLOATING_IP}"


---
sudo snap install jq
sudo snap install yq
sudo snap install juju
sudo snap install terraform --classic
sudo apt-get update
sudo apt-get install python3-openstackclient expect -y
ssh-keygen -f /home/ubuntu/.ssh/id_rsa -N ''

. openrc
openstack flavor create juju-controller --public --ram 2048 --disk 20 --vcpus 1
openstack flavor create m1.builder --public --ram 1024 --disk 20 --vcpus 2 --public
openstack flavor create m1.microk8s --public --ram 4096 --disk 20 --vcpus 2 --public

# The router to attach to the external network and to connect everything
# openstack router create main_router --enable-snat --external-gateway external-network

# if someone wants to connect to here...
# openstack subnet set --dns-nameserver 8.8.8.8 --dhcp external-subnet

# Domain
openstack domain create --description "Juju domain" juju

# Controller
openstack project create --domain juju --description "controller project" controller_project
openstack network create --project-domain juju --project controller_project controller_network
openstack subnet create controller_subnet --project-domain juju --project controller_project --network controller_network --subnet-range 192.168.100.0/24
openstack subnet set --dns-nameserver 8.8.8.8 controller_subnet
openstack router add subnet demo-router controller_subnet

openstack user create --domain juju --password admin controller_admin
openstack role add --user-domain juju --user controller_admin --project controller_project manager
openstack role add --user-domain juju --user controller_admin --project controller_project load-balancer_member

cat openrc > controllerrc
cat << EOF >> controllerrc
export OS_USERNAME=controller_admin
export OS_PASSWORD=admin
export OS_USER_DOMAIN_NAME=juju
export OS_PROJECT_DOMAIN_NAME=juju
export OS_PROJECT_NAME=controller_project
EOF

# model machine
openstack project create --domain juju --description "machine project" machine_project
openstack network create --project-domain juju --project machine_project machine_network
openstack subnet create machine_subnet --project-domain juju --project machine_project --network machine_network --subnet-range 192.168.101.0/24
openstack subnet set --dns-nameserver 8.8.8.8 machine_subnet
openstack router add subnet demo-router machine_subnet

openstack user create --domain juju --password admin machine_admin
openstack role add --user-domain juju --user machine_admin --project machine_project manager
openstack role add --user-domain juju --user machine_admin --project machine_project load-balancer_member

cat openrc > machinerc
cat << EOF >> machinerc
export OS_USERNAME=machine_admin
export OS_PASSWORD=admin
export OS_USER_DOMAIN_NAME=juju
export OS_PROJECT_DOMAIN_NAME=juju
export OS_PROJECT_NAME=machine_project
EOF

# model k8s
openstack project create --domain juju --description "k8s project" k8s_project
openstack network create --project-domain juju --project k8s_project k8s_network
openstack subnet create k8s_subnet --project-domain juju --project k8s_project --network k8s_network --subnet-range 192.168.102.0/24
openstack subnet set --dns-nameserver 8.8.8.8 k8s_subnet
openstack router add subnet demo-router k8s_subnet

openstack user create --domain juju --password admin k8s_admin
openstack role add --user-domain juju --user k8s_admin --project k8s_project manager
openstack role add --user-domain juju --user k8s_admin --project k8s_project load-balancer_member


cat openrc > k8src
cat << EOF >> k8src
export OS_USERNAME=k8s_admin
export OS_PASSWORD=admin
export OS_USER_DOMAIN_NAME=juju
export OS_PROJECT_DOMAIN_NAME=juju
export OS_PROJECT_NAME=k8s_project
EOF

CONTROLLER configuration
========================

. controllerrc
mkdir juju_data_controller
export JUJU_DATA=./juju_data_controller


# simplestreams
# images-sync should be enabled for this
export IMAGE=$(openstack image list --format json | jq -r '.[] | select( .Name | test("^auto-sync/.*noble") ).ID') && echo IMAGE: $IMAGE

mkdir ./simplestreams
juju metadata generate-image -d ./simplestreams -i ${IMAGE} --base=ubuntu@24.04 -r RegionOne -u ${OS_AUTH_URL}

# credentials
tee openstack-cloud.yaml > /dev/null << EOL
clouds:
  openstack:
    type: openstack
    auth-types: [userpass]
    regions:
      RegionOne:
        endpoint: '${OS_AUTH_URL}'
EOL
juju add-cloud --client openstack openstack-cloud.yaml

tee controller-credentials.yaml > /dev/null << EOL
credentials:
  openstack:
    default-region: RegionOne
    admin:
      auth-type: userpass
      username: $OS_USERNAME
      password: $OS_PASSWORD
      tenant-name: $OS_PROJECT_NAME
      project-domain-name: $OS_USER_DOMAIN_NAME
      user-domain-name: $OS_USER_DOMAIN_NAME
      version: "$OS_AUTH_VERSION"
EOL
juju add-credential --client openstack -f controller-credentials.yaml
juju default-credential openstack admin
juju default-region openstack RegionOne

juju bootstrap --debug \
    --config use-floating-ip=true \
    --config use-default-secgroup=true \
    --bootstrap-base=ubuntu@24.04 \
    --bootstrap-constraints instance-type=juju-controller \
    --bootstrap-constraints allocate-public-ip=true \
    --model-default network=controller_network \
    --metadata-source $HOME/simplestreams/ \
    --config external-network=external-network \
    openstack openstack

# no comment...
yes admin | juju change-user-password


New machine user and model
==========================
export JUJU_DATA=./juju_data_controller

# no comment
USER=machine-admin
USER_TOKEN=$( juju add-user ${USER} | grep -Po "juju register \K.*" )

. machinerc
tee machine-credentials.yaml > /dev/null << EOL
credentials:
  openstack:
    default-region: RegionOne
    machine:
      auth-type: userpass
      username: $OS_USERNAME
      password: $OS_PASSWORD
      tenant-name: $OS_PROJECT_NAME
      project-domain-name: $OS_USER_DOMAIN_NAME
      user-domain-name: $OS_USER_DOMAIN_NAME
      version: "$OS_AUTH_VERSION"
EOL
juju add-credential openstack --client --controller openstack -f machine-credentials.yaml
juju add-model --credential machine --owner machine-admin --config network=machine_network machine-model openstack

mkdir juju_data_machine
export JUJU_DATA=./juju_data_machine

./register_controller.expect $USER_TOKEN admin

# because we are not inside the network, we may need this if we need to access the machine.
juju set-model-constraints allocate-public-ip=true


New k8s user and model
======================
export JUJU_DATA=./juju_data_controller

# no comment
USER=k8s-admin
USER_TOKEN=$( juju add-user ${USER} | grep -Po "juju register \K.*" )

. k8src
tee k8s-credentials.yaml > /dev/null << EOL
credentials:
  openstack:
    default-region: RegionOne
    k8s:
      auth-type: userpass
      username: $OS_USERNAME
      password: $OS_PASSWORD
      tenant-name: $OS_PROJECT_NAME
      project-domain-name: $OS_USER_DOMAIN_NAME
      user-domain-name: $OS_USER_DOMAIN_NAME
      version: "$OS_AUTH_VERSION"
EOL
juju add-credential openstack --client --controller openstack -f k8s-credentials.yaml
juju add-model --credential k8s --owner k8s-admin --config network=k8s_network k8s-model openstack


mkdir juju_data_k8s
export JUJU_DATA=./juju_data_k8s

./register_controller.expect $USER_TOKEN admin

# because we are not inside the network, we may need this if we need to access the machine.
juju set-model-constraints allocate-public-ip=true

# deploy microk8s!
# also we could try ceph to see if it works..
juju deploy microk8s --constraints 'mem=4G root-disk=20G' --channel 1.28/stable  --config hostpath_storage=true
juju wait-for application microk8s
juju expose microk8s
juju wait-for application microk8s
# for the lb/ingress
juju exec --unit microk8s/0 "open-port 80"


New microk8s cloud in the same controller
=========================================
export JUJU_DATA=./juju_data_k8s
# sadly, the kubeconfig reports the internal ip.
K8S_EXTERNAL_IP=$(juju status --format json  | jq -r '.machines."0"."ip-addresses"[0]') && echo K8S_EXTERNAL_IP $K8S_EXTERNAL_IP
K8S_INTERNAL_IP=$(juju status --format json  | jq -r '.machines."0"."ip-addresses"[1]') && echo K8S_INTERNAL_IP $K8S_INTERNAL_IP

# use this instead if you want to access the k8s cloud from outside
# kubeconfig="$(juju exec --unit microk8s/leader -- microk8s config | yq e ".clusters[0].cluster.server = \"https://${K8S_EXTERNAL_IP}:16443\"")"
kubeconfig="$(juju exec --unit microk8s/leader -- microk8s config)"

export JUJU_DATA=./juju_data_controller
controller="$(juju controller-config controller-name)"
echo "$kubeconfig" | juju add-k8s microk8s-cloud --client --controller "$controller"

# give another model to the k8s-admin user :)
juju add-model --credential microk8s-cloud --owner k8s-admin microk8s-model microk8s-cloud

What about now?
===============
# NICE, there are two users with models. let's play a bit

export JUJU_DATA=./juju_data_machine

# . <( ssh ubuntu@192.168.20.2 cat demo-openrc)
# create the runners in the demo project
. demo-openrc

BASE_IMAGE=jammy
WEBHOOK_SECRET=supersecret
# BUILD_NETWORK=external-network
BUILD_NETWORK=demo-network

juju deploy github-runner-image-builder --channel=edge --revision=45 \
--config base-image=$BASE_IMAGE \
--config openstack-auth-url=$OS_AUTH_URL \
--config openstack-password=$OS_PASSWORD \
--config openstack-project-domain-name=$OS_PROJECT_DOMAIN_NAME \
--config openstack-project-name=$OS_PROJECT_NAME \
--config openstack-user-domain-name=$OS_USER_DOMAIN_NAME \
--config openstack-user-name=$OS_USERNAME \
--config experimental-external-build=true \
--config experimental-external-build-flavor=m1.builder \
--config experimental-external-build-network=${BUILD_NETWORK} \
--config app-channel="edge" \
--constraints "instance-type=m1.builder"

# export REPOSITORY=...
# export TOKEN=...
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

juju deploy github-runner small --channel=latest/stable --config path=$REPOSITORY --config virtual-machines=1 --config openstack-clouds-yaml=@myclouds.yaml --config openstack-flavor=m1.small --config openstack-network=external-network --config token=$TOKEN  --config labels="small,stg-reactive"  --config reconcile-interval=30 --config virtual-machines=2

# mongodb in the same model for now
juju deploy mongodb --channel 6/edge --revision 188 

juju expose mongodb
juju offer mongodb:database
juju grant k8s-admin consume machine-admin/machine-model.mongodb

juju integrate small mongodb
# sadly, sometimes this fails, and it is necessary to remove the relation and recreate it again
juju integrate small github-runner-image-builder


export JUJU_DATA=./juju_data_k8s
juju switch microk8s-model
# this is sh.t
juju deploy metallb --config iprange="${K8S_INTERNAL_IP}-${K8S_INTERNAL_IP}" --trust

export WEBHOOK_SECRET=supersecret
cat <<EOF > routing_table.yaml 
- small: [stg-reactive]
EOF

juju deploy github-runner-webhook-router --channel latest/edge --config flavours=@routing_table.yaml --config default-flavour=small --config webhook-secret=$WEBHOOK_SECRET
juju deploy traefik-k8s --trust

juju consume machine-admin/machine-model.mongodb
juju integrate github-runner-webhook-router mongodb
juju integrate github-runner-webhook-router traefik-k8s

# if accessing from outside, use floating ip.
juju run traefik-k8s/0 show-proxied-endpoints --format json | sed "s/${K8S_INTERNAL_IP}/${K8S_EXTERNAL_IP}/g"



