#!/bin/bash

set -euo pipefail

#CONFIG VARIABLES
GITLAB_USER=""
GITLAB_TOKEN=""
BACKUP_DIR=""
TEMP_DIR="/tmp/gitlab_backup_workers"
REPOS=""
REPO_FILE=""
PARALLEL_JOBS=4
RETRY_COUNT=3
LOG_FILE="./logs/gitlab-backup.log"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

#ARG VARIABLES
ARG_CONFIG=""
ARG_TEST=false

FAILED_URLS=()

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

transform_url(){
  local url="$1"
  local auth_url="${url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"
  echo "$auth_url"
}

get_project_name(){
  local url="$1"
  local name="${url##*/}"
  name="${name%.git}"
  echo "$name"
}

test_mode(){
  echo "Проверка доступности репозиториев"
  echo "================================="
  local ok=0 fail=0
  for url in "${REPO_URLS[@]}"; do
    if git ls-remote --heads "$url" &> /dev/null; then
      echo "$url - доступен"
      ((ok++))
    else
      echo "$url - недоступен"
      ((fail++))
    fi
  done
  echo "Итого: доступно $ok, недоступно $fail"
  exit 0
}

retry() {
  local n=0
  until [[ $n -ge $RETRY_COUNT ]]; do
    "$@" && return 0
    ((n++))
    local delay=$((2 ** n))
    log_warn "Попытка $n/$RETRY_COUNT через ${delay}с"
    sleep "$delay"
  done
  log_error "Не удалось после $RETRY_COUNT попыток: $*"
  return 1
}

clone_project() {
  local url="$1"
  local wid="${2:-0}"
  local prefix="[worker-$wid]"
  local project_name=$(get_project_name "$url")
  local date_dir=$(date "+%d-%m-%Y")
  local target_dir="$BACKUP_DIR/$project_name/$date_dir/$project_name"

  if [[ -d "$target_dir" ]]; then
    log_info "$prefix Обновление существующего зеркала: $project_name"
    if ! retry git -C "$target_dir" remote update --prune; then
      return 1
    fi
    log_info "$prefix Обновлено: $project_name"
    return 0
  fi

  mkdir -p "$(dirname "$target_dir")"
  log_info "$prefix Клонирование $project_name -> $target_dir"
  if ! retry git clone --mirror "$url" "$target_dir"; then
    return 1
  fi
  log_info "$prefix Выполнено: $project_name"
}

split_into_chunks(){
  local total=${#REPO_URLS[@]}
  log_info "Количество репозиториев на обработку: $total"
  local chunk_size=$(( (total + PARALLEL_JOBS - 1) / PARALLEL_JOBS ))
  log_info "Размер чанка для workers: $chunk_size"
  local w start
  for (( w=0; w<PARALLEL_JOBS; w++ )); do
    start=$(( w * chunk_size ))
    local chunk=("${REPO_URLS[@]:$start:$chunk_size}")
    if [[ ${#chunk[@]} -eq 0 ]]; then
      continue
    fi
    printf '%s\n' "${chunk[@]}" > "${TEMP_DIR}/worker-${w}.list"
  done

  log_info "Все файлы workers: $(ls $TEMP_DIR)"
}

worker(){
  local wid="$1"
  local list_file="$2"
  local prefix="[worker-$wid]"
  local all_succeed=true
  log_info "$prefix обрабатывает следующие репозитории: $(cat "$list_file")"
  while IFS= read -r url; do
    if clone_project "$url" "$wid"; then
      (
        flock -x 200
        echo "ok" >> "$STATS_DIR/ok"
      ) 200>"${STATS_DIR}/counter.lock"
    else
      log_error "$prefix не удалось обработать следующий репозиторий: $url"
      (
        flock -x 200
        echo "$url" >> "$FAILED_LIST"
        echo "fail" >> "$STATS_DIR/fail"
      ) 200>"${STATS_DIR}/counter.lock"
      all_succeed=false
    fi
  done < "$list_file"
  log_info "$prefix завершил свою работу"

  if [[ $all_succeed == false ]]; then
      log_error "$prefix завершил с ошибками"
      return 1
  else
      log_info "$prefix завершил успешно"
      return 0
  fi
}

send_telegram() {
    local message="$1"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 0
    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=$message" \
        -d "parse_mode=Markdown" > /dev/null
}

send_summary() {
    local ok="$1" fail="$2" duration="$3"
    local icon="✅" status="Успешно"
    if [[ $fail -gt 0 ]]; then
      icon="⚠️"
      status="С ошибками"
    fi
    send_telegram "*GitLab Backup* ${icon}
Статус: ${status}
✅ Успешно: ${ok}
❌ Ошибки: ${fail}
⏱ Время: ${duration}"
}

main(){
  parse_args $@

  local start_time=$(date +%s)

  cleanup() {
    local exit_code=$?
    log_warn "Очистка временных файлов..."
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    rm -rf "$STATS_DIR" 2>/dev/null || true
    if [[ $exit_code -ne 0 ]]; then
      send_telegram "⚠️ *GitLab Backup прерван* (код $exit_code)"
    fi
  }
  trap cleanup EXIT
  trap 'log_warn "Прервано (INT)"; exit 130' INT
  trap 'log_warn "Завершено (TERM)"; exit 143' TERM
  TEMP_DIR=$(mktemp -d)
  STATS_DIR=$(mktemp -d)
  export STATS_DIR

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

  for (( i=0; i<${#REPO_URLS[@]}; i++ )); do
    REPO_URLS[i]="$(transform_url "${REPO_URLS[i]}")"
  done

  if [[ "$ARG_TEST" == true ]]; then
    log_info "Список уникальных репозиториев (с аутентификацией):"
    for url in "${REPO_URLS[@]}"; do
      echo " $url"
    done

    test_mode
  fi

  split_into_chunks

  FAILED_LIST="$TEMP_DIR/failed_urls.list"

  declare -a WORKER_PIDS=()
  for list_file in "${TEMP_DIR}"/worker-*.list; do
    if ! [[ -r "$list_file" ]]; then
      continue
    fi
    local wid="${list_file##*-}"
    wid="${wid%.list}"
    worker "$wid" "$list_file" &
    WORKER_PIDS+=($!)
  done

  set +e
  local failed=0
  for pid in "${WORKER_PIDS[@]}"; do
    if ! wait "$pid"; then
      ((failed++))
    fi
  done
  set -e

  if [[ -f "$FAILED_LIST" && -s "$FAILED_LIST" ]]; then
    mapfile -t FAILED_URLS < "$FAILED_LIST"
  fi

  local ok_count=$(wc -l < "$STATS_DIR/ok" 2>/dev/null || echo 0)
  local fail_count=$(wc -l < "$STATS_DIR/fail" 2>/dev/null || echo 0)
  local duration=$(($(date +%s) - start_time))
  log_info "Бэкап завершён: успешно $ok_count, ошибок $fail_count, время ${duration}с"
  send_summary "$ok_count" "$fail_count" "${duration}с"
  
  if [[ $failed -eq 0 ]]; then
    log_info "Все workers закончили успешно"
  else
    log_warn "$failed worker(s) закончили с ошибкой"
  fi

  if [[ ${#FAILED_URLS[@]} -gt 0 ]]; then
    log_error "Не удалось клонировать следующие репозитории:"
    for url in "${FAILED_URLS[@]}"; do
      log_error "$url; "
    done
    exit 1
  else
    log_info "Бэкап успешно закончен"
    exit 0
  fi
}

main $@
