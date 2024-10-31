#!/bin/bash
#
# Copyright 2023 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
set -ex


CENTOS_9_STREAM_URL="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
CENTOS9_FILEPATH=/tmp/centos9.qcow2

if ! openstack image show centos9; then
    if [ ! -f ${CENTOS9_FILEPATH} ]; then
        curl -L -# $CENTOS_9_STREAM_URL > ${CENTOS9_FILEPATH}
    fi
    openstack image show centos9 || \
        openstack image create --file ${CENTOS9_FILEPATH} --container-format bare --disk-format qcow2 centos9
fi

# Create flavor
openstack flavor show nvidia || \
    openstack flavor create --ram 20480 --vcpus 20 --disk 11 --ephemeral 2 nvidia \
      --property "pci_passthrough:alias"="nvidia:1" \
      --property "hw:pci_numa_affinity_policy=preferred" \
      --property "hw:hide_hypervisor_id"=true

# Create networks
openstack network show private || openstack network create private --share
openstack subnet show priv_sub || openstack subnet create priv_sub --subnet-range 192.168.0.0/24 --network private
openstack network show public || openstack network create public --external --provider-network-type flat --provider-physical-network datacentre
openstack subnet show public_subnet || \
    openstack subnet create public_subnet --subnet-range 192.168.122.0/24 --allocation-pool start=192.168.122.171,end=192.168.122.250 --gateway 192.168.122.1 --dhcp --network public
openstack router show priv_router || {
    openstack router create priv_router
    openstack router add subnet priv_router priv_sub
    openstack router set priv_router --external-gateway public
}

# Create security group and icmp/ssh rules
openstack security group show basic || {
    openstack security group create basic
    openstack security group rule create basic --protocol icmp --ingress --icmp-type -1
    openstack security group rule create basic --protocol tcp --ingress --dst-port 22

    openstack security group rule create basic --protocol tcp --remote-ip 0.0.0.0/0
}

# List External compute resources
openstack compute service list
openstack network agent list

# Create an instance
NAME=nvidia
openstack server show ${NAME} || {
    openstack keypair show ${NAME} || {
        openstack keypair create ${NAME} > ${NAME}.pem
        # openstack keypair create --public-key ~/.ssh/id_rsa.pub ${NAME}
        chmod 600 ${NAME}.pem
    }
    openstack server create --flavor nvidia --image centos9 --key-name ${NAME} --nic net-id=private ${NAME} --security-group basic --wait
    fip=$(openstack floating ip create public -f value -c floating_ip_address)
    openstack server add floating ip ${NAME} ${fip}
}
openstack server list --long

echo "Pinging $fip with 120 seconds timeout to confirm it comes up"
timeout 120 bash -c "while true; do if ping -c1 -i1 $fip &>/dev/null; then echo 'Machine is up and running up'; break; fi; done"

echo "Changing the default DNS nameserver"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./${NAME}.pem cloud-user@${fip} 'echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf'

echo "Access VM with: oc rsh openstackclient ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./${NAME}.pem cloud-user@${fip}"
