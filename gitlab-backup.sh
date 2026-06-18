#!/bin/bash

set -euo pipefail

#CONFIG VARIABLES
GITLAB_USER=""
GITLAB_TOKEN=""
BACKUP_DIR=""
REPOS=""
REPO_FILE=""
PARALLEL_JOBS=4
RETRY_COUNT=3
LOG_FILE="/var/log/gitlab-backup.log"
TELEGRAM_BOT_TOKEN=""
TELEGRAN_CHAT_ID=""

main(){
  echo "Hello, World!"
}

main $@
