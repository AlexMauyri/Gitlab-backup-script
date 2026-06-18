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
LOG_FILE="./logs/gitlab-backup.log"
TELEGRAM_BOT_TOKEN=""
TELEGRAN_CHAT_ID=""

#ARG VARIABLES
ARG_CONFIG=""
ARG_TEST=false

log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }

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

# Опционально: путь к файлу логов (по умолчанию: ./logs/gitlab-backup.log)
# LOG_FILE=./logs/gitlab-backup.log

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

find_config(){
  local paths=(
    "$ARG_CONFIG"
    "$HOME/.config/gitlab-backup.conf"
    "/etc/gitlab-backup.conf"
  )

  for path in "${paths[@]}"; do
    if [[ -n "$path" && -r "$path" ]]; then
      echo "$path"
      return 0
    fi
  done

  if [[ -n "$ARG_CONFIG" ]]; then
    log_error "Указанный конфигурационный файл не найден: $ARG_CONFIG"
  else
    log_error "Конфигурационный файл не найден. Запустите скрипт с флагом --help, чтобы получить шаблон конфигурационного файла."
  fi

  exit 1
}

load_config(){
  if ! source "$1"; then
    log_error "Ошибка при загрузке конфигурационного файла: $1"
    exit 1
  fi

  log_info "Конфигурация загружена из: $1"
}

validate_config(){
  for var in GITLAB_USER GITLAB_TOKEN BACKUP_DIR; do
    if [[ -z "${!var}" ]]; then
      log_error "Пропущен необходимый параметр: $var"
      exit 1
    fi
  done

  if [[ -z "$REPOS" && -z "$REPO_FILE" ]]; then
    log_error "Не указаны репозитории. Укажите REPOS или REPO_FILE в конфигурационном файле." 
    exit 1
  fi

  if [[ -n "$REPO_FILE" && ! -r "$REPO_FILE" ]]; then
    log_error "Файл с репозиториями не найден или недоступен для чтения: $REPO_FILE"
    exit 1
  fi

  if ! mkdir -p "$BACKUP_DIR"; then
    log_error "Не удалось создать директорию для бэкапов: $BACKUP_DIR"
    exit 1
  fi

  PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
  RETRY_COUNT="${RETRY_COUNT:-3}"
  LOG_FILE="${LOG_FILE:-./logs/gitlab-backup.log}"

  for config_arg in PARALLEL_JOBS RETRY_COUNT; do
    if ! [[ "${!config_arg}" =~ ^[1-9][0-9]*$ ]]; then
      log_error "$config_arg должно быть положительным числом: ${!config_arg}"
      exit 1
    fi
  done

  log_info "Конфигурация проверена успешно"
}

read_repos_from_var(){
  if [[ -z "$REPOS" ]]; then
    return 0
  fi

  log_info "Чтение репозиториев из переменной REPOS: ${REPOS}"

  IFS='|' read -ra urls <<< "$REPOS"
  for url in "${urls[@]}"; do
    url="${url// /}"
    if [[ -n "$url" ]]; then
      RAW_URLS+=("$url")
    fi
  done

  log_info "Текущие репозитории: ${RAW_URLS[@]}"
}

read_repos_from_file(){
  if [[ -z "$REPO_FILE" ]]; then
    return 0
  fi
  
  log_info "Чтение репозиториев из файла: ${REPO_FILE}"

  while IFS= read -r url || [[ -n "$url" ]]; do
    url="${url%%#*}"
    url="${url// /}"
    if [[ -n "$url" ]]; then
      RAW_URLS+=("$url")
    fi
  done < "$REPO_FILE"

  log_info "Текущие репозитории: ${RAW_URLS[@]}"
}

filter_duplicate_urls(){
  declare -A seen
  REPO_URLS=()
  for url in "${RAW_URLS[@]}"; do
    if [[ -z "${seen[$url]+x}" ]]; then
      seen["$url"]=1
      REPO_URLS+=("$url")
    fi
  done

  log_info "Получены уникальные репозитории: ${REPO_URLS[@]}"
}

main(){
  parse_args $@

  config_path=$(find_config)
  load_config "$config_path"
  validate_config

  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  
  read_repos_from_var
  read_repos_from_file

  filter_duplicate_urls

  if [[ "$ARG_TEST" == true ]]; then
    log_info "Список уникальных репозиториев: "
    for url in "${REPO_URLS[@]}"; do
      echo " $url"
    done
  fi
}

main $@
