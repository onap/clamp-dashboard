#!/bin/bash -x
###
# ============LICENSE_START=======================================================
# ONAP CLAMP
# ================================================================================
# Copyright (C) 2018 AT&T Intellectual Property. All rights
#                             reserved.
# ================================================================================
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ============LICENSE_END============================================
# ===================================================================
#
###
KIBANA_CONF_FILE="/usr/share/kibana/config/kibana.yml"
SAVED_OBJECTS_ROOT="/saved-objects/"
RESTORE_CMD="/usr/local/bin/restore.py -H http://localhost:5601/ -f"
BACKUP_BIN="/usr/local/bin/backup.py"
KIBANA_START_CMD="/usr/local/bin/kibana-docker"
LOG_FILE="/tmp/load.kibana.log"
#KIBANA_LOAD_CMD="/usr/local/bin/kibana-docker -H 127.0.0.1 -l $LOG_FILE"
KIBANA_LOAD_CMD="/usr/local/bin/kibana-docker -l $LOG_FILE"
TIMEOUT=60
WAIT_TIME=2
LOADED_FLAG=$SAVED_OBJECTS_ROOT/.loaded

if [ -f $LOADED_FLAG ];
then
    echo "---- Kibana saved objects already restored. Remove $LOADED_FLAG if you want to restore them again."
elif [ -n "$(ls -A ${SAVED_OBJECTS_ROOT}/*)" ];
then
    echo "---- Waiting for elasticsearch to be up..."
    RES=-1
    PING_TIMEOUT=60
    SSL_SERVER_ENABLED_orig=$(grep '^[[:blank:]]*[^[:blank:]#]' /usr/share/kibana/config/kibana.yml | grep server.ssl.enabled | cut -d\  -f2)
    if [[ $SSL_SERVER_ENABLED_orig == \${* ]]
    then
     tmp2=${SSL_SERVER_ENABLED_orig#"\${"}
     tmp2=${tmp2%"}"}
     SSL_SERVER_ENABLED=${!tmp2}
    else
     SSL_SERVER_ENABLED=${SSL_SERVER_ENABLED_orig}
    fi

    if [ "$SSL_SERVER_ENABLED" = "true" ];
    then
       RESTORE_CMD="/usr/local/bin/restore.py -H https://localhost:5601/ -f"
    fi
   
    elastic_url_orig=$(grep '^[[:blank:]]*[^[:blank:]#;]' /usr/share/kibana/config/kibana.yml | grep elasticsearch.hosts | cut -d\  -f2)
#    tmp1 = ${elastic_url:0:2}
#    if [ "tmp1" = "\${" ];
    if [[ $elastic_url_orig == \${* ]]
    then
     tmp2=${elastic_url_orig#"\${"}
     tmp2=${tmp2%"}"}
     elastic_url=${!tmp2}
    else
     elastic_url=${elastic_url_orig}
    fi
   
    while [ ! "$RES" -eq "0" ] && [ "$PING_TIMEOUT" -gt "0" ];
    do
        curl -k $elastic_url
        RES=$?
        sleep $WAIT_TIME
        let PING_TIMEOUT=$PING_TIMEOUT-$WAIT_TIME
    done

    echo "---- Saved objects found, restoring files."

    $KIBANA_LOAD_CMD &
    KIB_PID=$!

    # Wait for log file to be avaiable
    LOG_TIMEOUT=60
    while [ ! -f $LOG_FILE ] && [ "$LOG_TIMEOUT" -gt "0" ];
    do
        echo "Waiting for $LOG_FILE to be available..."
        sleep $WAIT_TIME
        let LOG_TIMEOUT=$LOG_TIMEOUT-$WAIT_TIME
    done

    tail -f $LOG_FILE &
    LOG_PID=$!

    # Wait for kibana to be listening !!!
    if [ "$SSL_SERVER_ENABLED" = "true" ];
    then
       RES_KIBANA=$(curl -k --write-out %{http_code} --silent --output /dev/null https://localhost:5601)
    else
       RES_KIBANA=$(curl -k --write-out %{http_code} --silent --output /dev/null http://localhost:5601)
    fi
    echo "KIBANA Site status is now: $RES_KIBANA"
    while [[ "$RES_KIBANA" -ne 302 ]] && [ "$TIMEOUT" -gt "0" ];
    do
      echo "KIBANA Site status is still: $RES_KIBANA"
      sleep $WAIT_TIME
      let LOG_TIMEOUT=$LOG_TIMEOUT-$WAIT_TIME
      if [ "$SSL_SERVER_ENABLED" = "true" ];
      then
          RES_KIBANA=$(curl -k --write-out %{http_code} --silent --output /dev/null https://localhost:5601)
      else
          RES_KIBANA=$(curl -k --write-out %{http_code} --silent --output /dev/null http://localhost:5601)
      fi
    done
    echo "KIBANA Site status is good(http code 302): $RES_KIBANA"

    # Wait for kibana to be listening
    while [ -z "$(grep "Server running at" $LOG_FILE)" ] && [ "$TIMEOUT" -gt "0" ];
    do
        echo "Waiting for kibana to start..."
        sleep $WAIT_TIME
        let TIMEOUT=$TIMEOUT-$WAIT_TIME
    done
   
    while [ -z "$(grep "http server running" $LOG_FILE)" ] && [ "$TIMEOUT" -gt "0" ];
    do
        echo "Waiting for kibana http server to start..."
        sleep $WAIT_TIME
        let TIMEOUT=$TIMEOUT-$WAIT_TIME
    done   
    sleep 4

    # restore files
    for saved_objects_path in $SAVED_OBJECTS_ROOT/*
    do
        # skip files as we only need directories
        [ -f $saved_objects_path ] && continue

        echo "Restoring content of $saved_objects_path"
        $RESTORE_CMD -C $saved_objects_path
        sleep 1
    done
    
    touch $LOADED_FLAG
    if [ "$?" != "0" ];
    then
        echo "WARNING: Could not save $LOADED_FLAG, saved objects will be restored on next startup." >&2
    fi

    # cleanup
    kill $KIB_PID
    kill $LOG_PID
else
    echo "---- No saved object found"
    ls -A ${SAVED_OBJECTS_ROOT}/*
fi

echo "---- Starting kibana"

$KIBANA_START_CMD

