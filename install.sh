#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}🚀 MTProxy Web Manager Installer${NC}"
echo -e "${GREEN}========================================${NC}"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Пожалуйста, запустите с root правами${NC}"
    echo -e "${YELLOW}   sudo bash install.sh${NC}"
    exit 1
fi

# Получаем IP сервера
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s icanhazip.com)
fi

echo -e "${GREEN}✅ IP сервера: ${SERVER_IP}${NC}"

# Шаг 1: Обновление системы
echo -e "\n${BLUE}[1/8]${NC} ${YELLOW}Обновление системы...${NC}"
apt update && apt upgrade -y
apt install -y git curl build-essential libssl-dev zlib1g-dev python3-pip python3-venv iptables-persistent net-tools

# Шаг 2: Установка MTProxy
echo -e "\n${BLUE}[2/8]${NC} ${YELLOW}Установка MTProxy (GetPageSpeed форк)...${NC}"
cd /opt
rm -rf MTProxy 2>/dev/null
git clone https://github.com/GetPageSpeed/MTProxy.git
cd MTProxy
sed -i 's/COMMON_CFLAGS =/COMMON_CFLAGS = -fcommon/' Makefile
sed -i 's/COMMON_LDFLAGS =/COMMON_LDFLAGS = -fcommon/' Makefile
make
mkdir -p /opt/MTProxy
cp objs/bin/mtproto-proxy /opt/MTProxy/
cd /opt/MTProxy
curl -s https://core.telegram.org/getProxySecret -o proxy-secret
curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf
chmod +x mtproto-proxy

# Шаг 3: Создание systemd сервиса для прокси
echo -e "\n${BLUE}[3/8]${NC} ${YELLOW}Создание systemd сервиса для прокси...${NC}"
cat > /etc/systemd/system/mtproxy.service << 'EOF'
[Unit]
Description=MTProxy (GetPageSpeed Fork) with Fake-TLS
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=/opt/MTProxy
ExecStart=/opt/MTProxy/mtproto-proxy -u nobody -p 8888 -H 9443 -D www.google.com --aes-pwd proxy-secret proxy-multi.conf -M 1
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtproxy
systemctl start mtproxy

# Шаг 4: Настройка iptables
echo -e "\n${BLUE}[4/8]${NC} ${YELLOW}Настройка iptables...${NC}"
# Сохраняем текущие правила если есть
iptables-save > /tmp/iptables-backup 2>/dev/null
# Открываем порты
iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
iptables -A INPUT -p tcp --dport 9443 -j ACCEPT 2>/dev/null || true
iptables -A INPUT -p tcp --dport 5000 -j ACCEPT 2>/dev/null || true
# Сохраняем
DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent 2>/dev/null || true
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# Шаг 5: Установка веб-интерфейса
echo -e "\n${BLUE}[5/8]${NC} ${YELLOW}Установка веб-интерфейса...${NC}"
mkdir -p /opt/mtproxy-web/templates
cd /opt/mtproxy-web
python3 -m venv venv
source venv/bin/activate
pip install flask werkzeug --quiet
deactivate

# Шаг 6: Создание файлов приложения
echo -e "\n${BLUE}[6/8]${NC} ${YELLOW}Создание файлов приложения...${NC}"

# app.py
cat > /opt/mtproxy-web/app.py << 'APPEOF'
#!/usr/bin/env python3
import sqlite3
import subprocess
import os
import re
import time
import threading
from datetime import datetime
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify, session
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.secret_key = os.urandom(24)

DB_PATH = '/opt/mtproxy-web/users.db'
SERVICE_FILE = '/etc/systemd/system/mtproxy.service'
FAKE_DOMAIN = 'www.google.com'
PORT = 9443

ADMIN_PASS_FILE = '/opt/mtproxy-web/admin.hash'

def get_admin_password_hash():
    if os.path.exists(ADMIN_PASS_FILE):
        with open(ADMIN_PASS_FILE, 'r') as f:
            return f.read().strip()
    else:
        default_hash = generate_password_hash('admin123')
        with open(ADMIN_PASS_FILE, 'w') as f:
            f.write(default_hash)
        return default_hash

def set_admin_password(new_password):
    new_hash = generate_password_hash(new_password)
    with open(ADMIN_PASS_FILE, 'w') as f:
        f.write(new_hash)
    return True

