#!/bin/bash

# run a given command on all nodes
# arg is list to nodes to run on, followed by command

NODES=`cat $1`
shift
for node in $NODES; do
  ssh $node $*
done
