#!/bin/bash

ip link set ens1f0np0 mtu 9216
ip link set ens1f1np1 mtu 9216
ovs-vsctl set Interface vhost-user-1-n2 mtu_request=9216
ovs-vsctl set Interface vhost-user-0-n2 mtu_request=9216
ovs-vsctl set Interface dpdk-0 mtu_request=9216
ovs-vsctl set Interface dpdk-1 mtu_request=9216
ovs-vsctl set Interface phy-br-0 mtu_request=9216
ovs-vsctl set Interface phy-br-1 mtu_request=9216

