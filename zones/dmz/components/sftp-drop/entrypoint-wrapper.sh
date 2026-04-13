#!/bin/sh
# Start rsyslog to forward auth events to scribes-post (10.10.5.32:514),
# then hand off to the atmoz/sftp entrypoint.
rsyslogd
sleep 1
logger -t sftp "Unseen University Power & Light Co. SFTP drop-box (dispatch-box) starting. Anonymous access enabled."
exec /entrypoint "$@"
