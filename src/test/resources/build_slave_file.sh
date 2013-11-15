#!/bin/bash

# don't call this script directly, it is a helper
# args are path/to/slaves file-with-external-names

rm -f $1
NODES=`cat $2`

for node in $NODES; do
    echo `ssh root@$node "hostname -s"` >> $1
done
