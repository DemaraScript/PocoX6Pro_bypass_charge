#!/system/bin/sh
###############################################################################
# bypass_charge_menu.sh — обходная зарядка (mtk_battery_cmd current_cmd)
# By Limbress 4pda / powered - azenith, claude
###############################################################################

BASE_DIR=/data/local/tmp/Limb_Settings
CONF=$BASE_DIR/bypass.conf
LOG=$BASE_DIR/bypass.log
PIDFILE=$BASE_DIR/bypass_monitor.pid
STATEFILE=$BASE_DIR/bypass_state

CMD_NODE=/proc/mtk_battery_cmd/current_cmd
CAP_NODE=/sys/class/power_supply/battery/capacity
TEMP_NODE=/sys/class/power_supply/battery/temperature   # десятые градуса (382 = 38.2C)
ONLINE_NODE=/sys/class/power_supply/usb/online          # 1 = заряд подключен

DEFAULT_TARGET=80
DEFAULT_HYST=3
DEFAULT_TEMP_LIMIT=440
DEFAULT_EXTRA=0
DEFAULT_STATE="-"

# ---------------------------- цвета / экран ---------------------------------
C_RESET="\033[0m"
C_CYAN="\033[1;36m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_YELLOW="\033[1;33m"
C_DIM="\033[2m"
C_MAG="\033[1;35m"

cls() { printf '\033c'; }
TICKER_PID=""

# ----------------------------- storage / config ------------------------------
init_storage() {
  mkdir -p "$BASE_DIR"

  if [ ! -f "$CONF" ]; then
    echo "TARGET=$DEFAULT_TARGET" > "$CONF"
    echo "HYST=$DEFAULT_HYST" >> "$CONF"
    echo "TEMP_LIMIT=$DEFAULT_TEMP_LIMIT" >> "$CONF"
    echo "EXTRA_MODE=$DEFAULT_EXTRA" >> "$CONF"
  fi

  [ -f "$LOG" ] || touch "$LOG"
  [ -f "$STATEFILE" ] || echo "$DEFAULT_STATE" > "$STATEFILE"
}

log() {
  echo "$(date +%H:%M:%S) $1" >> "$LOG"
}

load_conf() {
  [ -f "$CONF" ] && . "$CONF"

  [ -z "$TARGET" ] && TARGET=$DEFAULT_TARGET
  [ -z "$HYST" ] && HYST=$DEFAULT_HYST
  [ -z "$TEMP_LIMIT" ] && TEMP_LIMIT=$DEFAULT_TEMP_LIMIT
  [ -z "$EXTRA_MODE" ] && EXTRA_MODE=$DEFAULT_EXTRA
}

save_conf() {
  mkdir -p "$BASE_DIR"
  {
    echo "TARGET=$TARGET"
    echo "HYST=$HYST"
    echo "TEMP_LIMIT=$TEMP_LIMIT"
    echo "EXTRA_MODE=$EXTRA_MODE"
  } > "$CONF"
}

save_state() {
  echo "$1" > "$STATEFILE"
}

load_state() {
  [ -f "$STATEFILE" ] && cat "$STATEFILE" || echo "$DEFAULT_STATE"
}

# ----------------------------- helpers ---------------------------------------
pid_alive() {
  [ -f "$PIDFILE" ] || return 1
  PID="$(cat "$PIDFILE" 2>/dev/null)"
  case "$PID" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$PID" 2>/dev/null
}

clear_pidfile() {
  rm -f "$PIDFILE"
}

get_cap()    { cat "$CAP_NODE" 2>/dev/null; }
get_temp()   { cat "$TEMP_NODE" 2>/dev/null; }
get_online() { cat "$ONLINE_NODE" 2>/dev/null; }

bypass_on() {
  echo "0 1" > "$CMD_NODE" 2>/dev/null
  log "BYPASS ON (cap=$(get_cap)% temp=$(get_temp))"
}

bypass_off() {
  echo "0 0" > "$CMD_NODE" 2>/dev/null
  log "BYPASS OFF (cap=$(get_cap)% temp=$(get_temp))"
}

# ----------------------------- monitor daemon --------------------------------
monitor_loop() {
  echo $$ > "$PIDFILE"
  trap 'clear_pidfile' EXIT

  log "MONITOR START target=$TARGET hyst=$HYST temp_limit=$TEMP_LIMIT"

  while true; do
    CAP=$(get_cap)
    TEMP=$(get_temp)
    ONLINE=$(get_online)

    if [ -z "$CAP" ] || [ -z "$TEMP" ]; then
      log "MONITOR: capacity/temp не читаются"
      sleep 5
      continue
    fi

    if [ "$TEMP" -ge "$TEMP_LIMIT" ]; then
      bypass_off
      log "MONITOR: SAFETY temp=$TEMP >= limit=$TEMP_LIMIT, жду остывания"
      sleep 15
      continue
    fi

    if [ "$ONLINE" != "1" ]; then
      sleep 10
      continue
    fi

    if [ "$CAP" -ge "$TARGET" ]; then
      bypass_on
    elif [ "$CAP" -le $((TARGET - HYST)) ]; then
      bypass_off
    fi

    sleep 10
  done
}

start_monitor() {
  if pid_alive; then
    echo "${C_YELLOW}Демон уже запущен (PID $(cat "$PIDFILE"))${C_RESET}"
    sleep 1
    return
  fi

  clear_pidfile

  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$0" __daemon >> "$LOG" 2>&1 </dev/null &
  else
    nohup sh "$0" __daemon >> "$LOG" 2>&1 </dev/null &
  fi

  sleep 1

  if pid_alive; then
    save_state "1"
    echo "${C_GREEN}Демон запущен — держит заряд около ${TARGET}% (гистерезис ${HYST}%)${C_RESET}"
    log "MONITOR STARTED"
  else
    echo "${C_RED}Не удалось запустить демон${C_RESET}"
    log "MONITOR START FAILED"
  fi

  sleep 1
}

stop_monitor() {
  if pid_alive; then
    PID="$(cat "$PIDFILE" 2>/dev/null)"
    kill "$PID" 2>/dev/null
    sleep 1
    clear_pidfile
    bypass_off
    save_state "2"
    echo "${C_RED}Демон остановлен, обычная зарядка восстановлена${C_RESET}"
    log "MONITOR STOP (manual)"
  else
    clear_pidfile
    echo "Демон не запущен"
  fi
  sleep 1
}

# ----------------------------- extra mode ------------------------------------
extra_on() {
  bypass_on
  save_state "E"
  echo "${C_MAG}>>> EXTRA: bypass включён мгновенно, без настроек и без демона <<<${C_RESET}"
  log "EXTRA bypass ON (override)"
  sleep 1
}

extra_off() {
  bypass_off
  save_state "F"
  echo "${C_MAG}>>> EXTRA: bypass выключен мгновенно, без настроек и без демона <<<${C_RESET}"
  log "EXTRA bypass OFF (override)"
  sleep 1
}

# ----------------------------- settings --------------------------------------
set_target() {
  cls
  echo -n "Целевой % удержания заряда, 1-100 (сейчас $TARGET): "
  read NEW
  case "$NEW" in
    ''|*[!0-9]*) echo "Не число, отмена"; sleep 1; return ;;
  esac
  if [ "$NEW" -lt 1 ] || [ "$NEW" -gt 100 ]; then
    echo "Вне диапазона 1-100, отмена"; sleep 1; return
  fi
  TARGET=$NEW
  save_conf
  echo "${C_GREEN}Порог зарядки установлен: ${TARGET}%${C_RESET}"
  sleep 1
}

