# What is in this repo

My experimentation for microstack, juju and github-runners


# 1. How to run integration tests for github-runner-operator


Fork `https://github.com/canonical/github-runner-operator` into your GitHub account.

Create a file named `.secrets` with the following information (it will be sourced):
```
export GITHUB_REPOSITORY=youraccount/github-runner-operator
export GITHUB_TOKEN=ghp_yourgithubtoken
```

See https://charmhub.io/github-runner/docs/how-to-change-token for more information about tokens.

Run the following script:
```
./prepare_github_runner_tests.sh
```

It should take between 20-40 minutes, depending on your machine/network.

You should have now a new lxd instance, you can log in with `lxc exec openstack -- su --login ubuntu`

## Check that everything is ok

```
lxc exec openstack -- su --login ubuntu
openstack server list
openstack image list
openstack network list

# maybe create and image...

# check the proxy
curl -x "$PROXY_IP:3128" "https://ip.oxylabs.io/"

# check that there is an env variable for the github token and repo:
echo $GITHUB_REPOSITORY
echo $GITHUB_TOKEN

```

## Run the tests:

Mount from your host the repo to run tests, something like:
```
lxc config device add openstack github disk readonly=false source=/home/jpuente/github path=/home/ubuntu/github
```

Comment the line `basepython = python3.10` in `tox.init`, as the openstack is runnin in `noble`.

Go there and run them!! like:

```
lxc exec openstack -- su --login ubuntu

cd /home/ubuntu/github/javierdelapuente/github-runner-operator
tox -e integration-juju3.6 -- -x  --log-cli-level=INFO  --log-format="%(asctime)s %(levelname)s %(message)s" --charm-file=github-runner_ubuntu-22.04-amd64.charm --path=$GITHUB_REPOSITORY --token=$GITHUB_TOKEN --model testing --keep-models --openstack-test-image image-builder-jammy-x64 --openstack-flavor-name-amd64 "m1.builder" --openstack-network-name-amd64 external-network --openstack-auth-url-amd64 "${OS_AUTH_URL}" --openstack-password-amd64 "${OS_PASSWORD}" --openstack-project-domain-name-amd64 "${OS_PROJECT_DOMAIN_NAME}" --openstack-project-name-amd64 "${OS_PROJECT_NAME}" --openstack-user-domain-name-amd64 "${OS_USER_DOMAIN_NAME}" --openstack-username-amd64 "${OS_USERNAME}" --openstack-region-name-amd64 "RegionOne" --https-proxy http://${PROXY_IP}:3128 --http-proxy http://${PROXY_IP}:3128 --no-proxy http://${PROXY_IP}:3128 --openstack-https-proxy http://${PROXY_IP}:3128 --openstack-http-proxy http://${PROXY_IP}:3128  --openstack-no-proxy 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16  -m openstack -k test_charm_metrics_success

# ....
juju switch testing
juju debug-log
jhack nuke
```


## Tests for the library

### Create a base image with image builder

An image needed for [test_runner_manager_openstack](https://github.com/canonical/github-runner-operator/blob/main/tests/integration/test_runner_manager_openstack.py) tests.

```
lxc exec openstack -- su --login ubuntu
```

```
juju add-model testing localhost
# create a base image
BASE_IMAGE=jammy
juju deploy github-runner-image-builder --channel=edge --revision=57 \
--config base-image=$BASE_IMAGE \
--config openstack-auth-url=$OS_AUTH_URL \
--config openstack-password=$OS_PASSWORD \
--config openstack-project-domain-name=$OS_PROJECT_DOMAIN_NAME \
--config openstack-project-name=$OS_PROJECT_NAME \
--config openstack-user-domain-name=$OS_USER_DOMAIN_NAME \
--config openstack-user-name=$OS_USERNAME \
--config build-flavor=m1.builder \
--config build-network=external-network

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

juju deploy github-runner --channel=latest/edge --config path=$GITHUB_REPOSITORY --config virtual-machines=1 --config openstack-clouds-yaml=@myclouds.yaml --config openstack-flavor=m1.builder --config openstack-network=external-network --config token=$GITHUB_TOKEN
juju integrate github-runner github-runner-image-builder


juju wait-for application github-runner
```

After a while, there will be two `github-runner-image-builder-jammy-x64` images. The one that is the snapshot should be deleted. 
```
for image_id in $(openstack image list --format json | jq -r '.[] | select( .Name == "github-runner-image-builder-jammy-x64" ).ID')
do
	echo $image_id
	openstack image show $image_id --format json
	image_type=$(openstack image show $image_id --format json | jq -r '.properties.image_type' )
	echo $image_type
	if [[ $image_type = "snapshot" ]]
	then
	    openstack image delete $image_id
	fi
done

juju remove-application github-runner --no-prompt
juju remove-application github-runner-image-builder --no-prompt
juju destroy-model testing --no-prompt
```



### Run the tests

```
tox -e integration-juju3.6 -- -x --log-cli-level=INFO --log-format="%(asctime)s %(levelname)s %(message)s" --charm-file=github-runner_ubuntu-22.04-amd64.charm --path=$GITHUB_REPOSITORY --token=$GITHUB_TOKEN --model testing --keep-models --openstack-test-image github-runner-image-builder-jammy-x64 --openstack-flavor-name-amd64 "m1.small" --openstack-network-name-amd64 external-network --openstack-auth-url-amd64 "${OS_AUTH_URL}" --openstack-password-amd64 "${OS_PASSWORD}" --openstack-project-domain-name-amd64 "${OS_PROJECT_DOMAIN_NAME}" --openstack-project-name-amd64 "${OS_PROJECT_NAME}" --openstack-user-domain-name-amd64 "${OS_USER_DOMAIN_NAME}" --openstack-username-amd64 "${OS_USERNAME}" --openstack-region-name-amd64 "RegionOne"  --https-proxy http://${PROXY_IP}:3128 --http-proxy http://${PROXY_IP}:3128 --no-proxy 127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.internal --openstack-https-proxy http://${PROXY_IP}:3128 --openstack-http-proxy http://${PROXY_IP}:3128 --openstack-no-proxy 127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.internal -m openstack -k test_runner_manager_openstack
```

```
tox -e integration-juju3.6 -- -x --log-cli-level=INFO --log-format="%(asctime)s %(levelname)s %(message)s" --charm-file=github-runner_ubuntu-22.04-amd64.charm --path=$GITHUB_REPOSITORY --token=$GITHUB_TOKEN --model testing --keep-models --openstack-test-image github-runner-image-builder-jammy-x64 --openstack-flavor-name-amd64 "m1.builder" --openstack-network-name-amd64 external-network --openstack-auth-url-amd64 "${OS_AUTH_URL}" --openstack-password-amd64 "${OS_PASSWORD}" --openstack-project-domain-name-amd64 "${OS_PROJECT_DOMAIN_NAME}" --openstack-project-name-amd64 "${OS_PROJECT_NAME}" --openstack-user-domain-name-amd64 "${OS_USER_DOMAIN_NAME}" --openstack-username-amd64 "${OS_USERNAME}" --openstack-region-name-amd64 "RegionOne"  --https-proxy http://${PROXY_IP}:3128 --http-proxy http://${PROXY_IP}:3128 --no-proxy 127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.internal --openstack-https-proxy http://${PROXY_IP}:3128 --openstack-http-proxy http://${PROXY_IP}:3128 --openstack-no-proxy 127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.internal -m openstack -k test_debug_ssh
```
