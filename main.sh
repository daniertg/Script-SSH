#!/bin/bash

# TheorymaVPN SSH Manager untuk Debian 12
# Script Auto untuk Setup SSH Tunneling dan WebSocket

# Warna untuk tampilan lebih baik
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# Cek apakah script dijalankan sebagai root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Script ini harus dijalankan sebagai root${PLAIN}"
    exit 1
fi

# Fungsi untuk menampilkan progress
function show_progress() {
    echo -e "${YELLOW}[+] $1...${PLAIN}"
}

# Fungsi untuk operasi berhasil
function success() {
    echo -e "${GREEN}[✓] $1${PLAIN}"
}

# Fungsi untuk error
function error() {
    echo -e "${RED}[✗] $1${PLAIN}"
    exit 1
}

# Deteksi OS - Khusus untuk Debian 12
show_progress "Mendeteksi sistem operasi"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
    if [[ "$OS" == "debian" ]] && [[ "$VER" == "12" ]]; then
        success "Terdeteksi OS: Debian 12 (Bookworm)"
    else
        error "Script ini khusus untuk Debian 12. Sistem Anda: $OS $VER"
    fi
else
    error "Tidak dapat mendeteksi sistem operasi"
fi

# Fungsi untuk menginstal SSH (otomatis dijalankan di awal)
install_ssh() {
    if [ -f "/etc/ssh/sshd_config" ]; then
        show_progress "OpenSSH Server sudah terinstal"
    else
        show_progress "Memperbarui paket sistem"
        apt-get update -y > /dev/null 2>&1
        apt-get upgrade -y > /dev/null 2>&1
        success "Paket sistem diperbarui"

        show_progress "Menginstall OpenSSH Server"
        apt-get install openssh-server net-tools curl wget -y > /dev/null 2>&1
        success "OpenSSH Server berhasil diinstall"

        show_progress "Mengkonfigurasi SSH server untuk tunneling"
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        sed -i 's/#PermitTunnel no/PermitTunnel yes/g' /etc/ssh/sshd_config
        sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
        sed -i 's/#AllowAgentForwarding yes/AllowAgentForwarding yes/g' /etc/ssh/sshd_config
        sed -i 's/#GatewayPorts no/GatewayPorts yes/g' /etc/ssh/sshd_config
        
        # Konfigurasi keamanan dasar
        sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/g' /etc/ssh/sshd_config
        sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' /etc/ssh/sshd_config
        
        # Set port SSH default (22)
        if ! grep -q "^Port" /etc/ssh/sshd_config; then
            echo "Port 22" >> /etc/ssh/sshd_config
        fi
        
        # Restart SSH
        systemctl restart ssh > /dev/null 2>&1
        systemctl enable ssh > /dev/null 2>&1
        success "SSH Server berhasil dikonfigurasi untuk tunneling"
    fi
}

# Fungsi untuk menginstal TLS SSH
install_tls_ssh() {
    show_progress "Menginstal TLS SSH pada port 443"
    
    # Instal stunnel4
    apt-get install stunnel4 -y > /dev/null 2>&1
    
    # Cek apakah stunnel4 sudah terinstal
    if [ ! -f /etc/stunnel/stunnel.conf ]; then
        error "Gagal menginstal stunnel4"
    fi
    
    # Buat sertifikat SSL untuk stunnel
    show_progress "Membuat sertifikat SSL"
    
    # Dapatkan hostname/IP untuk sertifikat
    PUBLIC_IP=$(get_public_ip)
    HOSTNAME=$(hostname)
    
    # Buat direktori untuk sertifikat jika belum ada
    mkdir -p /etc/stunnel/cert
    
    # Buat sertifikat self-signed
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/CN=$PUBLIC_IP" \
        -keyout /etc/stunnel/cert/stunnel.key \
        -out /etc/stunnel/cert/stunnel.crt > /dev/null 2>&1
    
    # Gabung key dan cert untuk stunnel
    cat /etc/stunnel/cert/stunnel.key /etc/stunnel/cert/stunnel.crt > /etc/stunnel/cert/stunnel.pem
    
    # Konfigurasi stunnel untuk TLS SSH
    cat > /etc/stunnel/stunnel.conf << EOF
pid = /var/run/stunnel4/stunnel.pid
cert = /etc/stunnel/cert/stunnel.pem
client = no
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-tls]
accept = 443
connect = 127.0.0.1:22
EOF
    
    # Aktifkan stunnel4
    sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4
    
    # Restart stunnel4
    systemctl restart stunnel4 > /dev/null 2>&1
    systemctl enable stunnel4 > /dev/null 2>&1
    
    # Buka port di firewall
    if command -v ufw &> /dev/null; then
        ufw allow 443/tcp > /dev/null 2>&1
    fi
    
    success "TLS SSH berhasil diinstal dan dikonfigurasi pada port 443"
    
    # Simpan pengaturan
    echo "443" > /etc/theoryma_tls_port
}

