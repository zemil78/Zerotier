#!/bin/sh

# ============================================
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ДЛЯ НАСТРОЙКИ
# ============================================

# Настройки ZeroTier
ZT_NETWORK_ID="16a57f6ab54047fc"
ZT_PORT="9993"
ZT_CONFIG_PATH="/etc/config/zerotier-one"

# URL файла planet (пользовательские корневые серверы)
ZT_PLANET_URL="https://raw.githubusercontent.com/zemil78/Zerotier/main/planet.ru"

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
# ОПРЕДЕЛЕНИЕ ПАКЕТНОГО МЕНЕДЖЕРА
# ============================================

detect_package_manager() {
    if command -v opkg >/dev/null 2>&1; then
        echo "opkg"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    elif command -v apt >/dev/null 2>&1; then
        echo "apt"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    else
        echo "unknown"
    fi
}

# ============================================
# ФУНКЦИИ ДЛЯ РАБОТЫ С ПАКЕТАМИ
# ============================================

pkg_update() {
    local pm=$1
    case $pm in
        opkg)
            opkg update
            ;;
        apk)
            apk update
            ;;
        apt)
            apt update
            ;;
        yum|dnf)
            $pm check-update
            ;;
        *)
            error "Неизвестный пакетный менеджер: $pm"
            ;;
    esac
}

pkg_remove() {
    local pm=$1
    local pkg=$2
    case $pm in
        opkg)
            opkg remove "$pkg" 2>/dev/null
            ;;
        apk)
            apk del "$pkg" 2>/dev/null
            ;;
        apt)
            apt remove -y "$pkg" 2>/dev/null
            ;;
        yum|dnf)
            $pm remove -y "$pkg" 2>/dev/null
            ;;
        *)
            error "Неизвестный пакетный менеджер: $pm"
            ;;
    esac
}

pkg_install() {
    local pm=$1
    local pkg=$2
    case $pm in
        opkg)
            opkg install "$pkg"
            ;;
        apk)
            apk add "$pkg"
            ;;
        apt)
            apt install -y "$pkg"
            ;;
        yum|dnf)
            $pm install -y "$pkg"
            ;;
        *)
            error "Неизвестный пакетный менеджер: $pm"
            ;;
    esac
}

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

# Определяем пакетный менеджер
PACKAGE_MANAGER=$(detect_package_manager)
log "Обнаружен пакетный менеджер: $PACKAGE_MANAGER"

if [ "$PACKAGE_MANAGER" = "unknown" ]; then
    error "Не удалось определить пакетный менеджер. Поддерживаются: opkg, apk, apt, yum, dnf"
fi

log "Начало настройки ZeroTier с пользовательским planet"

# Остановить сервис
log "Остановка сервиса..."
/etc/init.d/zerotier stop 2>/dev/null
killall zerotier-one 2>/dev/null
sleep 2

# Удалить пакет
log "Удаление пакета zerotier..."
pkg_remove "$PACKAGE_MANAGER" zerotier

# Удалить все папки с конфигурациями
log "Удаление старых конфигураций..."
for path in $ZT_OLD_PATHS; do
    rm -rf $path 2>/dev/null
    log "  Удалено: $path"
done
rm -f /etc/init.d/zerotier
rm -f $ZT_UCI_CONFIG 2>/dev/null

# Удалить из UCI network
if command -v uci >/dev/null 2>&1; then
    uci delete network.zerotier 2>/dev/null
    uci commit network 2>/dev/null
else
    log "UCI не найден (возможно не OpenWrt), пропускаем настройку network"
fi

# Удалить правила форвардинга (динамически, без ограничения по индексам)
if command -v uci >/dev/null 2>&1; then
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

    uci commit firewall 2>/dev/null
    log "Firewall очищен"
else
    log "UCI не найден, пропускаем настройку firewall"
fi

# Обновить списки пакетов
log "Обновление репозиториев..."
pkg_update "$PACKAGE_MANAGER" || error "Не удалось обновить репозитории"

# Установить ZeroTier
log "Установка ZeroTier..."
pkg_install "$PACKAGE_MANAGER" zerotier || error "Не удалось установить zerotier"

# Создать папку для постоянного хранения
log "Создание конфигурационной директории: $ZT_CONFIG_PATH"
mkdir -p "$ZT_CONFIG_PATH"

# Удалить опасную строку rm -rf из init.d скрипта
log "Патчинг /etc/init.d/zerotier (меняем rm -rf на echo)..."
if [ -f /etc/init.d/zerotier ]; then
    sed -i 's/rm -rf "${CONFIG_PATH}"/echo "rm -rf ${CONFIG_PATH}"/' /etc/init.d/zerotier
    success "Заменили rm -rf на echo в init.d"
