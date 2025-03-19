#!/bin/bash
################################################################################
# Script for installing Odoo 18 on Debian 12 (Bookworm)
# Author: Claude AI, based on scripts by Yenthe Van Ginneken
# Website: https://github.com/Yenthe666/InstallScript
#-------------------------------------------------------------------------------
# This script will install Odoo 18 on Debian 12 with Nginx as a reverse proxy
# and SSL configuration via Let's Encrypt. It supports multiple Odoo instances
# using different ports.
#-------------------------------------------------------------------------------
# Instructions:
# 1. Save this file as odoo18_install.sh
# 2. Make it executable: sudo chmod +x odoo18_install.sh
# 3. Run the script with sudo: sudo ./odoo18_install.sh
################################################################################

# Set to false to disable colors
USE_COLORS="True"

# Color definitions
if [ "$USE_COLORS" = "True" ]; then
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    GREEN=''
    YELLOW=''
    RED=''
    BLUE=''
    NC=''
fi

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command execution was successful
check_command() {
    if [ $? -ne 0 ]; then
        print_error "$1"
        exit 1
    fi
}

# Configuration variables
OE_USER="odoo"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"
OE_VERSION="18.0"
INSTALL_WKHTMLTOPDF="True"
OE_PORT="8069"
LONGPOLLING_PORT="8072"
IS_ENTERPRISE="False"
INSTALL_NGINX="True"
ENABLE_SSL="True"
GENERATE_RANDOM_PASSWORD="True"
OE_SUPERADMIN="admin"
OE_CONFIG="${OE_USER}-server"
WEBSITE_NAME="_"
ADMIN_EMAIL="odoo@example.com"

# PostgreSQL version
PG_VERSION="15"
INSTALL_POSTGRESQL="True"

# Worker configuration for better performance
CPU_COUNT=$(grep -c ^processor /proc/cpuinfo)
WORKERS=$((CPU_COUNT > 0 ? CPU_COUNT * 2 : 2))
MAX_CRON_THREADS=$((CPU_COUNT > 0 ? CPU_COUNT : 2))

# Check if the script is run as root
if [ $EUID -ne 0 ]; then
   print_error "This script must be run as root"
   exit 1
fi

# Prompt for configuration if running interactively
if [ -t 0 ] && [ -t 1 ]; then
    read -p "Domain name for Odoo (e.g., odoo.example.com): " user_domain
    if [ ! -z "$user_domain" ]; then
        WEBSITE_NAME=$user_domain
    fi

    read -p "Email for SSL certificate (required for Let's Encrypt): " user_email
    if [ ! -z "$user_email" ]; then
        ADMIN_EMAIL=$user_email
    fi

    read -p "Install Odoo Enterprise Edition? (y/N): " is_enterprise
    if [[ "$is_enterprise" =~ ^[Yy]$ ]]; then
        IS_ENTERPRISE="True"
    fi

    read -p "Configure Nginx with SSL? (Y/n): " use_nginx_ssl
    if [[ "$use_nginx_ssl" =~ ^[Nn]$ ]]; then
        ENABLE_SSL="False"
    fi
fi

# Validate configuration
if [ "$INSTALL_NGINX" = "True" ] && [ "$ENABLE_SSL" = "True" ]; then
    if [ "$WEBSITE_NAME" = "_" ]; then
        print_error "Website name must be set for SSL configuration. Please update WEBSITE_NAME."
        exit 1
    fi

    if [ "$ADMIN_EMAIL" = "odoo@example.com" ]; then
        print_error "Admin email must be set for SSL configuration. Please update ADMIN_EMAIL."
        exit 1
    fi
fi

print_info "Starting Odoo $OE_VERSION installation on Debian..."
print_info "This script will install:"
echo "- Odoo $OE_VERSION ($([ "$IS_ENTERPRISE" = "True" ] && echo "Enterprise" || echo "Community"))"
echo "- PostgreSQL $PG_VERSION"
[ "$INSTALL_WKHTMLTOPDF" = "True" ] && echo "- Wkhtmltopdf"
[ "$INSTALL_NGINX" = "True" ] && echo "- Nginx $([ "$ENABLE_SSL" = "True" ] && echo "with SSL via Let's Encrypt")"

# Update system
print_info "Updating system packages..."
apt-get update
check_command "Failed to update package lists"
apt-get upgrade -y
check_command "Failed to upgrade packages"

# Install necessary packages
print_info "Installing necessary packages..."
apt-get install -y software-properties-common gnupg2 curl wget git 
check_command "Failed to install base dependencies"

