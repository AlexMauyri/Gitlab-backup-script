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

#ARG VARIABLES
ARG_CONFIG=""
ARG_TEST=false

help(){
  cat << EOF
GitLab Backup Script
==========================

Использование:
  gitlab-backup.sh [--config <файл>] [--test] [--help]

Опции:
  --config <файл>    Путь к конфигурационному файлу
  --test             Проверить доступность репозиториев без клонирования
  --help             Показать эту справку и шаблон конфига

Шаблон конфигурационного файла:
--------------------------------
# Конфигурация скрипта бэкапа GitLab
# ==================================
# Все пути должны быть абсолютными.
# Для REPOS URL разделяются символом '|' (вертикальная черта).
# Для REPO_FILE укажите путь к файлу с одним URL на строку.

# Обязательно: имя пользователя GitLab (для логирования, не для аутентификации)
GITLAB_USER=your_username

# Обязательно: Personal Access Token (права read_repository)
GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx

# Обязательно: папка для хранения бэкапов (должна существовать или быть создаваемой)
BACKUP_DIR=/backup/gitlab

# Опционально: список репозиториев (через '|')
# REPOS=https://gitlab.com/group/project1.git|https://gitlab.com/group/project2.git

# Опционально: файл со списком репозиториев (один на строку)
# REPO_FILE=/etc/gitlab-repos.list

# Опционально: количество параллельных процессов (по умолчанию: 4)
# PARALLEL_JOBS=4

# Опционально: количество повторных попыток при сетевых ошибках (по умолчанию: 3)
# RETRY_COUNT=3

# Опционально: путь к файлу логов (по умолчанию: /var/log/gitlab-backup.log)
# LOG_FILE=/var/log/gitlab-backup.log

# Опционально: уведомления в Telegram
# TELEGRAM_BOT_TOKEN=123456:ABC-DEF1234
# TELEGRAM_CHAT_ID=-123456789
EOF
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) ARG_CONFIG="$2";  shift 2 ;;
      --test)   ARG_TEST=true;    shift ;;
      --help)   help;            exit 0 ;;
      *) echo "Неизвестный флаг: $1"; help; exit 1 ;;
    esac
  done
}

main(){
  parse_args $@
}

main $@
