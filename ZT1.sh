#!/bin/sh

# ============================================
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ДЛЯ НАСТРОЙКИ
# ============================================

# Настройки ZeroTier
ZT_NETWORK_ID="16a57f6ab54047fc"
ZT_PORT="9993"
ZT_CONFIG_PATH="/etc/config/zerotier-one"

# URL файла planet (пользовательские корневые серверы)
ZT_PLANET_URL="https://raw.githubusercontent.com/zemil78/Zerotier/main/planet"

# Настройки интерфейса
ZT_ZONE_NAME="vpn"
ZT_FIREWALL_ZONE="vpn"
ZT_INTERFACE_NAME="zerotier"

# Настройки файрвола (разрешить доступ к сетям)
ZT_FORWARD_TO_LAN=true
ZT_FORWARD_TO_WAN=true
ZT_FORWARD_FROM_LAN=true

# Настройки автозапуска
ZT_RC_LOCAL_DELAY="30"

# Пути к конфигурациям
ZT_OLD_PATHS="/var/lib/zerotier-one /var/lib/zerotier-luci /etc/zerotier /tmp/zerotier-*"
ZT_UCI_CONFIG="/etc/config/zerotier"

# Логирование
ZT_VERBOSE=true  # true/false - показывать подробный вывод

# ============================================
# ФУНКЦИИ
# ============================================

log() {
    if [ "$ZT_VERBOSE" = true ]; then
        echo "[$(date '+%H:%M:%S')] $1"
    fi
}

error() {
    echo "❌ ОШИБКА: $1" >&2
    exit 1
}

success() {
    echo "✅ $1"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Запустите скрипт от root: sudo $0"
    fi
}

# ============================================
# ОСНОВНОЙ СКРИПТ
# ============================================

# Проверка прав
check_root

log "Начало настройки ZeroTier с пользовательским planet"

# Остановить сервис
log "Остановка сервиса..."
/etc/init.d/zerotier stop 2>/dev/null
killall zerotier-one 2>/dev/null
sleep 2

# Удалить пакет
log "Удаление пакета zerotier..."
apk del zerotier 2>/dev/null

# Удалить все папки с конфигурациями
log "Удаление старых конфигураций..."
for path in $ZT_OLD_PATHS; do
    rm -rf $path 2>/dev/null
    log "  Удалено: $path"
done
rm -f $ZT_UCI_CONFIG 2>/dev/null

# Удалить из UCI network
uci delete network.zerotier 2>/dev/null
uci commit network

# Удалить правила форвардинга (динамически, без ограничения по индексам)
log "Очистка правил firewall..."
while true; do
    FOUND=false
    for i in $(seq 0 100); do
        if uci get firewall.@forwarding[$i] 2>/dev/null | grep -q "src='$ZT_ZONE_NAME'\|dest='$ZT_ZONE_NAME'"; then
            uci delete firewall.@forwarding[$i]
            FOUND=true
            break
        fi
    done
    [ "$FOUND" = false ] && break
done

# Удалить саму зону vpn
for i in $(seq 0 100); do
    if uci get firewall.@zone[$i].name 2>/dev/null | grep -q "$ZT_ZONE_NAME"; then
        uci delete firewall.@zone[$i]
        break
    fi
done

uci commit firewall
log "Firewall очищен"

# Обновить списки пакетов
log "Обновление репозиториев..."
apk update || error "Не удалось обновить репозитории"

# Установить ZeroTier
log "Установка ZeroTier..."
apk add zerotier || error "Не удалось установить zerotier"

# Создать папку для постоянного хранения
log "Создание конфигурационной директории: $ZT_CONFIG_PATH"
mkdir -p "$ZT_CONFIG_PATH"

# Удалить опасную строку rm -rf из init.d скрипта
log "Патчинг /etc/init.d/zerotier(Комментируем)..."
if [ -f /etc/init.d/zerotier ]; then
    sed -i 's/^\([^#]*rm -rf "${CONFIG_PATH}"\)/# \1/' /etc/init.d/zerotier
    success "Закоментрованна строка rm -rf из init.d"