# Fungsi untuk menginstal WebSocket
install_websocket() {
    show_progress "Menginstal paket yang diperlukan untuk WebSocket"
    apt-get install -y python3 python3-pip nginx > /dev/null 2>&1
    
    show_progress "Menginstal WebSocketify"
    pip3 install websockify > /dev/null 2>&1
    success "WebSocketify berhasil diinstal"
    
    # Set port WebSocket ke 80 secara default
    WS_PORT=80
    
    # Dapatkan port SSH
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}')
    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT=22
    fi
    
    # Buat service systemd untuk websockify
    show_progress "Membuat service WebSocket"
    cat > /etc/systemd/system/websockify.service << EOF
[Unit]
Description=Websockify Service for SSH
After=network.target

[Service]
ExecStart=/usr/local/bin/websockify --web=/usr/share/nginx/html $WS_PORT localhost:$SSH_PORT
Restart=always
User=root
Group=root
KillMode=process
RestartSec=10
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
EOF
    
    # Hentikan Nginx jika sedang berjalan (untuk mengosongkan port 80)
    systemctl stop nginx > /dev/null 2>&1
    
    # Buka port di firewall
    show_progress "Memperbarui aturan firewall"
    if command -v ufw &> /dev/null; then
        ufw allow $WS_PORT/tcp > /dev/null 2>&1
    fi
    
    # Mulai dan aktifkan service websockify
    show_progress "Memulai service WebSocket di port 80"
    systemctl daemon-reload
    systemctl start websockify
    systemctl enable websockify
    
    success "SSH WebSocket berhasil diinstal dan dikonfigurasi di port $WS_PORT"
    
    # Simpan konfigurasi WebSocket untuk referensi mendatang
    echo "$WS_PORT" > /etc/theoryma_ws_port
    
    # Tekan Enter untuk melanjutkan
    read -n 1 -s -r -p "Tekan sembarang tombol untuk melanjutkan..."
}

# Fungsi untuk mendapatkan IP publik
get_public_ip() {
    # Coba beberapa layanan untuk mendapatkan IP publik
    PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ipinfo.io/ip || curl -s https://ifconfig.me)
    
    # Jika gagal mendapatkan IP publik, gunakan IP lokal
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(ip addr show | grep -E "inet.*brd" | head -n1 | awk '{print $2}' | cut -d '/' -f1)
    fi
    
    echo "$PUBLIC_IP"
}

# Fungsi Menu Utama
show_main_menu() {
    clear
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${GREEN}            THEORYMA VPN SSH MANAGER - DEBIAN 12            ${PLAIN}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${YELLOW}1.${PLAIN} Menu SSH"
    echo -e "${YELLOW}2.${PLAIN} Menu WebSocket"
    echo -e "${YELLOW}3.${PLAIN} Restart Sistem"
    echo -e "${YELLOW}4.${PLAIN} Keluar"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo ""
    read -p "Pilih opsi [1-4]: " main_option
}

