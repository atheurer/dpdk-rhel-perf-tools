#!/bin/bash
ovs-vsctl set Interface dpdk-0 options:"n_rxq=2" other_config:pmd-rxq-affinity="0:2,1:4"
ovs-vsctl set Interface dpdk-1 options:"n_rxq=2" other_config:pmd-rxq-affinity="0:6,1:8"

ovs-vsctl set Interface vhost-user-0-n0 options:"n_rxq=2" other_config:pmd-rxq-affinity="0:50,1:52"
ovs-vsctl set Interface vhost-user-1-n0 options:"n_rxq=2" other_config:pmd-rxq-affinity="0:54,1:56"
