# dpdk-rhel-perf-tools
Tools used for automation testing of DPDK on RHEL products

start-vswitch.sh
- Configure and start a vsiwtch, used on a KVM host.  Note that when using a DPDK switch, this script requires that cpu-partitioning tuned profile is already installed and "isolated_cores" has been defined.

virt-remove-vhostuser.sh
- Remove all virtio-net interfaces which use vhostuser as a back-end.

virt-add-vhostuser.sh
- Add one virtio-net interface to the VM, using vhostuser as the back-end.  This requires using openvswitch or testpmd as the vswitch on the host

virt-pin.sh
- Pin the vcpus and memory to a specific NUMA node.  Note that this also requires the use of cpu-partitioning tuned profile.

virt-boot-vms.sh
- Boot 1 or more VMs and return the hostname for each.  This requires a specific configuration of the VM console, documented within this script.

virt-shutdown-all-vms.sh
- Power off all active VMs

These scripts are typically used in the following way:

On a KVM host:
start-vswitch.sh --devices=<two PCI devices> --switch=openvswitch  --dataplane=dpdk  --topology=pv,vp #bring up ovs with DPDK
virt-remove-vhostuser.sh vm1 #remove any old virtio-net interfaces using vhostuser
virt-add-vhostuser.sh vm1 #add first vhostuser
virt-add-vhostuser.sh vm1 #add second vhostuser
virt-pin.sh vm1 --host-node=1 #use same NUMA node as the two PCI devices used in start-vswitch.sh
virt-boot-vms.sh vm1
  
Once the VM is up, start-vswitch.sh can be used to start testpmd in the VM:
start-vswitch.sh --devices=<last-two-virtio-net-devices> --dataplane=dpdk --topology=pp --switch=testpmd