def verify_admin_password(password):
    return check_password_hash(get_admin_password_hash(), password)

def login_required(f):
    from functools import wraps
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        if username == 'admin' and verify_admin_password(password):
            session['logged_in'] = True
            session['username'] = username
            flash('✅ Успешный вход', 'success')
            return redirect(url_for('index'))
        else:
            flash('❌ Неверный логин или пароль', 'error')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.clear()
    flash('✅ Вы вышли из системы', 'success')
    return redirect(url_for('login'))

@app.route('/change_password', methods=['GET', 'POST'])
@login_required
def change_password():
    if request.method == 'POST':
        old_password = request.form.get('old_password')
        new_password = request.form.get('new_password')
        confirm_password = request.form.get('confirm_password')
        
        if not verify_admin_password(old_password):
            flash('❌ Текущий пароль неверен', 'error')
            return redirect(url_for('change_password'))
        
        if len(new_password) < 4:
            flash('❌ Новый пароль должен быть не менее 4 символов', 'error')
            return redirect(url_for('change_password'))
        
        if new_password != confirm_password:
            flash('❌ Новый пароль и подтверждение не совпадают', 'error')
            return redirect(url_for('change_password'))
        
        set_admin_password(new_password)
        flash('✅ Пароль успешно изменён!', 'success')
        return redirect(url_for('change_password'))
    
    return render_template('change_password.html')

def get_server_ip():
    try:
        result = subprocess.run(['curl', '-s', 'ifconfig.me'], capture_output=True, text=True, timeout=5)
        return result.stdout.strip() if result.stdout else '127.0.0.1'
    except:
        return '127.0.0.1'

def generate_secret():
    result = subprocess.run(['head', '-c', '16', '/dev/urandom'], capture_output=True)
    return result.stdout.hex()

def generate_client_secret(server_secret):
    domain_hex = subprocess.run(['echo', '-n', FAKE_DOMAIN], capture_output=True, text=True)
    hex_result = subprocess.run(['xxd', '-plain'], input=domain_hex.stdout, capture_output=True, text=True)
    return f"ee{server_secret}{hex_result.stdout.strip()}"

def generate_link(client_secret):
    server_ip = get_server_ip()
    return f"tg://proxy?server={server_ip}&port={PORT}&secret={client_secret}"

def update_service_with_secrets():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT server_secret FROM users WHERE active = 1")
    active_secrets = [row[0] for row in c.fetchall()]
    conn.close()
    
    if not os.path.exists(SERVICE_FILE):
        return False
    
    with open(SERVICE_FILE, 'r') as f:
        content = f.read()
    
    exec_start = f"/opt/MTProxy/mtproto-proxy -u nobody -p 8888 -H {PORT}"
    for secret in active_secrets:
        exec_start += f" -S {secret}"
    exec_start += f" -D {FAKE_DOMAIN} --aes-pwd proxy-secret proxy-multi.conf -M 1"
    
    new_content = re.sub(r'ExecStart=.*', f'ExecStart={exec_start}', content)
    
    with open(SERVICE_FILE, 'w') as f:
        f.write(new_content)
    
    subprocess.run(['systemctl', 'daemon-reload'])
    subprocess.run(['systemctl', 'restart', 'mtproxy'])
    return True

def format_bytes(bytes_val):
    if bytes_val >= 1024**3:
        return f"{bytes_val / 1024**3:.2f} GB"
    elif bytes_val >= 1024**2:
        return f"{bytes_val / 1024**2:.2f} MB"
    elif bytes_val >= 1024:
        return f"{bytes_val / 1024:.2f} KB"
    else:
        return f"{bytes_val} B"

def get_proxy_stats():
    try:
        result = subprocess.run(['curl', '-s', 'http://localhost:8888/stats'], capture_output=True, text=True, timeout=5)
        output = result.stdout
        stats = {'total_bytes': 0, 'clients': 0, 'uptime': 0}
        for line in output.split('\n'):
            if 'bytes' in line.lower():
                match = re.search(r'(\d+\.?\d*)\s*(?:GB|MB|KB)', line)
                if match:
                    val = float(match.group(1))
                    if 'GB' in line:
                        stats['total_bytes'] = int(val * 1024**3)
                    elif 'MB' in line:
                        stats['total_bytes'] = int(val * 1024**2)
                    elif 'KB' in line:
                        stats['total_bytes'] = int(val * 1024)
            elif 'clients' in line.lower():
                match = re.search(r'(\d+)', line)
                if match:
                    stats['clients'] = int(match.group(1))
        return stats
    except:
        return {'total_bytes': 0, 'clients': 0, 'uptime': 0}

