#!/bin/bash

/usr/bin/dpdk-testpmd  --lcores 0@0,1@65,2@193,3@66,4@194 --file-prefix server-1 --socket-mem 0,0,1024,0,0,0,0,0 --huge-dir /dev/hugepages  --allow 0000:21:00.0 --allow 0000:21:00.1 -v -- --nb-ports 2 --nb-cores 4 --auto-start --rxq 2 --txq 2 --rxd 4096 --txd 4096 --max-pkt-len=9216 --mbuf-size=16384 -i