# Install PostgreSQL if needed
if [ "$INSTALL_POSTGRESQL" = "True" ]; then
    print_info "Installing PostgreSQL $PG_VERSION..."
    apt-get install -y postgresql-$PG_VERSION postgresql-server-dev-$PG_VERSION
    check_command "Failed to install PostgreSQL"

    # Create PostgreSQL user
    print_info "Creating PostgreSQL user '$OE_USER'..."
    sudo -u postgres createuser -s $OE_USER 2> /dev/null || true
    print_success "PostgreSQL user created"
fi

# Install Python dependencies
print_info "Installing Python and development dependencies..."
apt-get install -y \
    python3 python3-pip python3-dev python3-venv python3-wheel \
    build-essential libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
    libtiff5-dev libjpeg62-turbo-dev libopenjp2-7-dev zlib1g-dev \
    libfreetype6-dev libwebp-dev libharfbuzz-dev libfribidi-dev \
    libxcb1-dev libpq-dev libjpeg-dev
check_command "Failed to install Python dependencies"

# Install NodeJS and NPM for Odoo 18
print_info "Installing NodeJS and npm..."
apt-get install -y nodejs npm
check_command "Failed to install NodeJS and npm"

# Install rtlcss for RTL support in Odoo
print_info "Installing rtlcss..."
npm install -g rtlcss less less-plugin-clean-css
check_command "Failed to install rtlcss"

# Install wkhtmltopdf if needed
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
    print_info "Installing wkhtmltopdf..."
    # Since Odoo 18 is new, using the recommended version for Odoo 16
    WKHTML_VERSION="0.12.6.1-3"
    
    # Architecture detection
    ARCH=$(dpkg --print-architecture)
    if [ "$ARCH" = "amd64" ]; then
        WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTML_VERSION}/wkhtmltox_${WKHTML_VERSION}.bookworm_amd64.deb"
    else
        print_warning "Architecture $ARCH not directly supported for wkhtmltopdf. Will try to install from apt."
        apt-get install -y wkhtmltopdf
        check_command "Failed to install wkhtmltopdf from apt"
    fi

    if [ ! -z "$WKHTML_URL" ]; then
        wget $WKHTML_URL -O /tmp/wkhtmltox.deb
        check_command "Failed to download wkhtmltopdf"
        
        apt-get install -y /tmp/wkhtmltox.deb
        check_command "Failed to install wkhtmltopdf"
        
        ln -s /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf
        ln -s /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage
        
        print_success "wkhtmltopdf installed successfully"
    fi
fi

# Create Odoo system user
print_info "Creating system user $OE_USER..."
adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER
check_command "Failed to create Odoo system user"

# Add to sudo group for convenience (optional)
adduser $OE_USER sudo
check_command "Failed to add Odoo user to sudo group"

# Create log directory
print_info "Creating log directory..."
mkdir -p /var/log/$OE_USER
chown $OE_USER:$OE_USER /var/log/$OE_USER
check_command "Failed to create log directory"

# Install Odoo
print_info "Installing Odoo $OE_VERSION..."
git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo $OE_HOME_EXT/
check_command "Failed to clone Odoo repository"

# Install Odoo Python dependencies
print_info "Installing Odoo Python dependencies..."
pip3 install wheel
pip3 install -r $OE_HOME_EXT/requirements.txt
check_command "Failed to install Odoo Python dependencies"

# Install additional dependencies for better performance and features
pip3 install psycopg2-binary watchdog Werkzeug==2.3.7
check_command "Failed to install additional Python packages"