def monitor_traffic():
    last_total = 0
    while True:
        time.sleep(60)
        stats = get_proxy_stats()
        current_total = stats['total_bytes']
        if current_total > last_total:
            delta = current_total - last_total
            conn = sqlite3.connect(DB_PATH)
            c = conn.cursor()
            c.execute("SELECT id FROM users WHERE active = 1")
            active_users = c.fetchall()
            conn.close()
            if active_users:
                per_user = delta // len(active_users)
                conn = sqlite3.connect(DB_PATH)
                c = conn.cursor()
                c.execute(f"UPDATE users SET total_bytes = total_bytes + {per_user} WHERE active = 1")
                c.execute("UPDATE users SET last_seen = CURRENT_TIMESTAMP WHERE active = 1")
                conn.commit()
                conn.close()
        last_total = current_total

threading.Thread(target=monitor_traffic, daemon=True).start()

@app.route('/')
@login_required
def index():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT id, name, client_secret, link, active, created_at, last_seen, total_bytes, notes FROM users ORDER BY created_at DESC")
    users = []
    for row in c.fetchall():
        user = list(row)
        user[7] = format_bytes(user[7] or 0)
        if user[6]:
            try:
                dt = datetime.strptime(user[6], '%Y-%m-%d %H:%M:%S')
                user[6] = dt.strftime('%d.%m.%Y %H:%M')
            except:
                user[6] = user[6][:16] if user[6] else 'никогда'
        else:
            user[6] = 'никогда'
        users.append(user)
    conn.close()
    proxy_stats = get_proxy_stats()
    proxy_stats['total_bytes_fmt'] = format_bytes(proxy_stats['total_bytes'])
    return render_template('index.html', users=users, server_ip=get_server_ip(), port=PORT, proxy_stats=proxy_stats)

@app.route('/add', methods=['POST'])
@login_required
def add_user():
    name = request.form.get('name')
    notes = request.form.get('notes', '')
    if not name:
        flash('Имя сотрудника обязательно', 'error')
        return redirect(url_for('index'))
    server_secret = generate_secret()
    client_secret = generate_client_secret(server_secret)
    link = generate_link(client_secret)
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("INSERT INTO users (name, server_secret, client_secret, link, active, notes) VALUES (?, ?, ?, ?, 1, ?)",
              (name, server_secret, client_secret, link, notes))
    conn.commit()
    conn.close()
    update_service_with_secrets()
    flash(f'✅ Сотрудник {name} добавлен', 'success')
    return redirect(url_for('index'))

@app.route('/toggle/<int:user_id>')
@login_required
def toggle_user(user_id):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT active, name FROM users WHERE id = ?", (user_id,))
    current = c.fetchone()
    if current:
        new_status = 0 if current[0] else 1
        c.execute("UPDATE users SET active = ? WHERE id = ?", (new_status, user_id))
        conn.commit()
        update_service_with_secrets()
        flash(f'{"🟢 Включён" if new_status else "🔴 Отключён"} сотрудник {current[1]}', 'success')
    conn.close()
    return redirect(url_for('index'))

@app.route('/delete/<int:user_id>')
@login_required
def delete_user(user_id):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT name FROM users WHERE id = ?", (user_id,))
    user = c.fetchone()
    if user:
        c.execute("DELETE FROM users WHERE id = ?", (user_id,))
        conn.commit()
        flash(f'🗑 Удалён сотрудник {user[0]}', 'success')
        update_service_with_secrets()
    conn.close()
    return redirect(url_for('index'))

@app.route('/refresh')
@login_required
def refresh_service():
    if update_service_with_secrets():
        flash('🔄 Сервис прокси перезапущен', 'success')
    else:
        flash('❌ Нет активных пользователей или ошибка', 'error')
    return redirect(url_for('index'))

