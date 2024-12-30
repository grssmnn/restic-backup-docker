#!/bin/sh

last_logfile="/var/log/check-last.log"
last_mail_logfile="/var/log/check-mail-last.log"
last_microsoft_teams_logfile="/var/log/check-microsoft-teams-last.log"

copyErrorLog() {
  cp ${last_logfile} /var/log/check-error-last.log
}

logLast() {
  echo "$1" >> ${last_logfile}
}

if [ -f "/hooks/pre-check.sh" ]; then
    echo "Starting pre-check script ..."
    /hooks/pre-check.sh
else
    echo "Pre-check script not found ..."
fi

start=`date +%s`
rm -f ${last_logfile} ${last_mail_logfile}
echo "Starting Check at $(date +"%Y-%m-%d %H:%M:%S")"
echo "Starting Check at $(date)" >> ${last_logfile}
logLast "CHECK_CRON: ${CHECK_CRON}"
logLast "RESTIC_DATA_SUBSET: ${RESTIC_DATA_SUBSET}"
logLast "RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}"
logLast "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}"

# Do not save full check log to logfile but to check-last.log
if [ -n "${RESTIC_DATA_SUBSET}" ]; then
    restic check --read-data-subset=${RESTIC_DATA_SUBSET} >> ${last_logfile} 2>&1
else
    restic check >> ${last_logfile} 2>&1
fi
check_rc=$?
logLast "Finished check at $(date)"
if [[ $check_rc == 0 ]]; then
    echo "Check Successful"
else
    echo "Check Failed with Status ${check_rc}"
    restic unlock
    copyErrorLog
fi

end=`date +%s`
echo "Finished Check at $(date +"%Y-%m-%d %H:%M:%S") after $((end-start)) seconds"

if [ -n "${TEAMS_WEBHOOK_URL}" ]; then
    teams_title="Restic Last Check Log"
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

if [ -f "/hooks/post-check.sh" ]; then
    echo "Starting post-check script ..."
    /hooks/post-check.sh $check_rc
else
    echo "Post-check script not found ..."
fi
