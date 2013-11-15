#!/bin/bash

usage="Usage: $0 host-list-file private-key-file
 (note that the cluster master MUST be the first host in the host-list-file)"

if [ $# -lt 1 ]; then
  echo $usage
  exit 1
fi

# set to something else if tachyon installed elsewherex
REMOTE_TACHYON_HOME="/root/tachyon"

FILES_PER_HOST=10
FAILED=0

run_remote_command() {
  ssh -i $PRIV_KEY root@$HOST "$1"
}

run_on_all() {
  run_remote_command "$REMOTE_TACHYON_HOME/src/test/resources/run_on_all.sh /tmp/tachyon_test/slaves $*"
}

get_current_master() {
  echo "Trying to find a master"
  STARTTIME=$(date +%s)
  while (( 1 )); do
    sleep 1
    echo -n "."
    OK=0
    for h in $HOSTS; do
      curl -o /dev/null -s http://$h:19999/home
      if [ $? -eq 0 ]; then
        OK=1
        CURRENT_MASTER=$h
        break
      fi
    done
    if [ $OK -eq 1 ]; then
      ENDTIME=$(date +%s)
      echo -e "\nFound a master at: $CURRENT_MASTER (took $(($ENDTIME - $STARTTIME)) seconds)"
      break
    fi
  done
}

kill_current_master() {
  HOST=$CURRENT_MASTER
  run_remote_command "$REMOTE_TACHYON_HOME/bin/tachyon killAll tachyon.Master"
}

write_files() {
  HOST=$CURRENT_MASTER
  END=$(($1+$FILES_PER_HOST-1))
  echo "Writing $FILES_PER_HOST files on $CURRENT_MASTER ($1 to $END)"
  for i in `seq $1 $END`
  do
    STRINGS[i]=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 128 | head -n1`
    run_remote_command "TACHYON_SYSTEM_INSTALLATION=yes TACHYON_CONF_DIR=\"/tmp/tachyon_test/conf\" $REMOTE_TACHYON_HOME/bin/tachyon tfs copyFromLocal <(echo ${STRINGS[$i]}) /ttest/$i"
  done
}

test_files() {
  echo "Testing $(($END+1)) files"
  HOST=$CURRENT_MASTER
  for i in `seq 0 $END`
  do
    MSTR=`run_remote_command "TACHYON_SYSTEM_INSTALLATION=yes TACHYON_CONF_DIR=\"/tmp/tachyon_test/conf\" $REMOTE_TACHYON_HOME/bin/tachyon tfs copyToLocal /ttest/$i /tmp/ttest.tmp;cat /tmp/ttest.tmp"`
    for s in $MSTR;do
      STR=$s
    done
    if [ "$STR" != "${STRINGS[$i]}" ];then
      echo -e "/ttest$i:\tFAILED\n\texpecting:\t${STRINGS[$i]}\n\tgot:\t$STR"
      FAILED=1
    else
      echo -e "/ttest/$i:\tPASSED"
    fi
  done
}

HOSTS=`cat $1`
HOST=`head -n1 $1`
NUMHOSTS=`wc -l $1 | cut -d' ' -f1`
PRIV_KEY=$2

echo "Making env"
run_remote_command "mkdir -p /tmp/tachyon_test/conf"

echo "Building host list"
scp -i $PRIV_KEY $1 root@$HOST:/tmp/tachyon_test/external_hosts
run_remote_command "$REMOTE_TACHYON_HOME/src/test/resources/build_slave_file.sh /tmp/tachyon_test/slaves /tmp/tachyon_test/external_hosts"
INTERNAL_MASTER=`run_remote_command "head -n1 /tmp/tachyon_test/slaves"`

echo "Killing any running Tachyon processes"
run_on_all "$REMOTE_TACHYON_HOME/bin/tachyon killAll tachyon.Master"
run_on_all "$REMOTE_TACHYON_HOME/bin/tachyon killAll tachyon.Worker"


echo "Copying existing configs and web context"
run_on_all "\"mkdir -p /tmp/tachyon_test/conf;cp $REMOTE_TACHYON_HOME/conf/* /tmp/tachyon_test/conf/\""
run_on_all "\"mkdir -p /tmp/tachyon_test/src/main/java/tachyon/; cp -r $REMOTE_TACHYON_HOME/src/main/java/tachyon/web/  /tmp/tachyon_test/src/main/java/tachyon/\""
run_on_all "\"mkdir -p /tmp/tachyon_test/target; cp -r $REMOTE_TACHYON_HOME/target/*.jar  /tmp/tachyon_test/target/\""

echo "Generating Configs"
run_on_all "$REMOTE_TACHYON_HOME/src/test/resources/create_test_conf.sh /tmp/tachyon_test/conf/tachyon-env.sh /usr $INTERNAL_MASTER /tmp/tachyon_test"

echo "cleaning logs"
run_on_all "\"rm /tmp/tachyon_test/logs/*\""

echo "formating tachyon"
run_remote_command "TACHYON_SYSTEM_INSTALLATION=yes TACHYON_CONF_DIR=\"/tmp/tachyon_test/conf\" $REMOTE_TACHYON_HOME/bin/tachyon format"

echo "Starting Masters"
run_on_all "\"-f TACHYON_SYSTEM_INSTALLATION=yes TACHYON_CONF_DIR=\"/tmp/tachyon_test/conf\" $REMOTE_TACHYON_HOME/bin/tachyon-start.sh master\"" &

sleep 2
get_current_master

echo "Starting workers"
run_on_all "\"TACHYON_SYSTEM_INSTALLATION=yes TACHYON_CONF_DIR=\"/tmp/tachyon_test/conf\" $REMOTE_TACHYON_HOME/bin/tachyon-start.sh worker Mount\"" &

sleep 5

KILLED=1
END=0

while [ $KILLED -le $NUMHOSTS ]; do
  write_files $END
  test_files
  END=$(($END+1))
  if [ $KILLED -lt $NUMHOSTS ];then
    echo "Killing master at $CURRENT_MASTER"
    kill_current_master
    get_current_master
  fi
  KILLED=$(($KILLED+1))
done

echo "Pulling logs"
TMPD=`mktemp -d`
for h in $HOSTS;do
  scp -i $PRIV_KEY "root@$h:/tmp/tachyon_test/logs/*" $TMPD
done

SECS=$(date +%s)
LOGFILE="/tmp/tachyon_remote_cluster_test_logs.$SECS.tar"
pushd $TMPD > /dev/null
tar cf $LOGFILE *
popd > /dev/null
gzip $LOGFILE
rm $TMPD/*
rmdir $TMPD

echo "Logs are in: $LOGFILE.gz"

echo "Leaving cluster running, master is: $CURRENT_MASTER"
if [ $FAILED -eq 1 ]; then
  echo "FAILED (see messages above)"
else
  echo "PASSED"
fi