@app.route('/stats')
@login_required
def stats():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT COUNT(*) FROM users")
    total = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM users WHERE active = 1")
    active = c.fetchone()[0]
    c.execute("SELECT SUM(total_bytes) FROM users")
    total_bytes = c.fetchone()[0] or 0
    conn.close()
    proxy_stats = get_proxy_stats()
    return render_template('stats.html', total=total, active=active, total_bytes=format_bytes(total_bytes), proxy_stats=proxy_stats, proxy_total_bytes=format_bytes(proxy_stats['total_bytes']), clients=proxy_stats['clients'], uptime=proxy_stats['uptime'])

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
APPEOF

# login.html
cat > /opt/mtproxy-web/templates/login.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Вход - MTProxy Manager</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
        .card{background:#fff;border-radius:16px;padding:40px;width:100%;max-width:400px;box-shadow:0 20px 40px rgba(0,0,0,0.1)}
        h1{text-align:center;margin-bottom:30px;color:#333}
        .form-group{margin-bottom:20px}
        label{display:block;margin-bottom:8px;font-weight:600;color:#555}
        input{width:100%;padding:12px;border:1px solid #ddd;border-radius:8px;font-size:16px}
        input:focus{outline:none;border-color:#667eea}
        button{width:100%;padding:12px;background:#667eea;color:#fff;border:none;border-radius:8px;font-size:16px;cursor:pointer;font-weight:600}
        button:hover{background:#5a67d8}
        .flash{padding:12px;border-radius:8px;margin-bottom:20px}
        .flash.success{background:#d4edda;color:#155724;border:1px solid #c3e6cb}
        .flash.error{background:#f8d7da;color:#721c24;border:1px solid #f5c6cb}
    </style>
</head>
<body>
    <div class="card">
        <h1>🔐 Вход в систему</h1>
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="flash {{ category }}">{{ message }}</div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        <form method="POST">
            <div class="form-group">
                <label>Логин</label>
                <input type="text" name="username" required autofocus>
            </div>
            <div class="form-group">
                <label>Пароль</label>
                <input type="password" name="password" required>
            </div>
            <button type="submit">Войти</button>
        </form>
    </div>
</body>
</html>
HTMLEOF

# change_password.html
cat > /opt/mtproxy-web/templates/change_password.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Смена пароля - MTProxy Manager</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f0f2f5;padding:20px}
        .container{max-width:500px;margin:50px auto}
        .card{background:#fff;border-radius:16px;padding:30px;box-shadow:0 2px 10px rgba(0,0,0,0.1)}
        h2{text-align:center;margin-bottom:25px;color:#333}
        .form-group{margin-bottom:20px}
        label{display:block;margin-bottom:8px;font-weight:600;color:#555}
        input{width:100%;padding:12px;border:1px solid #ddd;border-radius:8px;font-size:14px}
        input:focus{outline:none;border-color:#667eea}
        button,.btn{background:#667eea;color:#fff;border:none;padding:12px 20px;border-radius:8px;cursor:pointer;font-size:14px;text-decoration:none;display:inline-block}
        button:hover,.btn:hover{background:#5a67d8}
        .btn-secondary{background:#718096}
        .btn-secondary:hover{background:#4a5568}
        .flash{padding:12px;border-radius:8px;margin-bottom:20px}
        .flash.success{background:#d4edda;color:#155724;border:1px solid #c3e6cb}
        .flash.error{background:#f8d7da;color:#721c24;border:1px solid #f5c6cb}
        .actions{display:flex;gap:15px;justify-content:center;margin-top:10px}
        .info{background:#e6f7ff;padding:15px;border-radius:8px;margin-bottom:20px;color:#0050b3;font-size:14px}
    </style>
</head>
<body>
    <div class="container">
        <div class="card">
            <h2>🔐 Смена пароля</h2>
            {% with messages = get_flashed_messages(with_categories=true) %}
                {% if messages %}
                    {% for category, message in messages %}
                        <div class="flash {{ category }}">{{ message }}</div>
                    {% endfor %}
                {% endif %}
            {% endwith %}
            <div class="info">⚠️ После смены пароля используйте новый пароль при следующем входе.</div>
            <form method="POST">
                <div class="form-group">
                    <label>Текущий пароль</label>
                    <input type="password" name="old_password" required autofocus>
                </div>
                <div class="form-group">
                    <label>Новый пароль (мин. 4 символа)</label>
                    <input type="password" name="new_password" required>
                </div>
                <div class="form-group">
                    <label>Подтверждение пароля</label>
                    <input type="password" name="confirm_password" required>
                </div>
                <div class="actions">
                    <button type="submit">✅ Сменить пароль</button>
                    <a href="/" class="btn btn-secondary">↩️ На главную</a>
                </div>
            </form>
        </div>
    </div>
</body>
</html>
HTMLEOF

# index.html
cat > /opt/mtproxy-web/templates/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MTProxy Manager - Управление сотрудниками</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f0f2f5;padding:20px}
        .container{max-width:1400px;margin:0 auto}
        .header{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:#fff;padding:20px;border-radius:16px;margin-bottom:20px}
        .header h1{margin-bottom:10px}
        .header p{opacity:0.9;font-size:14px}
        .navbar{display:flex;gap:15px;flex-wrap:wrap;margin-top:15px}
        .navbar a{color:#fff;text-decoration:none;padding:5px 12px;border-radius:8px;background:rgba(255,255,255,0.1);transition:0.2s}
        .navbar a:hover{background:rgba(255,255,255,0.2)}
        .card{background:#fff;border-radius:16px;padding:20px;margin-bottom:20px;box-shadow:0 2px 8px rgba(0,0,0,0.1)}
        .form-group{margin-bottom:15px}
        label{display:block;margin-bottom:5px;font-weight:600;color:#333}
        input[type="text"],textarea{width:100%;padding:10px;border:1px solid #ddd;border-radius:8px;font-size:14px}
        button,.btn{background:#667eea;color:#fff;border:none;padding:10px 20px;border-radius:8px;cursor:pointer;font-size:14px;text-decoration:none;display:inline-block}
        button:hover,.btn:hover{background:#5a67d8}
        .btn-danger{background:#e53e3e}
        .btn-danger:hover{background:#c53030}
        .btn-sm{padding:4px 10px;font-size:12px}
        table{width:100%;border-collapse:collapse}
        th,td{padding:12px;text-align:left;border-bottom:1px solid #eee}
        th{background:#f7f7f7;font-weight:600}
        .status-active{color:#48bb78;font-weight:bold}
        .status-inactive{color:#e53e3e;font-weight:bold}
        .link{font-family:monospace;font-size:12px;word-break:break-all;background:#f7f7f7;padding:5px;border-radius:6px}
        .copy-btn{background:#718096;padding:2px 8px;font-size:11px;margin-left:5px;border:none;border-radius:4px;color:#fff;cursor:pointer}
        .flash{padding:12px;border-radius:8px;margin-bottom:15px}
        .flash.success{background:#d4edda;color:#155724;border:1px solid #c3e6cb}
        .flash.error{background:#f8d7da;color:#721c24;border:1px solid #f5c6cb}
        .actions a{margin-right:8px}
        .stats-grid{display:flex;gap:20px;margin-bottom:20px;flex-wrap:wrap}
        .stat-card{background:#fff;padding:15px;border-radius:16px;flex:1;min-width:120px;text-align:center;box-shadow:0 2px 8px rgba(0,0,0,0.1)}
        .stat-card h3{font-size:28px;color:#667eea}
        .traffic-cell{font-family:monospace;font-weight:bold;color:#2c7a4a}
        @media(max-width:768px){table,thead,tbody,th,td,tr{display:block}th{display:none}td{border:none;margin-bottom:5px}}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 MTProxy Manager</h1>
            <p>Сервер: {{ server_ip }}:{{ port }} | Fake-TLS: www.google.com</p>
            <div class="navbar">
                <a href="/">👥 Пользователи</a>
                <a href="/stats">📊 Статистика</a>
                <a href="/refresh">🔄 Перезапустить прокси</a>
                <a href="/change_password">🔑 Сменить пароль</a>
                <a href="/logout">🚪 Выход</a>
            </div>
        </div>

        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="flash {{ category }}">{{ message }}</div>
                {% endfor %}
            {% endif %}
        {% endwith %}

        <div class="stats-grid">
            <div class="stat-card"><h3>{{ users|length }}</h3><p>Всего сотрудников</p></div>
            <div class="stat-card"><h3>{{ users|selectattr('4', 'equalto', 1)|list|length }}</h3><p>Активных</p></div>
            <div class="stat-card"><h3>{{ proxy_stats.total_bytes_fmt }}</h3><p>Общий трафик</p></div>
        </div>

        <div class="card">
            <h2>➕ Добавить сотрудника</h2>
            <form method="POST" action="/add">
                <div class="form-group">
                    <label>Имя сотрудника</label>
                    <input type="text" name="name" required placeholder="Например: Иван Петров">
                </div>
                <div class="form-group">
                    <label>Примечание (отдел, должность)</label>
                    <textarea name="notes" rows="2" placeholder="Необязательно"></textarea>
                </div>
                <button type="submit">➕ Добавить</button>
            </form>
        </div>

        <div class="card">
            <h2>👥 Список сотрудников</h2>
            {% if users %}
            <table>
                <thead><tr><th>ID</th><th>Имя</th><th>Примечание</th><th>Ссылка</th><th>Статус</th><th>📊 Трафик</th><th>Активность</th><th>Действия</th></tr></thead>
                <tbody>
                    {% for user in users %}
                    <tr>
                        <td>{{ user[0] }}</td>
                        <td><strong>{{ user[1] }}</strong></td>
                        <td>{{ user[8] or '-' }}</td>
                        <td><div class="link">{{ user[2] }}</div><button class="copy-btn" onclick="copyToClipboard('{{ user[3] }}')">📋 Копировать</button></td>
                        <td>{% if user[4] == 1 %}<span class="status-active">✅ Активен</span>{% else %}<span class="status-inactive">❌ Отключён</span>{% endif %}</td>
                        <td class="traffic-cell">{{ user[7] }}</td>
                        <td>{{ user[6] or 'никогда' }}</td>
                        <td class="actions">
                            <a href="/toggle/{{ user[0] }}" class="btn btn-sm">{% if user[4] == 1 %}🔴 Отключить{% else %}🟢 Включить{% endif %}</a>
                            <a href="/delete/{{ user[0] }}" class="btn btn-danger btn-sm" onclick="return confirm('Удалить {{ user[1] }}?')">🗑 Удалить</a>
                        </td>
                    </tr>
                    {% endfor %}
                </tbody>
            </table>
            {% else %}
            <p>Нет сотрудников. Добавьте первого!</p>
            {% endif %}
        </div>
    </div>
    <script>function copyToClipboard(text){navigator.clipboard.writeText(text);alert('Ссылка скопирована!');}</script>
</body>
</html>
HTMLEOF

# stats.html
cat > /opt/mtproxy-web/templates/stats.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Статистика - MTProxy Manager</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f0f2f5;padding:20px}
        .container{max-width:1200px;margin:0 auto}
        .header{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:#fff;padding:20px;border-radius:16px;margin-bottom:20px}
        .header a{color:#fff;text-decoration:none;margin-right:15px;padding:5px 12px;background:rgba(255,255,255,0.1);border-radius:8px;display:inline-block}
        .header a:hover{background:rgba(255,255,255,0.2)}
        .card{background:#fff;border-radius:16px;padding:20px;margin-bottom:20px;box-shadow:0 2px 8px rgba(0,0,0,0.1)}
        pre{background:#2d3748;color:#e2e8f0;padding:15px;border-radius:8px;overflow-x:auto;font-size:12px;font-family:monospace}
        .stats-grid{display:flex;gap:20px;margin-bottom:20px;flex-wrap:wrap}
        .stat-card{background:#fff;padding:20px;border-radius:16px;flex:1;min-width:150px;text-align:center;box-shadow:0 2px 8px rgba(0,0,0,0.1)}
        .stat-card h3{font-size:32px;color:#667eea;margin-bottom:5px}
        .stat-card p{color:#666;font-size:14px}
        .stat-card small{color:#999;font-size:12px}
        .navbar{display:flex;gap:10px;flex-wrap:wrap;margin-top:10px}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📊 Детальная статистика</h1>
            <div class="navbar">
                <a href="/">← На главную</a>
                <a href="/refresh">🔄 Перезапустить прокси</a>
                <a href="/change_password">🔑 Сменить пароль</a>
                <a href="/logout">🚪 Выход</a>
            </div>
        </div>

        <div class="stats-grid">
            <div class="stat-card"><h3>{{ total }}</h3><p>Всего сотрудников</p></div>
            <div class="stat-card"><h3>{{ active }}</h3><p>Активных</p></div>
            <div class="stat-card"><h3>{{ total_bytes }}</h3><p>Трафик (оценка)</p><small>Равномерное распределение</small></div>
            <div class="stat-card"><h3>{{ proxy_total_bytes }}</h3><p>Общий трафик</p><small>Реальные данные</small></div>
            <div class="stat-card"><h3>{{ clients }}</h3><p>Текущих подключений</p></div>
        </div>

        <div class="card">
            <h3>📡 Статистика прокси (localhost:8888/stats)</h3>
            <pre>{{ proxy_stats }}</pre>
        </div>

        <div class="card">
            <h3>💡 Важно</h3>
            <p>MTProto прокси НЕ умеет разделять трафик по секретам. Трафик каждого пользователя оценивается приблизительно, путём равномерного распределения общего трафика между активными пользователями.</p>
            <p>Для точного учёта трафика каждому пользователю нужно запускать отдельный экземпляр прокси на своём порту.</p>
        </div>
    </div>
</body>
</html>
HTMLEOF

# Создаем базу данных
echo -e "\n${BLUE}[7/8]${NC} ${YELLOW}Создание базы данных...${NC}"
cat > /opt/mtproxy-web/init_db.py << 'EOF'
import sqlite3
conn = sqlite3.connect('/opt/mtproxy-web/users.db')
c = conn.cursor()
c.execute('''CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    server_secret TEXT NOT NULL,
    client_secret TEXT NOT NULL,
    link TEXT NOT NULL,
    active INTEGER DEFAULT 1,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen TIMESTAMP,
    total_bytes INTEGER DEFAULT 0,
    notes TEXT
)''')
conn.commit()
conn.close()
EOF

cd /opt/mtproxy-web
source venv/bin/activate
python3 init_db.py
deactivate
rm -f init_db.py

# Создаем пароль администратора
python3 -c "
from werkzeug.security import generate_password_hash
with open('/opt/mtproxy-web/admin.hash', 'w') as f:
    f.write(generate_password_hash('admin123'))
" 2>/dev/null || echo "admin123" > /opt/mtproxy-web/admin.hash

# Шаг 8: Создание systemd сервиса для веб-интерфейса
echo -e "\n${BLUE}[8/8]${NC} ${YELLOW}Создание systemd сервиса для веб-интерфейса...${NC}"
cat > /etc/systemd/system/mtproxy-web.service << 'EOF'
[Unit]
Description=MTProxy Web Interface
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/mtproxy-web
ExecStart=/opt/mtproxy-web/venv/bin/python /opt/mtproxy-web/app.py
Restart=always
User=root
Group=root
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtproxy-web
systemctl start mtproxy-web

# Финальная проверка
echo -e "\n${BLUE}Проверка установки...${NC}"
sleep 3

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✅ УСТАНОВКА ЗАВЕРШЕНА!${NC}"
echo -e "${GREEN}========================================${NC}"

# Проверка статусов
echo -e "\n${BLUE}Статус прокси:${NC}"
systemctl is-active mtproxy && echo -e "${GREEN}  ✅ mtproxy активен${NC}" || echo -e "${RED}  ❌ mtproxy не активен${NC}"

echo -e "\n${BLUE}Статус веб-интерфейса:${NC}"
systemctl is-active mtproxy-web && echo -e "${GREEN}  ✅ mtproxy-web активен${NC}" || echo -e "${RED}  ❌ mtproxy-web не активен${NC}"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}🌐 ВЕБ-ИНТЕРФЕЙС:${NC}"
echo -e "   http://${SERVER_IP}:5000"
echo -e "\n${GREEN}🔑 ДАННЫЕ ДЛЯ ВХОДА:${NC}"
echo -e "   Логин: ${YELLOW}admin${NC}"
echo -e "   Пароль: ${YELLOW}admin123${NC}"
echo -e "\n${RED}⚠️  ВАЖНО: Сразу смените пароль в веб-интерфейсе!${NC}"
echo -e "\n${GREEN}📝 ПОЛЕЗНЫЕ КОМАНДЫ:${NC}"
echo -e "   systemctl status mtproxy       # статус прокси"
echo -e "   systemctl status mtproxy-web   # статус веб-интерфейса"
echo -e "   journalctl -u mtproxy -f       # логи прокси"
echo -e "   journalctl -u mtproxy-web -f   # логи веб-интерфейса"
echo -e "   curl http://localhost:8888/stats # статистика прокси"
echo -e "\n${GREEN}========================================${NC}"