# Fungsi Menu SSH
show_ssh_menu() {
    clear
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${GREEN}                      MENU SSH                              ${PLAIN}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${YELLOW}1.${PLAIN} Buat User SSH"
    echo -e "${YELLOW}2.${PLAIN} Hapus User SSH"
    echo -e "${YELLOW}3.${PLAIN} Tampilkan Daftar User SSH"
    echo -e "${YELLOW}4.${PLAIN} Restart Service SSH"
    echo -e "${YELLOW}5.${PLAIN} Instal/Restart TLS SSH (Port 443)"
    echo -e "${YELLOW}6.${PLAIN} Kembali ke Menu Utama"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo ""
    read -p "Pilih opsi [1-6]: " ssh_option
}

# Fungsi Menu WebSocket
show_websocket_menu() {
    clear
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${GREEN}                  MENU SSH WEBSOCKET                        ${PLAIN}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${YELLOW}1.${PLAIN} Buat User WebSocket"
    echo -e "${YELLOW}2.${PLAIN} Hapus User WebSocket"
    echo -e "${YELLOW}3.${PLAIN} Tampilkan Daftar User WebSocket"
    echo -e "${YELLOW}4.${PLAIN} Restart Service WebSocket"
    echo -e "${YELLOW}5.${PLAIN} Kembali ke Menu Utama"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo ""
    read -p "Pilih opsi [1-5]: " websocket_option
}

# Create SSH User Function
create_user() {
    read -p "Masukkan username untuk SSH: " SSH_USER
    read -s -p "Masukkan password untuk $SSH_USER: " SSH_PASSWORD
    echo ""

    useradd -m -s /bin/bash "$SSH_USER" > /dev/null 2>&1
    echo "$SSH_USER:$SSH_PASSWORD" | chpasswd
    success "User SSH $SSH_USER berhasil dibuat"
    
    # Tampilkan informasi koneksi
    IP_ADDRESS=$(get_public_ip)
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}')
    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT=22
    fi
    
    # Cek apakah TLS SSH sudah diinstal
    TLS_PORT=""
    if [ -f /etc/stunnel/stunnel.conf ]; then
        TLS_PORT=$(cat /etc/theoryma_tls_port 2>/dev/null || echo "443")
    fi
    
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${GREEN}           INFORMASI KONEKSI USER SSH BARU                  ${PLAIN}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${YELLOW}Detail Akun:${PLAIN}"
    echo -e "Username    : ${GREEN}$SSH_USER${PLAIN}"
    echo -e "Password    : ${GREEN}$SSH_PASSWORD${PLAIN}"
    echo -e "IP Address  : ${GREEN}$IP_ADDRESS${PLAIN}"
    echo -e "Port SSH    : ${GREEN}$SSH_PORT${PLAIN}"
    if [[ ! -z "$TLS_PORT" ]]; then
        echo -e "Port TLS    : ${GREEN}$TLS_PORT${PLAIN}"
    fi
    echo ""
    echo -e "${YELLOW}Perintah Koneksi SSH:${PLAIN}"
    echo -e "${GREEN}ssh $SSH_USER@$IP_ADDRESS -p $SSH_PORT${PLAIN}"
    echo ""
    if [[ ! -z "$TLS_PORT" ]]; then
        echo -e "${YELLOW}Perintah Koneksi SSH TLS:${PLAIN}"
        echo -e "${GREEN}Gunakan klien SSH dengan dukungan TLS pada port $TLS_PORT${PLAIN}"
    fi
    echo ""
    echo -e "${YELLOW}Perintah Koneksi SOCKS5 Proxy:${PLAIN}"
    echo -e "${GREEN}ssh -D 1080 $SSH_USER@$IP_ADDRESS -p $SSH_PORT${PLAIN}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    
    # Tekan Enter untuk melanjutkan
    read -n 1 -s -r -p "Tekan sembarang tombol untuk melanjutkan..."
}

