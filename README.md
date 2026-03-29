# MTProxyWebManager
Полноценный веб-интерфейс для управления MTProto прокси с Fake-TLS поддержкой

 Возможности
Установка MTProxy (форк GetPageSpeed) с Fake-TLS маскировкой

Веб-интерфейс для управления сотрудниками

Создание ee-ссылок для Telegram

Включение/отключение доступа сотрудников

Оценочная статистика трафика

Смена пароля администратора

Автоматическое обновление конфигурации прокси

Работает без Docker

📋 Требования
VPS/VDS с Ubuntu 22.04

Минимум 1 GB RAM

Root доступ

В проекте используется порт TCP 9443 для прокси. Его можно сменить на свой.

Установка: 

curl -sSL https://github.com/soloveyplus/MTProxyWebManager/blob/main/install.sh | sudo bash

или

wget -qO- https://github.com/soloveyplus/MTProxyWebManager/blob/main/install.sh | sudo bash

После установки
Откройте браузер и перейдите по адресу:

http://IP_ВАШЕГО_СЕРВЕРА:5000
Данные для входа:

Логин: admin
Пароль: admin123
⚠️ ВНИМАНИЕ! Сразу смените пароль администратора в веб-интерфейсе!
