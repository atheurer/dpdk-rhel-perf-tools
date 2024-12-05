#!/bin/bash


# using "rpm"
ovs_bin="/usr/bin"
ovs_sbin="/usr/sbin"
ovs_run="/var/run/openvswitch"
ovs_etc="/etc/openvswitch"

$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true
$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:vhost-iommu-support=true
$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="0,0,1024,0,0,0,0,0"




ovs_dpdk_interface_0_name="dpdk-0"
pci_dev0="0000:21:00.0"
ovs_dpdk_interface_0_args="options:dpdk-devargs=${pci_dev0}"

ovs_dpdk_interface_1_name="dpdk-1"
pci_dev1="0000:21:00.1"
ovs_dpdk_interface_1_args="options:dpdk-devargs=${pci_dev1}"


$ovs_bin/ovs-vsctl --if-exists del-br ovsbr0
$ovs_bin/ovs-vsctl add-br ovsbr0 -- set bridge ovsbr0 datapath_type=netdev

echo "ovs_dpdk_interface_0_name = $ovs_dpdk_interface_0_name"
echo "ovs_dpdk_interface_0_args = $ovs_dpdk_interface_0_args"
echo "ovs_dpdk_interface_1_name = $ovs_dpdk_interface_1_name"
echo "ovs_dpdk_interface_1_args = $ovs_dpdk_interface_1_args"
$ovs_bin/ovs-vsctl add-port ovsbr0 ${ovs_dpdk_interface_0_name} -- set Interface ${ovs_dpdk_interface_0_name} type=dpdk ${ovs_dpdk_interface_0_args}
$ovs_bin/ovs-vsctl add-port ovsbr0 ${ovs_dpdk_interface_1_name} -- set Interface ${ovs_dpdk_interface_1_name} type=dpdk ${ovs_dpdk_interface_1_args}
$ovs_bin/ovs-ofctl del-flows ovsbr0
$ovs_bin/ovs-ofctl del-flows ovsbr0 
$ovs_bin/ovs-ofctl add-flow ovsbr0 action=NORMAL
ovs_ports=2


$ovs_bin/ovs-vsctl set interface ${ovs_dpdk_interface_0_name} options:n_rxq=1
$ovs_bin/ovs-vsctl set interface ${ovs_dpdk_interface_1_name} options:n_rxq=1


$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_0_name} options:n_txq_desc=2048
$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_0_name} options:n_rxq_desc=2048
$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_1_name} options:n_txq_desc=2048
$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_1_name} options:n_rxq_desc=2048


$ovs_bin/ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=0x20000000000000000000000000000000200000000

$ovs_bin/ovs-appctl dpif-netdev/pmd-rxq-show

ip link set ens1f0np0 mtu 9216
ip link set ens1f1np1 mtu 9216
ovs-vsctl set Interface dpdk-0 mtu_request=9216
ovs-vsctl set Interface dpdk-1 mtu_request=9216

