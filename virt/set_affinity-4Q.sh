#!/bin/bash

ovs-vsctl set Interface dpdk-0 options:"n_rxq=4" other_config:pmd-rxq-affinity="0:2,1:4,2:6,3:8"
ovs-vsctl set Interface dpdk-0 options:"n_rxq=4" other_config:pmd-rxq-affinity="0:10,1:12,2:14,3:16"

ovs-vsctl set Interface vhost-user-0-n0 options:"n_rxq=4" other_config:pmd-rxq-affinity="0:50,1:52,2:54,3:56"
ovs-vsctl set Interface vhost-user-1-n0 options:"n_rxq=4" other_config:pmd-rxq-affinity="0:58,1:60,2:62,3:64"