else
    log "Файл /etc/init.d/zerotier не найден"
fi

# Скачать пользовательский planet файл
log "Загрузка planet файла из: $ZT_PLANET_URL"
if command -v wget >/dev/null 2>&1; then
    wget -O "$ZT_CONFIG_PATH/planet" "$ZT_PLANET_URL" || error "Не удалось загрузить planet файл"
elif command -v curl >/dev/null 2>&1; then
    curl -L -o "$ZT_CONFIG_PATH/planet" "$ZT_PLANET_URL" || error "Не удалось загрузить planet файл"
else
    error "Не найден ни wget, ни curl. Установите один из них"
fi
chmod 644 "$ZT_CONFIG_PATH/planet"
success "Planet файл установлен"

# Удалить временную папку (если создалась)
rm -rf /var/lib/zerotier-one 2>/dev/null

# Создать чистый конфиг UCI (если есть uci)
if command -v uci >/dev/null 2>&1; then
    log "Создание UCI конфигурации..."
    cat > $ZT_UCI_CONFIG << EOF
config zerotier 'global'
	option enabled '1'
	option port '$ZT_PORT'
	option config_path '$ZT_CONFIG_PATH'
EOF
    success "UCI конфигурация создана"
else
    # Создаем конфиг вручную для систем без UCI
    log "UCI не найден, создаем конфиг вручную..."
    mkdir -p /etc/zerotier
    echo "port $ZT_PORT" > /etc/zerotier/local.conf
    echo "config_path $ZT_CONFIG_PATH" >> /etc/zerotier/local.conf
fi

# Включить автозапуск
log "Настройка автозапуска..."
if [ -f /etc/init.d/zerotier ]; then
    /etc/init.d/zerotier enable
else
    # Для systemd
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable zerotier-one
    fi
fi

# Запустить сервис
log "Запуск сервиса..."
if [ -f /etc/init.d/zerotier ]; then
    /etc/init.d/zerotier start
elif command -v systemctl >/dev/null 2>&1; then
    systemctl start zerotier-one
else
    # Прямой запуск
    zerotier-one -d -p $ZT_CONFIG_PATH
fi
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

# Настройка сети и файрвола только если есть uci (OpenWrt)
if command -v uci >/dev/null 2>&1; then
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
        log "Интерфейс ZeroTier не найден (возможно еще не создан)"
    fi
else
    log "UCI не найден, настройка сети и файрвола пропущена"
    
    # Альтернативная настройка через iptables
    if command -v iptables >/dev/null 2>&1; then
        ZT_DEV=$(ip link show | grep -o 'zt[^:]*' | head -1)
        if [ -n "$ZT_DEV" ]; then
            iptables -I INPUT -i $ZT_DEV -j ACCEPT
            iptables -I FORWARD -i $ZT_DEV -j ACCEPT
            iptables -I FORWARD -o $ZT_DEV -j ACCEPT
            # Сохраняем правила
            if command -v iptables-save >/dev/null 2>&1; then
                iptables-save > /etc/iptables.rules
            fi
            success "Правила iptables добавлены"
        fi
    fi
fi

# Добавить в автозагрузку (rc.local)
if [ -f /etc/rc.local ]; then
    if ! grep -q "zerotier-cli join $ZT_NETWORK_ID" /etc/rc.local; then
        log "Добавление в rc.local..."
        sed -i '/exit 0/d' /etc/rc.local
        echo "sleep $ZT_RC_LOCAL_DELAY" >> /etc/rc.local
        echo "zerotier-cli join $ZT_NETWORK_ID" >> /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        success "Добавлено в автозагрузку"
    fi
else
    # Если rc.local не существует, создаем
    echo "#!/bin/sh" > /etc/rc.local
    echo "sleep $ZT_RC_LOCAL_DELAY" >> /etc/rc.local
    echo "zerotier-cli join $ZT_NETWORK_ID" >> /etc/rc.local
    echo "exit 0" >> /etc/rc.local
    chmod +x /etc/rc.local
    success "Создан rc.local с автозагрузкой"
fi

# Финальная проверка
log "=========================================="
log "Финальная проверка:"
zerotier-cli listnetworks

success "Настройка ZeroTier завершена!"
log "=========================================="
log "Пакетный менеджер: $PACKAGE_MANAGER"
log "Сеть: $ZT_NETWORK_ID"
log "Конфигурация: $ZT_CONFIG_PATH"
log "Planet файл: $ZT_PLANET_URL"
log "=========================================="
log "ВАЖНО: После перезагрузки проверьте"
log "работу командой: zerotier-cli listnetworks"
log "=========================================="
rm -f /root/ZT.sh