# Delete SSH User Function
delete_user() {
    read -p "Masukkan username yang akan dihapus: " DEL_USER
    if id "$DEL_USER" &>/dev/null; then
        userdel -r "$DEL_USER" > /dev/null 2>&1
        success "User $DEL_USER berhasil dihapus"
    else
        error "User $DEL_USER tidak ditemukan"
    fi
    
    # Tekan Enter untuk melanjutkan
    read -n 1 -s -r -p "Tekan sembarang tombol untuk melanjutkan..."
}

# Show SSH Users Function
show_users() {
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${GREEN}                   DAFTAR USER SSH                          ${PLAIN}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    awk -F':' '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd | while read user; do
        echo -e "${YELLOW}$user${PLAIN}"
    done
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    
    # Tekan Enter untuk melanjutkan
    read -n 1 -s -r -p "Tekan sembarang tombol untuk melanjutkan..."
}

# Restart SSH Function
restart_ssh() {
    show_progress "Merestart service SSH"
    systemctl restart ssh > /dev/null 2>&1
    systemctl enable ssh > /dev/null 2>&1
    success "Service SSH berhasil direstart dan diaktifkan"
    
    # Tekan Enter untuk melanjutkan
    read -n 1 -s -r -p "Tekan sembarang tombol untuk melanjutkan..."
}

# Create WebSocket User Function
create_websocket_user() {
    read -p "Masukkan username untuk WebSocket: " WS_USER
    read -s -p "Masukkan password untuk $WS_USER: " WS_PASSWORD
    echo ""

    useradd -m -s /bin/bash "$WS_USER" > /dev/null 2>&1
    echo "$WS_USER:$WS_PASSWORD" | chpasswd
    success "User WebSocket $WS_USER berhasil dibuat"
    
    # Tampilkan informasi koneksi
    IP_ADDRESS=$(get_public_ip)
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}')
    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT=22
    fi
    
    # Ambil port WebSocket dari file konfigurasi
    WS_PORT=$(cat /etc/theoryma_ws_port 2>/dev/null)
    if [[ -z "$WS_PORT" ]]; then
        WS_PORT=80  # Default port jika file konfigurasi tidak ditemukan
    fi
    
    # Cek apakah TLS SSH sudah diinstal
    TLS_PORT=""
    if [ -f /etc/stunnel/stunnel.conf ]; then
        TLS_PORT=$(cat /etc/theoryma_tls_port 2>/dev/null || echo "443")
    fi
    
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${GREEN}         INFORMASI KONEKSI USER WEBSOCKET BARU              ${PLAIN}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    echo -e "${YELLOW}Detail Akun:${PLAIN}"
    echo -e "Username        : ${GREEN}$WS_USER${PLAIN}"
    echo -e "Password        : ${GREEN}$WS_PASSWORD${PLAIN}"
    echo -e "IP Address      : ${GREEN}$IP_ADDRESS${PLAIN}"
    echo -e "Port SSH        : ${GREEN}$SSH_PORT${PLAIN}"
    echo -e "Port WebSocket  : ${GREEN}$WS_PORT${PLAIN}"
    if [[ ! -z "$TLS_PORT" ]]; then
        echo -e "Port TLS SSH   : ${GREEN}$TLS_PORT${PLAIN}"
    fi
    echo ""
    echo -e "${YELLOW}URL WebSocket:${PLAIN}"
    echo -e "${GREEN}ws://$IP_ADDRESS:$WS_PORT${PLAIN}"
    echo ""
    echo -e "${YELLOW}Konfigurasi untuk Aplikasi SSH Client:${PLAIN}"
    echo -e "Host           : ${GREEN}$IP_ADDRESS${PLAIN}"
    echo -e "Port           : ${GREEN}$WS_PORT${PLAIN}"
    echo -e "Username       : ${GREEN}$WS_USER${PLAIN}"
    echo -e "Password       : ${GREEN}$WS_PASSWORD${PLAIN}"
    echo -e "WebSocket Path : ${GREEN}/${PLAIN}"
    if [[ ! -z "$TLS_PORT" ]]; then
        echo -e ""
        echo -e "${YELLOW}Untuk koneksi TLS SSH:${PLAIN}"
        echo -e "Host          : ${GREEN}$IP_ADDRESS${PLAIN}"
        echo -e "Port          : ${GREEN}$TLS_PORT${PLAIN}"
        echo -e "Username      : ${GREEN}$WS_USER${PLAIN}"
        echo -e "Password      : ${GREEN}$WS_PASSWORD${PLAIN}"
    fi
    echo -e "${GREEN}════════════════════════════════════════════════════════════${PLAIN}"
    
    # Tekan Enter untuk melanjutkan
    read -n 1 -s -r -p "Tekan sembarang tombol untuk melanjutkan..."
}