set_hyst() {
  cls
  echo -n "Гистерезис, % (сейчас $HYST): "
  read NEW
  case "$NEW" in
    ''|*[!0-9]*) echo "Не число, отмена"; sleep 1; return ;;
  esac
  if [ "$NEW" -lt 0 ] || [ "$NEW" -gt 20 ]; then
    echo "Вне диапазона 0-20, отмена"; sleep 1; return
  fi
  HYST=$NEW
  save_conf
  echo "${C_GREEN}Гистерезис установлен: ${HYST}%${C_RESET}"
  sleep 1
}

set_temp_limit() {
  cls
  echo -n "Лимит температуры в десятых градуса, напр. 440=44.0C (сейчас $TEMP_LIMIT): "
  read NEW
  case "$NEW" in
    ''|*[!0-9]*) echo "Не число, отмена"; sleep 1; return ;;
  esac
  TEMP_LIMIT=$NEW
  save_conf
  echo "${C_GREEN}Лимит температуры: $((TEMP_LIMIT/10)).$((TEMP_LIMIT%10)) C${C_RESET}"
  sleep 1
}

toggle_extra() {
  cls
  if [ "$EXTRA_MODE" = "1" ]; then
    EXTRA_MODE=0
    save_conf
    echo "${C_YELLOW}Extra features ВЫКЛЮЧЕН — вернулись пункты 1)/2) с демоном${C_RESET}"
    log "EXTRA MODE OFF"
  else
    if pid_alive; then
      PID="$(cat "$PIDFILE" 2>/dev/null)"
      kill "$PID" 2>/dev/null
      clear_pidfile
      log "MONITOR STOP (extra mode enabled)"
      echo "${C_DIM}Демон был запущен — остановлен, т.к. Extra features его не использует${C_RESET}"
    fi
    EXTRA_MODE=1
    save_conf
    echo "${C_MAG}Extra features ВКЛЮЧЕН — теперь E)/F), мгновенно, без демона и без настроек${C_RESET}"
    log "EXTRA MODE ON"
  fi
  sleep 2
}