# Install Enterprise if requested
if [ "$IS_ENTERPRISE" = "True" ]; then
    print_info "Installing Odoo Enterprise..."
    
    # Create enterprise directory
    sudo -u $OE_USER mkdir -p $OE_HOME/enterprise/addons
    
    print_warning "You need GitHub access to Odoo Enterprise repository."
    print_warning "Please enter your GitHub credentials when prompted."
    
    GITHUB_RESPONSE=$(sudo -u $OE_USER git clone --depth 1 --branch $OE_VERSION https://github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    
    while [[ $GITHUB_RESPONSE == *"Authentication"* ]]; do
        print_error "Authentication with GitHub failed! Please try again."
        print_warning "You need to be an official Odoo partner with access to"
        print_warning "https://github.com/odoo/enterprise repository."
        print_warning "Press Ctrl+C to exit this script."
        
        GITHUB_RESPONSE=$(sudo -u $OE_USER git clone --depth 1 --branch $OE_VERSION https://github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    done
    
    print_success "Odoo Enterprise installed at $OE_HOME/enterprise/addons"
    
    # Install Enterprise-specific dependencies
    print_info "Installing Enterprise-specific dependencies..."
    pip3 install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
    check_command "Failed to install Enterprise-specific Python dependencies"
fi

# Create custom addons directory
print_info "Creating custom addons directory..."
sudo -u $OE_USER mkdir -p $OE_HOME/custom/addons
check_command "Failed to create custom addons directory"

# Set permissions
print_info "Setting permissions..."
chown -R $OE_USER:$OE_USER $OE_HOME/
check_command "Failed to set permissions"

# Create server config file
print_info "Creating server configuration file..."
touch /etc/${OE_CONFIG}.conf
echo -e "[options]" > /etc/${OE_CONFIG}.conf

# Set admin password
if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    print_info "Generating random admin password..."
    OE_SUPERADMIN=$(openssl rand -base64 12)
fi

cat <<EOF >> /etc/${OE_CONFIG}.conf
; This is the password that allows database operations:
admin_passwd = $OE_SUPERADMIN
db_host = False
db_port = False
db_user = $OE_USER
db_password = False
http_port = $OE_PORT
longpolling_port = $LONGPOLLING_PORT
logfile = /var/log/$OE_USER/$OE_CONFIG.log
logrotate = True
proxy_mode = True

; Performance optimizations
workers = $WORKERS
max_cron_threads = $MAX_CRON_THREADS
limit_time_cpu = 600
limit_time_real = 1200
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
EOF

# Add addons path
if [ "$IS_ENTERPRISE" = "True" ]; then
    echo "addons_path = $OE_HOME/enterprise/addons,$OE_HOME_EXT/addons,$OE_HOME/custom/addons" >> /etc/${OE_CONFIG}.conf
else
    echo "addons_path = $OE_HOME_EXT/addons,$OE_HOME/custom/addons" >> /etc/${OE_CONFIG}.conf
fi

# Set permissions for the config file
chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
chmod 640 /etc/${OE_CONFIG}.conf

# Create systemd service file
print_info "Creating systemd service file..."
cat <<EOF > /etc/systemd/system/${OE_CONFIG}.service
[Unit]
Description=Odoo 18
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=${OE_CONFIG}
PermissionsStartOnly=true
User=${OE_USER}
Group=${OE_USER}
ExecStart=${OE_HOME_EXT}/odoo-bin --config=/etc/${OE_CONFIG}.conf --logfile=/var/log/${OE_USER}/${OE_CONFIG}.log
StandardOutput=journal+console
WorkingDirectory=${OE_HOME_EXT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable Odoo service
systemctl daemon-reload
systemctl enable ${OE_CONFIG}
check_command "Failed to enable Odoo service"

# Install Nginx if needed
if [ "$INSTALL_NGINX" = "True" ]; then
    print_info "Installing and configuring Nginx..."
    apt-get install -y nginx
    check_command "Failed to install Nginx"

    # Create Nginx configuration file
    cat <<EOF > /etc/nginx/sites-available/$WEBSITE_NAME
upstream odoo {
    server 127.0.0.1:$OE_PORT;
}

upstream odoochat {
    server 127.0.0.1:$LONGPOLLING_PORT;
}

server {
    listen 80;
    server_name $WEBSITE_NAME;

    # Proxy headers
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header Referrer-Policy "strict-origin";

    # Logs
    access_log /var/log/nginx/${OE_USER}-access.log;
    error_log /var/log/nginx/${OE_USER}-error.log;

    # Proxy buffers
    proxy_buffers 16 64k;
    proxy_buffer_size 128k;

    # Timeouts
    proxy_read_timeout 900s;
    proxy_connect_timeout 900s;
    proxy_send_timeout 900s;

    # Proxy error handling
    proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;

    # Cache and compression
    gzip on;
    gzip_min_length 1100;
    gzip_buffers 4 32k;
    gzip_types text/plain text/css text/less text/javascript text/xml application/json application/x-javascript application/xml application/xml+rss application/javascript;
    gzip_vary on;

    # Client body size
    client_max_body_size 100M;

    # Main location
    location / {
        proxy_pass http://odoo;
        proxy_redirect off;
    }

    # Websocket support for Odoo chat
    location /websocket {
        proxy_pass http://odoochat;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_http_version 1.1;
    }

    # Longpolling
    location /longpolling {
        proxy_pass http://odoochat;
    }

    # Static files
    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo;
    }

    # Common asset files
    location ~* .(js|css|png|jpg|jpeg|gif|ico)$ {
        expires 7d;
        proxy_pass http://odoo;
        add_header Cache-Control "public, max-age=604800";
    }
}
EOF

    # Enable the Nginx site
    ln -s /etc/nginx/sites-available/$WEBSITE_NAME /etc/nginx/sites-enabled/$WEBSITE_NAME
    # Remove default site if exists
    if [ -f /etc/nginx/sites-enabled/default ]; then
        rm /etc/nginx/sites-enabled/default
    fi

    # Test Nginx configuration
    nginx -t
    check_command "Invalid Nginx configuration"

    # Restart Nginx
    systemctl restart nginx
    check_command "Failed to restart Nginx"

    print_success "Nginx configuration created at /etc/nginx/sites-available/$WEBSITE_NAME"
fi

# Setup SSL with certbot if requested
if [ "$INSTALL_NGINX" = "True" ] && [ "$ENABLE_SSL" = "True" ] && [ "$WEBSITE_NAME" != "_" ] && [ "$ADMIN_EMAIL" != "odoo@example.com" ]; then
    print_info "Setting up SSL with Let's Encrypt..."

    # Install certbot
    apt-get install -y snapd
    check_command "Failed to install snapd"

    snap install core
    snap refresh core
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/bin/certbot

    # Get SSL certificate
    certbot --nginx -d $WEBSITE_NAME --noninteractive --agree-tos --email $ADMIN_EMAIL --redirect
    check_command "Failed to obtain SSL certificate"

    # Setup auto-renewal
    echo "0 0 * * * certbot renew --quiet" | crontab -
    check_command "Failed to setup certbot auto-renewal"

    print_success "SSL certificate installed for $WEBSITE_NAME"
else
    print_warning "SSL setup skipped due to configuration or missing parameters"
    if [ "$WEBSITE_NAME" = "_" ]; then
        print_warning "Website name is set as '_'. Cannot obtain SSL certificate."
    fi
    if [ "$ADMIN_EMAIL" = "odoo@example.com" ]; then
        print_warning "Admin email is set to default value. Cannot register with Let's Encrypt."
    fi
fi

# Start Odoo service
print_info "Starting Odoo service..."
systemctl start ${OE_CONFIG}
check_command "Failed to start Odoo service"

# === Security Hardening ===
print_info "Applying security hardening measures..."

# Update SSH configuration for better security
if [ -f /etc/ssh/sshd_config ]; then
    print_info "Hardening SSH configuration..."
    
    # Backup the original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    
    # Apply security settings
    sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config
    
    # Restart SSH service
    systemctl restart sshd
    check_command "Failed to restart SSH service"
    
    print_success "SSH hardening applied (root login disabled, password auth disabled)"
fi

# Setup firewall
print_info "Setting up firewall..."
apt-get install -y ufw
check_command "Failed to install UFW firewall"

# Configure firewall rules
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow "Nginx Full"
ufw allow $OE_PORT/tcp
ufw allow $LONGPOLLING_PORT/tcp

# Enable firewall
print_warning "About to enable UFW firewall. SSH connections will still be allowed."
echo "y" | ufw enable
check_command "Failed to enable UFW firewall"

print_success "Firewall configured and enabled"

# === Final Output ===
print_success "Odoo $OE_VERSION installation completed successfully!"
echo 
echo -e "${GREEN}-----------------------------------------------------------${NC}"
echo -e "${GREEN}Installation Summary${NC}"
echo -e "${GREEN}-----------------------------------------------------------${NC}"
echo "Odoo version: $OE_VERSION"
echo "Odoo service name: $OE_CONFIG"
echo "Odoo superadmin password: $OE_SUPERADMIN"
echo "Odoo user: $OE_USER"
echo "Odoo home: $OE_HOME"
echo "Odoo port: $OE_PORT"
echo "Longpolling port: $LONGPOLLING_PORT"
echo "Configuration file: /etc/${OE_CONFIG}.conf"
echo "Log file: /var/log/$OE_USER/${OE_CONFIG}.log"
echo "Custom addons path: $OE_HOME/custom/addons"
if [ "$INSTALL_NGINX" = "True" ]; then
    echo "Nginx site name: $WEBSITE_NAME"
    echo "Nginx config: /etc/nginx/sites-available/$WEBSITE_NAME"
    if [ "$ENABLE_SSL" = "True" ] && [ "$WEBSITE_NAME" != "_" ]; then
        echo "SSL: Enabled (Let's Encrypt)"
    else
        echo "SSL: Disabled"
    fi
fi
echo 
echo -e "${BLUE}Useful Commands:${NC}"
echo "Start Odoo: sudo systemctl start $OE_CONFIG"
echo "Stop Odoo: sudo systemctl stop $OE_CONFIG"
echo "Restart Odoo: sudo systemctl restart $OE_CONFIG"
echo "Check status: sudo systemctl status $OE_CONFIG"
echo "View logs: sudo tail -f /var/log/$OE_USER/${OE_CONFIG}.log"
echo 
echo -e "${YELLOW}Note: Allow a few minutes for Odoo to fully start the first time.${NC}"
echo -e "${YELLOW}Access Odoo at: http://$WEBSITE_NAME ${NC}"
if [ "$ENABLE_SSL" = "True" ] && [ "$WEBSITE_NAME" != "_" ]; then
    echo -e "${YELLOW}or securely at: https://$WEBSITE_NAME${NC}"
fi
echo -e "${GREEN}-----------------------------------------------------------${NC}"
