#!/bin/sh

last_logfile="/var/log/backup-last.log"
last_mail_logfile="/var/log/mail-last.log"
last_microsoft_teams_logfile="/var/log/microsoft-teams-last.log"

DOCKER_SOCK="/var/run/docker.sock"

copyErrorLog() {
  cp ${last_logfile} /var/log/backup-error-last.log
}

logLast() {
  echo "$1" >> ${last_logfile}
}

if [ -f "/hooks/pre-backup.sh" ]; then
    echo "Starting pre-backup script ..."
    /hooks/pre-backup.sh
else
    echo "Pre-backup script not found ..."
fi

if [ -S "$DOCKER_SOCK" ]; then
  temp_file="$(mktemp)"
  docker ps --format "{{.ID}}" --filter "label=docker-volume-backup.stop-during-backup=true" $CUSTOM_LABEL > "$temp_file"
  containers_to_stop="$(cat $temp_file | tr '\n' ' ')"
  containers_to_stop_total="$(cat $temp_file | wc -l)"
  containers_total="$(docker ps --format "{{.ID}}" | wc -l)"
  rm "$temp_file"
  echo "$containers_total containers running on host in total"
  echo "$containers_to_stop_total containers marked to be stopped during backup"
else
  containers_to_stop_total="0"
  containers_total="0"
  echo "Cannot access \"$DOCKER_SOCK\", won't look for containers to stop"
fi

if [ "$containers_to_stop_total" != "0" ]; then
  info "Stopping containers"
  docker stop $containers_to_stop
fi

start=`date +%s`
rm -f ${last_logfile} ${last_mail_logfile}
echo "Starting Backup at $(date +"%Y-%m-%d %H:%M:%S")"
echo "Starting Backup at $(date)" >> ${last_logfile}
logLast "BACKUP_CRON: ${BACKUP_CRON}"
logLast "RESTIC_TAG: ${RESTIC_TAG}"
logLast "RESTIC_FORGET_ARGS: ${RESTIC_FORGET_ARGS}"
logLast "RESTIC_JOB_ARGS: ${RESTIC_JOB_ARGS}"
logLast "RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}"
logLast "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}"

# Do not save full backup log to logfile but to backup-last.log
restic backup /data ${RESTIC_JOB_ARGS} --tag=${RESTIC_TAG?"Missing environment variable RESTIC_TAG"} >> ${last_logfile} 2>&1
backup_rc=$?
logLast "Finished backup at $(date)"
if [[ $backup_rc == 0 ]]; then
    echo "Backup Successful"
else
    echo "Backup Failed with Status ${backup_rc}"
    restic unlock
    copyErrorLog
fi

if [[ $backup_rc == 0 ]] && [ -n "${RESTIC_FORGET_ARGS}" ]; then
    echo "Forget about old snapshots based on RESTIC_FORGET_ARGS = ${RESTIC_FORGET_ARGS}"
    restic forget ${RESTIC_FORGET_ARGS} >> ${last_logfile} 2>&1
    rc=$?
    logLast "Finished forget at $(date)"
    if [[ $rc == 0 ]]; then
        echo "Forget Successful"
    else
        echo "Forget Failed with Status ${rc}"
        restic unlock
        copyErrorLog
    fi
fi

end=`date +%s`
echo "Finished Backup at $(date +"%Y-%m-%d %H:%M:%S") after $((end-start)) seconds"

if [ -n "${TEAMS_WEBHOOK_URL}" ]; then
    teams_title="Restic Last Backup Log"
    teams_message=$( cat ${last_logfile} | sed 's/"/\"/g' | sed "s/'/\'/g" | sed ':a;N;$!ba;s/\n/\n\n/g' )
    teams_req_body="{\"title\": \"${teams_title}\", \"text\": \"${teams_message}\" }"
    sh -c "curl -H 'Content-Type: application/json' -d '${teams_req_body}' '${TEAMS_WEBHOOK_URL}' > ${last_microsoft_teams_logfile} 2>&1"
    if [ $? == 0 ]; then
        echo "Microsoft Teams notification successfully sent."
    else
        echo "Sending Microsoft Teams notification FAILED. Check ${last_microsoft_teams_logfile} for further information."
    fi
fi

if [ -n "${MAILX_ARGS}" ]; then
    sh -c "mail -v -S sendwait ${MAILX_ARGS} < ${last_logfile} > ${last_mail_logfile} 2>&1"
    if [ $? == 0 ]; then
        echo "Mail notification successfully sent."
    else
        echo "Sending mail notification FAILED. Check ${last_mail_logfile} for further information."
    fi
fi

if [ "$containers_to_stop_total" != "0" ]; then
  info "Starting containers back up"
  docker start $containers_to_stop
fi

if [ -f "/hooks/post-backup.sh" ]; then
    echo "Starting post-backup script ..."
    /hooks/post-backup.sh $backup_rc
else
    echo "Post-backup script not found ..."
fi