settings_menu() {
  while true; do
    cls
    echo "${C_CYAN}==== Настройки ====${C_RESET}"
    echo "1) Порог зарядки         (сейчас ${TARGET}%)"
    echo "2) Порог температуры     (сейчас $((TEMP_LIMIT/10)).$((TEMP_LIMIT%10))C)"
    echo "3) Extra features        (сейчас $([ "$EXTRA_MODE" = "1" ] && echo "${C_MAG}ВКЛ${C_RESET}" || echo "${C_DIM}выкл${C_RESET}"))"
    echo "4) Гистерезис            (сейчас ${HYST}%)"
    echo "0) Назад"
    echo "===================="
    printf "Выбор: "
    read SCH
    case "$SCH" in
      1) set_target ;;
      2) set_temp_limit ;;
      3) toggle_extra ;;
      4) set_hyst ;;
      0) return ;;
      *) echo "Нет такого пункта"; sleep 1 ;;
    esac
  done
}

show_log() {
  cls
  echo "${C_CYAN}=== последние 25 строк лога ===${C_RESET}"
  tail -n 25 "$LOG" 2>/dev/null
  echo ""
  echo "Нажми Enter для возврата"
  read _DUMMY
}

# ----------------------------- banner ----------------------------------------
print_banner() {
  printf '%b\n' "${C_CYAN}"
  printf '%b\n' " ██╗     ██╗███╗   ███╗██████╗ "
  printf '%b\n' " ██║     ██║████╗ ████║██╔══██╗"
  printf '%b\n' " ██║     ██║██╔████╔██║██████╔╝"
  printf '%b\n' " ██║     ██║██║╚██╔╝██║██╔══██╗"
  printf '%b\n' " ███████╗██║██║ ╚═╝ ██║██████╔╝"
  printf '%b\n' " ╚══════╝╚═╝╚═╝     ╚═╝╚═════╝ "
  printf '%b\n' "${C_RESET}"
  printf '%b\n' "${C_DIM}        By Limbress 4pda${C_RESET}"
  printf '%b\n' "${C_DIM}     powered - azenith, claude${C_RESET}"
  echo "================================="
  printf '%b\n' "${C_YELLOW}   Bypass charge Poco X6 Pro${C_RESET}"
  echo "  Tested on 16 android LineageOS"
  echo "================================="
}

