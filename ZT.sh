#!/bin/sh
# Остановить сервис
/etc/init.d/zerotier stop 2>/dev/null
killall zerotier-one 2>/dev/null
sleep 2

# Удалить пакет
apk del zerotier

# Удалить все папки с конфигурациями
rm -rf /var/lib/zerotier-one
rm -rf /var/lib/zerotier-luci
rm -rf /etc/zerotier
rm -f /etc/config/zerotier
rm -rf /tmp/zerotier-*

uci delete network.zerotier 2>/dev/null
uci commit network

# Удалить правила форвардинга (обычно их 3)
for i in $(seq 0 10); do
    if uci get firewall.@forwarding[$i] 2>/dev/null | grep -q "src='vpn'"; then
        uci delete firewall.@forwarding[$i]
    fi
    if uci get firewall.@forwarding[$i] 2>/dev/null | grep -q "dest='vpn'"; then
        uci delete firewall.@forwarding[$i]
    fi
done

# Удалить саму зону vpn
for i in $(seq 0 10); do
    if uci get firewall.@zone[$i].name 2>/dev/null | grep -q "vpn"; then
        uci delete firewall.@zone[$i]
        break
    fi
done

uci commit firewall

# Обновить списки пакетов
apk update

# Установить ZeroTier
apk add zerotier

# Создать папку для постоянного хранения
mkdir -p /etc/zerotier

# Удалить временную папку (если создалась)
rm -rf /var/lib/zerotier-one

# Создать симлинк на постоянную папку
ln -s /etc/zerotier /var/lib/zerotier-one

# Создать чистый конфиг
cat > /etc/config/zerotier << 'EOF'
config zerotier 'global'
        option enabled '1'
        option port '9993'

config zerotier 'main_network'
        option enabled '1'
        list join 'cf719fd540faee8e'
EOF


# Включить автозапуск
/etc/init.d/zerotier enable

# Запустить сервис
/etc/init.d/zerotier start
sleep 10

# Подождать генерации ключей (10 секунд)


# Проверить статус
zerotier-cli status

zerotier-cli join cf719fd540faee8e
sleep 5

# Проверить статус
zerotier-cli status

# Проверить список сетей


# Найти интерфейс ZeroTier
ZT_DEV=$(ip link show | grep -o 'zt[^:]*' | head -1)

if [ -n "$ZT_DEV" ]; then
    echo "Найден интерфейс: $ZT_DEV"
    
    # Создать интерфейс в UCI
    uci set network.zerotier=interface
    uci set network.zerotier.proto='none'
    uci set network.zerotier.device="$ZT_DEV"
    
    # Создать зону firewall
    uci add firewall zone
    uci set firewall.@zone[-1].name='vpn'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'
    uci set firewall.@zone[-1].masq='1'
    uci add_list firewall.@zone[-1].network='zerotier'
    
    # Правила форвардинга
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='vpn'
    uci set firewall.@forwarding[-1].dest='lan'
    
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='vpn'
    uci set firewall.@forwarding[-1].dest='wan'
    
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].dest='vpn'
    
    # Применить
    uci commit network
    uci commit firewall
    /etc/init.d/firewall restart
    
    echo "✅ Файрвол настроен"
else
    echo "❌ Интерфейс всё ещё не создан"
fi

sed -i '/exit 0/i sleep 30\nzerotier-cli join cf719fd540faee8e' /etc/rc.local

zerotier-cli listnetworks