else
    log "Файл /etc/init.d/zerotier не найден"
fi

# Скачать пользовательский planet файл
log "Загрузка planet файла из: $ZT_PLANET_URL"
wget -O "$ZT_CONFIG_PATH/planet" "$ZT_PLANET_URL" || error "Не удалось загрузить planet файл"
chmod 644 "$ZT_CONFIG_PATH/planet"
success "Planet файл установлен"

# Удалить временную папку (если создалась)
rm -rf /var/lib/zerotier-one 2>/dev/null

# Создать чистый конфиг UCI
log "Создание UCI конфигурации..."
cat > $ZT_UCI_CONFIG << EOF
config zerotier 'global'
	option enabled '1'
	option port '$ZT_PORT'
	option config_path '$ZT_CONFIG_PATH'
EOF
success "UCI конфигурация создана"

# Включить автозапуск
log "Настройка автозапуска..."
/etc/init.d/zerotier enable

# Запустить сервис
log "Запуск сервиса..."
/etc/init.d/zerotier start
sleep 10

# Проверить статус
log "Проверка статуса..."
zerotier-cli status

# Подключиться к сети
log "Подключение к сети: $ZT_NETWORK_ID"
zerotier-cli join "$ZT_NETWORK_ID"
sleep 5

# Повторная проверка статуса
zerotier-cli status

# Найти интерфейс ZeroTier
ZT_DEV=$(ip link show | grep -o 'zt[^:]*' | head -1)

if [ -n "$ZT_DEV" ]; then
    success "Найден интерфейс: $ZT_DEV"
    
    # Создать интерфейс в UCI
    uci set network.$ZT_INTERFACE_NAME=interface
    uci set network.$ZT_INTERFACE_NAME.proto='none'
    uci set network.$ZT_INTERFACE_NAME.device="$ZT_DEV"
    
    # Создать зону firewall
    uci add firewall zone
    uci set firewall.@zone[-1].name="$ZT_ZONE_NAME"
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'
    uci set firewall.@zone[-1].masq='1'
    uci add_list firewall.@zone[-1].network="$ZT_INTERFACE_NAME"
    
    # Правила форвардинга
    if [ "$ZT_FORWARD_TO_LAN" = true ]; then
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src="$ZT_ZONE_NAME"
        uci set firewall.@forwarding[-1].dest='lan'
        log "Добавлено правило: vpn -> lan"
    fi
    
    if [ "$ZT_FORWARD_TO_WAN" = true ]; then
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src="$ZT_ZONE_NAME"
        uci set firewall.@forwarding[-1].dest='wan'
        log "Добавлено правило: vpn -> wan"
    fi
    
    if [ "$ZT_FORWARD_FROM_LAN" = true ]; then
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest="$ZT_ZONE_NAME"
        log "Добавлено правило: lan -> vpn"
    fi
    
    # Применить настройки
    uci commit network
    uci commit firewall
    /etc/init.d/firewall restart
    
    success "Файрвол настроен"
else
    error "Интерфейс ZeroTier не создан"
fi

# Добавить в rc.local (если ещё не добавлено)
if ! grep -q "zerotier-cli join $ZT_NETWORK_ID" /etc/rc.local; then
    log "Добавление в rc.local..."
    sed -i "/exit 0/i sleep $ZT_RC_LOCAL_DELAY\nzerotier-cli join $ZT_NETWORK_ID" /etc/rc.local
    success "Добавлено в автозагрузку"
fi

# Финальная проверка
log "=========================================="
log "Финальная проверка:"
zerotier-cli listnetworks

success "Настройка ZeroTier завершена!"
log "=========================================="
log "Сеть: $ZT_NETWORK_ID"
log "Конфигурация: $ZT_CONFIG_PATH"
log "Planet файл: $ZT_PLANET_URL"