# ----------------------------- screen ----------------------------------------
LINE_NO=0
eline() { printf '%b\n' "$1"; LINE_NO=$((LINE_NO + 1)); }

render_screen() {
  cls
  LINE_NO=0
  print_banner
  LINE_NO=14

  eline "${C_YELLOW}==== Menu ====${C_RESET}"
  if [ "$EXTRA_MODE" = "1" ]; then
    eline "${C_MAG}E) Включить обходную зарядку (мгновенно, без демона)${C_RESET}"
    eline "${C_MAG}F) Выключить обходную зарядку (мгновенно, без демона)${C_RESET}"
  else
    eline "1) Включить обходную зарядку (демон)"
    eline "2) Выключить обходную зарядку (демон)"
  fi
  eline "3) Настройки"
  eline "0) Выход"
  eline "7) Лог"
  eline "===="
  eline "${C_YELLOW}State${C_RESET}"

  ZARYAD_ROW=$((LINE_NO + 1))
  ONLINE_NOW=$(get_online)
  eline "Зарядка       - $([ "$ONLINE_NOW" = "1" ] && printf "${C_GREEN}подключена${C_RESET}" || printf "${C_DIM}нет${C_RESET}")"

  if pid_alive; then
    eline "Демон         - ${C_GREEN}запущен${C_RESET} (target=${TARGET}% hyst=${HYST}%)"
  else
    eline "Демон         - ${C_DIM}нет${C_RESET}"
  fi

  ST=$(load_state)
  eline "Статус bypass - режим [$ST]  (1=демон ON, 2=демон OFF, E=extra ON, F=extra OFF)"
  eline "===="
  printf "Выбор: "
}

start_ticker() {
  ( while true; do
      sleep 2
      O=$(get_online)
      TXT=$([ "$O" = "1" ] && printf "${C_GREEN}подключена${C_RESET}" || printf "${C_DIM}нет${C_RESET}")
      printf '\033[s\033[%d;1H\033[2KЗарядка       - %b\033[u' "$ZARYAD_ROW" "$TXT"
    done ) &
  TICKER_PID=$!
}

stop_ticker() {
  [ -n "$TICKER_PID" ] && kill "$TICKER_PID" 2>/dev/null
  TICKER_PID=""
}

trap 'stop_ticker' INT TERM HUP

# ----------------------------- daemon mode -----------------------------------
if [ "$1" = "__daemon" ]; then
  init_storage
  load_conf
  monitor_loop
  exit 0
fi

# ----------------------------- main ------------------------------------------
init_storage
load_conf

while true; do
  render_screen
  start_ticker
  read CH
  stop_ticker

  case "$CH" in
    [Ee])
      if [ "$EXTRA_MODE" = "1" ]; then
        extra_on
      else
        echo "Extra features выключен — сначала включи в Настройках (3)"
        sleep 1
      fi
      ;;
    [Ff])
      if [ "$EXTRA_MODE" = "1" ]; then
        extra_off
      else
        echo "Extra features выключен — сначала включи в Настройках (3)"
        sleep 1
      fi
      ;;
    1)
      if [ "$EXTRA_MODE" = "1" ]; then
        echo "Пункт 1 скрыт в Extra-режиме, используй E"
        sleep 1
      else
        start_monitor
      fi
      ;;
    2)
      if [ "$EXTRA_MODE" = "1" ]; then
        echo "Пункт 2 скрыт в Extra-режиме, используй F"
        sleep 1
      else
        stop_monitor
      fi
      ;;
    3) settings_menu ;;
    7) show_log ;;
    0)
      cls
      echo "Выход из меню. Демон (если был запущен) продолжит работать в фоне."
      exit 0
      ;;
    *)
      echo "Нет такого пункта"
      sleep 1
      ;;
  esac
done