# Restart WebSocket Function
restart_websocket() {
    show_progress "Merestart service WebSocket"
    systemctl restart websockify > /dev/null 2>&1
    systemctl enable websockify > /dev/null 2>&1
    success "Service WebSocket berhasil direstart dan diaktifkan"
    
    # Tekan Enter untuk melanjutkan
    read -n 1 -s -r -p "Tekan sembarang tombol untuk melanjutkan..."
}

# Tambahkan fungsi untuk restart TLS SSH
restart_tls_ssh() {
    show_progress "Merestart service TLS SSH"
    systemctl restart stunnel4 > /dev/null 2>&1
    systemctl enable stunnel4 > /dev/null 2>&1
    success "Service TLS SSH berhasil direstart dan diaktifkan"
    
    # Tekan Enter untuk melanjutkan
    read -n 1 -s -r -p "Tekan sembarang tombol untuk melanjutkan..."
}

# Reboot System Function
reboot_system() {
    show_progress "Bersiap untuk merestart sistem"
    echo -e "${YELLOW}Sistem akan direstart dalam 5 detik...${PLAIN}"
    sleep 1
    echo -e "${YELLOW}4...${PLAIN}"
    sleep 1
    echo -e "${YELLOW}3...${PLAIN}"
    sleep 1
    echo -e "${YELLOW}2...${PLAIN}"
    sleep 1
    echo -e "${YELLOW}1...${PLAIN}"
    sleep 1
    echo -e "${GREEN}Merestart sekarang!${PLAIN}"
    reboot
}

# Jalankan instalasi SSH saat script dimulai
install_ssh

# Program Utama
while true; do
    show_main_menu
    case $main_option in
        1) # Menu SSH
            while true; do
                show_ssh_menu
                case $ssh_option in
                    1) create_user ;;
                    2) delete_user ;;
                    3) show_users ;;
                    4) restart_ssh ;;
                    5) # Instal atau restart TLS SSH
                       if [ -f /etc/stunnel/stunnel.conf ]; then
                           restart_tls_ssh
                       else
                           install_tls_ssh
                       fi
                       ;;
                    6) break ;;
                    *) echo -e "${RED}Silakan masukkan opsi yang valid [1-6]${PLAIN}"
                       sleep 2 ;;
                esac
            done
            ;;
        2) # Menu WebSocket
            # Periksa jika WebSocket sudah diinstal
            if [ ! -f /etc/systemd/system/websockify.service ]; then
                show_progress "WebSocket belum diinstal. Menginstal WebSocket..."
                install_websocket
            fi
            
            while true; do
                show_websocket_menu
                case $websocket_option in
                    1) create_websocket_user ;;
                    2) delete_user ;;
                    3) show_users ;;
                    4) restart_websocket ;;
                    5) break ;;
                    *) echo -e "${RED}Silakan masukkan opsi yang valid [1-5]${PLAIN}"
                       sleep 2 ;;
                esac
            done
            ;;
        3) reboot_system ;;
        4) clear
           echo -e "${GREEN}Terima kasih telah menggunakan TheorymaVPN SSH Manager${PLAIN}"
           exit 0 ;;
        *) echo -e "${RED}Silakan masukkan opsi yang valid [1-4]${PLAIN}"
           sleep 2 ;;
    esac
done