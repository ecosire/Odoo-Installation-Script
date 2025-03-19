#!/bin/bash
################################################################################
# Script for installing Odoo 18 on Ubuntu 22.04 LTS and 24.04 LTS
# Author: Based on scripts by Yenthe Van Ginneken
# Updated for Odoo 18 with best practices from Bitnami for stability
#-------------------------------------------------------------------------------
# This script will install Odoo on your Ubuntu server. It can install multiple Odoo instances
# in one Ubuntu because of the different ports
#-------------------------------------------------------------------------------
# Make a new file:
# sudo nano odoo18_install.sh
# Place this content in it and then make the file executable:
# sudo chmod +x odoo18_install.sh
# Execute the script to install Odoo:
# ./odoo18_install.sh
################################################################################

# Set to true to enable debug mode (more verbose output)
DEBUG_MODE="False"

log() {
    local level=$1
    shift
    local message="$@"
    if [ "$level" = "DEBUG" ] && [ "$DEBUG_MODE" != "True" ]; then
        return
    fi
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - [$level] - $message"
}

# Configuration variables
OE_USER="odoo"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"

# Set to true if you want to install it, false if you don't need it or have it already installed.
INSTALL_WKHTMLTOPDF="True"

# Default port for Odoo
OE_PORT="8069"

# Choose the Odoo version which you want to install. 
OE_VERSION="18.0"

# Set this to True if you want to install the Odoo enterprise version!
IS_ENTERPRISE="False"

# Installs PostgreSQL V16 for improved performance
INSTALL_POSTGRESQL_16="True"

# Set this to True if you want to install Nginx!
INSTALL_NGINX="True"

# Set the superadmin password - if GENERATE_RANDOM_PASSWORD is set to "True" we will automatically generate a random password, otherwise we use this one
OE_SUPERADMIN="admin"

# Set to "True" to generate a random password, "False" to use the variable in OE_SUPERADMIN
GENERATE_RANDOM_PASSWORD="True"

OE_CONFIG="${OE_USER}-server"

# Default website name for Nginx config
WEBSITE_NAME="_"

# Default long polling port
LONGPOLLING_PORT="8072"

# Set to "True" to install certbot and have SSL enabled, "False" to use http
ENABLE_SSL="True"

# Provide Email to register SSL certificate
ADMIN_EMAIL="odoo@example.com"

# Performance tuning options
DB_MAX_CONNECTIONS=100
DB_SHARED_BUFFERS="512MB"
WORKERS=0  # 0 = auto calculate based on CPU cores
MAX_CRON_THREADS=2
LIMIT_MEMORY_HARD="2684354560"  # 2.5 GB
LIMIT_MEMORY_SOFT="2147483648"  # 2 GB
LIMIT_TIME_CPU=60
LIMIT_TIME_REAL=120
MAX_DB_CONNECTIONS=64

# Bitnami inspired stability settings
ENABLE_MULTIPROCESSING="True"
ENABLE_SYSLOG="True"
LOG_LEVEL="info"  # debug, info, warning, error, critical
ENABLE_DB_FILTERING="True"
DB_FILTER=".*"  # Allow all databases by default

# Get OS information
OS_NAME=$(lsb_release -cs)
OS_VERSION=$(lsb_release -rs)

log "INFO" "Starting Odoo 18 installation on $OS_NAME $OS_VERSION"

# Check if script is run as root
if [ $EUID -ne 0 ]; then
    log "ERROR" "This script must be run as root. Please use sudo."
    exit 1
fi

# Function to calculate number of worker processes
calculate_workers() {
    # Calculate based on CPU cores, using Odoo's recommendation (CPU cores * 2) + 1
    # but cap at reasonable limits
    local cpu_count=$(nproc)
    local calculated=$((cpu_count * 2 + 1))
    
    # Cap at 8 workers for typical deployments
    if [ $calculated -gt 8 ]; then
        calculated=8
    fi
    
    echo $calculated
}

#--------------------------------------------------
# Update Server
#--------------------------------------------------
log "INFO" "Updating server packages..."
apt-get update
apt-get upgrade -y

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
log "INFO" "Installing PostgreSQL Server..."
if [ $INSTALL_POSTGRESQL_16 = "True" ]; then
    log "INFO" "Installing PostgreSQL 16 for better performance"
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
    apt-get update
    apt-get install postgresql-16 postgresql-client-16 postgresql-server-dev-16 -y
    
    # Configure PostgreSQL for better performance
    PG_CONF="/etc/postgresql/16/main/postgresql.conf"
    PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
    
    # Backup the config files
    cp $PG_CONF $PG_CONF.backup
    cp $PG_HBA $PG_HBA.backup
    
    # Update PostgreSQL configuration for better performance
    sed -i "s/max_connections = 100/max_connections = $DB_MAX_CONNECTIONS/" $PG_CONF
    sed -i "s/shared_buffers = 128MB/shared_buffers = $DB_SHARED_BUFFERS/" $PG_CONF
    
    # Apply more aggressive settings for larger instances
    echo "work_mem = 16MB" >> $PG_CONF
    echo "maintenance_work_mem = 128MB" >> $PG_CONF
    echo "effective_cache_size = 1GB" >> $PG_CONF
    echo "synchronous_commit = off" >> $PG_CONF
    echo "checkpoint_timeout = 15min" >> $PG_CONF
    echo "checkpoint_completion_target = 0.9" >> $PG_CONF
    echo "wal_buffers = 16MB" >> $PG_CONF
    echo "default_statistics_target = 100" >> $PG_CONF
    
    # Restart PostgreSQL
    systemctl restart postgresql
else
    log "INFO" "Installing default PostgreSQL version"
    apt-get install postgresql postgresql-server-dev-all -y
fi

log "INFO" "Creating the Odoo PostgreSQL user"
su - postgres -c "createuser -s $OE_USER" 2> /dev/null || true

#--------------------------------------------------
# Install Required Dependencies
#--------------------------------------------------
log "INFO" "Installing Python and other dependencies..."
apt-get install python3-pip python3-dev python3-venv python3-wheel \
    build-essential wget git libxslt1-dev libzip-dev libldap2-dev \
    libsasl2-dev python3-setuptools libpq-dev libxml2-dev libxslt1-dev \
    libjpeg8-dev zlib1g-dev libfreetype6-dev liblcms2-dev libwebp-dev \
    libharfbuzz-dev libfribidi-dev libxcb1-dev -y

log "INFO" "Installing Node.js and NPM for LESS compilation..."
apt-get install nodejs npm -y
npm install -g rtlcss less less-plugin-clean-css

log "INFO" "Installing Python packages/requirements..."
pip3 install wheel
pip3 install -r https://github.com/odoo/odoo/raw/${OE_VERSION}/requirements.txt

#--------------------------------------------------
# Install Wkhtmltopdf if needed
#--------------------------------------------------
if [ $INSTALL_WKHTMLTOPDF = "True" ]; then
    log "INFO" "Installing wkhtmltopdf for Odoo 18 PDF reports..."
    
    # For Odoo 18, we need wkhtmltopdf 0.12.6
    WKHTMLTOPDF_VERSION="0.12.6.1-2"
    WKHTMLTOPDF_ARCH="amd64"
    
    if [ "$(arch)" == "aarch64" ]; then
        WKHTMLTOPDF_ARCH="arm64"
    fi
    
    WKHTMLTOPDF_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/wkhtmltox_${WKHTMLTOPDF_VERSION}.jammy_${WKHTMLTOPDF_ARCH}.deb"
    
    log "DEBUG" "Downloading wkhtmltopdf from $WKHTMLTOPDF_URL"
    wget $WKHTMLTOPDF_URL
    apt install -y ./wkhtmltox_${WKHTMLTOPDF_VERSION}.jammy_${WKHTMLTOPDF_ARCH}.deb
    rm wkhtmltox_${WKHTMLTOPDF_VERSION}.jammy_${WKHTMLTOPDF_ARCH}.deb
    
    # Create symlinks for compatibility
    ln -s /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf
    ln -s /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage
    
    log "INFO" "wkhtmltopdf installation completed"
else
    log "INFO" "Skipping wkhtmltopdf installation based on user preferences"
fi

#--------------------------------------------------
# Create ODOO system user
#--------------------------------------------------
log "INFO" "Creating Odoo system user..."
adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER
adduser $OE_USER sudo

log "INFO" "Creating Log directory..."
mkdir -p /var/log/$OE_USER
chown $OE_USER:$OE_USER /var/log/$OE_USER

#--------------------------------------------------
# Install ODOO from GitHub
#--------------------------------------------------
log "INFO" "Installing Odoo from GitHub repository..."
git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo $OE_HOME_EXT/

if [ $IS_ENTERPRISE = "True" ]; then
    # Odoo Enterprise install!
    log "INFO" "Installing Odoo Enterprise..."
    pip3 install psycopg2-binary pdfminer.six
    
    # Create symlink for node
    ln -s /usr/bin/nodejs /usr/bin/node 2>/dev/null || true
    
    su $OE_USER -c "mkdir -p $OE_HOME/enterprise"
    su $OE_USER -c "mkdir -p $OE_HOME/enterprise/addons"

    GITHUB_RESPONSE=$(git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    while [[ $GITHUB_RESPONSE == *"Authentication"* ]]; do
        log "WARNING" "------------------------WARNING------------------------------"
        log "WARNING" "Your authentication with Github has failed! Please try again."
        log "WARNING" "In order to clone and install the Odoo enterprise version you"
        log "WARNING" "need to be an official Odoo partner and have access to"
        log "WARNING" "https://github.com/odoo/enterprise."
        log "WARNING" "TIP: Press ctrl+c to stop this script."
        log "WARNING" "-------------------------------------------------------------"
        
        GITHUB_RESPONSE=$(git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    done

    log "INFO" "Added Enterprise code under $OE_HOME/enterprise/addons"
    log "INFO" "Installing Enterprise specific libraries..."
    pip3 install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
    npm install -g less less-plugin-clean-css
fi

#--------------------------------------------------
# Create Custom addons directory
#--------------------------------------------------
log "INFO" "Creating custom module directory..."
su $OE_USER -c "mkdir -p $OE_HOME/custom"
su $OE_USER -c "mkdir -p $OE_HOME/custom/addons"

#--------------------------------------------------
# Set permissions and create config file
#--------------------------------------------------
log "INFO" "Setting permissions on home folder..."
chown -R $OE_USER:$OE_USER $OE_HOME/

log "INFO" "Creating server config file..."
touch /etc/${OE_CONFIG}.conf

# If workers is set to 0, calculate based on CPU cores
if [ "$WORKERS" = "0" ]; then
    WORKERS=$(calculate_workers)
    log "INFO" "Auto-calculated workers: $WORKERS"
fi

# Create server config file
cat <<EOF > /etc/${OE_CONFIG}.conf
[options]
; This is the password that allows database operations:
admin_passwd = ${OE_SUPERADMIN}
http_port = ${OE_PORT}
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
EOF

# Add Enterprise addons path if Enterprise
if [ $IS_ENTERPRISE = "True" ]; then
    echo "addons_path = ${OE_HOME}/enterprise/addons,${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons" >> /etc/${OE_CONFIG}.conf
else
    echo "addons_path = ${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons" >> /etc/${OE_CONFIG}.conf
fi

# Add Bitnami inspired performance and stability settings
cat <<EOF >> /etc/${OE_CONFIG}.conf
xmlrpc_port = ${OE_PORT}
longpolling_port = ${LONGPOLLING_PORT}
proxy_mode = False
workers = ${WORKERS}
max_cron_threads = ${MAX_CRON_THREADS}
limit_memory_hard = ${LIMIT_MEMORY_HARD}
limit_memory_soft = ${LIMIT_MEMORY_SOFT}
limit_time_cpu = ${LIMIT_TIME_CPU}
limit_time_real = ${LIMIT_TIME_REAL}
max_db_connections = ${MAX_DB_CONNECTIONS}
db_maxconn = ${MAX_DB_CONNECTIONS}
list_db = True
EOF

# Add optional settings based on configuration variables
if [ "$ENABLE_MULTIPROCESSING" = "True" ]; then
    echo "multiprocessing = True" >> /etc/${OE_CONFIG}.conf
fi

if [ "$ENABLE_SYSLOG" = "True" ]; then
    echo "syslog = True" >> /etc/${OE_CONFIG}.conf
    echo "log_level = ${LOG_LEVEL}" >> /etc/${OE_CONFIG}.conf
fi

if [ "$ENABLE_DB_FILTERING" = "True" ]; then
    echo "dbfilter = ${DB_FILTER}" >> /etc/${OE_CONFIG}.conf
fi

# Set proper permissions
chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
chmod 640 /etc/${OE_CONFIG}.conf

#--------------------------------------------------
# Create startup file / service
#--------------------------------------------------
log "INFO" "Creating systemd service file..."
cat <<EOF > /etc/systemd/system/${OE_CONFIG}.service
[Unit]
Description=Odoo 18 ERP Server
After=network.target postgresql.service

[Service]
Type=simple
User=${OE_USER}
Group=${OE_USER}
ExecStart=${OE_HOME_EXT}/odoo-bin --config=/etc/${OE_CONFIG}.conf
Restart=always
RestartSec=5
SyslogIdentifier=${OE_CONFIG}
KillMode=mixed
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF

log "INFO" "Enabling Odoo service to start on boot..."
systemctl daemon-reload
systemctl enable ${OE_CONFIG}

#--------------------------------------------------
# Install Nginx if needed
#--------------------------------------------------
if [ $INSTALL_NGINX = "True" ]; then
    log "INFO" "Installing and configuring Nginx..."
    apt-get install nginx -y
    
    # Create nginx configuration
    cat <<EOF > /etc/nginx/sites-available/${OE_CONFIG}
upstream odoo {
    server 127.0.0.1:${OE_PORT};
}

upstream odoochat {
    server 127.0.0.1:${LONGPOLLING_PORT};
}

server {
    listen 80;
    server_name ${WEBSITE_NAME};

    # Force the use of https
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Frame-Options SAMEORIGIN;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload";

    # Proxy headers
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # Log files
    access_log /var/log/nginx/${OE_CONFIG}-access.log;
    error_log /var/log/nginx/${OE_CONFIG}-error.log;

    # Increase proxy buffer size
    proxy_buffers 16 64k;
    proxy_buffer_size 128k;
    
    # Proxy timeouts
    proxy_read_timeout 900s;
    proxy_connect_timeout 900s;
    proxy_send_timeout 900s;
    
    # General proxy settings
    proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
    
    # Add Headers for odoo proxy mode
    proxy_set_header X-Forwarded-Host \$host;
    
    # Compression
    gzip on;
    gzip_min_length 1100;
    gzip_buffers 4 32k;
    gzip_types text/css text/less text/plain text/xml application/xml application/json application/javascript application/pdf image/jpeg image/png;
    gzip_vary on;
    
    # Client header buffers
    client_header_buffer_size 4k;
    large_client_header_buffers 4 64k;
    client_max_body_size 0;
    
    # Specifies the maximum accepted body size of a client request
    # as indicated by the request header Content-Length. Set to 0 to disable
    client_max_body_size 500m;

    # Handle longpoll requests
    location /longpolling {
        proxy_pass http://odoochat;
    }

    # Handle / requests
    location / {
        proxy_redirect off;
        proxy_pass http://odoo;
    }

    # Cache static files
    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo;
    }

    # Cache static assets
    location ~* .(js|css|png|jpg|jpeg|gif|ico)$ {
        expires 7d;
        proxy_cache_valid 200 48h;
        proxy_buffering on;
        proxy_pass http://odoo;
        add_header Cache-Control "public, no-transform";
    }
}
EOF

    # Enable the site
    ln -s /etc/nginx/sites-available/${OE_CONFIG} /etc/nginx/sites-enabled/${OE_CONFIG}
    rm -f /etc/nginx/sites-enabled/default
    
    log "INFO" "Testing Nginx configuration..."
    nginx -t
    
    log "INFO" "Restarting Nginx..."
    systemctl restart nginx
    
    # Update Odoo config to use Nginx proxy
    sed -i "s/proxy_mode = False/proxy_mode = True/" /etc/${OE_CONFIG}.conf
    
    log "INFO" "Nginx installed and configured for Odoo"
else
    log "INFO" "Nginx installation skipped based on user preference"
fi

#--------------------------------------------------
# Enable SSL with certbot if requested
#--------------------------------------------------
if [ $INSTALL_NGINX = "True" ] && [ $ENABLE_SSL = "True" ] && [ $ADMIN_EMAIL != "odoo@example.com" ] && [ $WEBSITE_NAME != "_" ]; then
    log "INFO" "Setting up SSL with Let's Encrypt..."
    
    # Install certbot
    apt-get update
    apt-get install snapd -y
    snap install core
    snap refresh core
    snap install --classic certbot
    ln -s /snap/bin/certbot /usr/bin/certbot
    
    # Request and install the certificate
    certbot --nginx -d $WEBSITE_NAME --noninteractive --agree-tos --email $ADMIN_EMAIL --redirect
    
    log "INFO" "SSL/HTTPS is enabled!"
    
    # Setup auto-renewal
    log "INFO" "Setting up automatic SSL certificate renewal..."
    echo "0 0 1 * * certbot renew --quiet" | crontab -
else
    if [ $ENABLE_SSL = "True" ]; then
        log "WARNING" "SSL/HTTPS isn't enabled due to missing configuration!"
        if [ $ADMIN_EMAIL = "odoo@example.com" ]; then
            log "WARNING" "Certbot does not support registration with odoo@example.com. Use a real email address."
        fi
        if [ $WEBSITE_NAME = "_" ]; then
            log "WARNING" "Website name is set as _. Cannot obtain SSL Certificate. Use a real domain name."
        fi
    else
        log "INFO" "SSL/HTTPS isn't enabled based on user preference."
    fi
fi

#--------------------------------------------------
# Setup Odoo auto backup (Bitnami inspired)
#--------------------------------------------------
log "INFO" "Setting up automated database backups..."

# Create backup directory
mkdir -p /var/backups/odoo
chown $OE_USER:$OE_USER /var/backups/odoo

# Create backup script
cat <<EOF > /usr/local/bin/odoo-backup.sh
#!/bin/bash
# Odoo automated backup script
BACKUP_DIR="/var/backups/odoo"
ODOO_DATABASE="postgres"
BACKUP_DAYS=7

# Create backup directory if not exists
mkdir -p \$BACKUP_DIR

# Get current date
NOW=\$(date +"%Y-%m-%d_%H-%M-%S")

# Create database backup
su - $OE_USER -c "pg_dump \$ODOO_DATABASE" > "\$BACKUP_DIR/odoo_db_\$NOW.sql"

# Compress backup
gzip -f "\$BACKUP_DIR/odoo_db_\$NOW.sql"

# Create filestore backup (if it exists)
if [ -d "$OE_HOME/.local/share/Odoo/filestore" ]; then
    tar -zcf "\$BACKUP_DIR/odoo_filestore_\$NOW.tar.gz" -C "$OE_HOME/.local/share/Odoo/filestore" .
fi

# Delete old backups
find \$BACKUP_DIR -name "odoo_db_*.sql.gz" -mtime +\$BACKUP_DAYS -delete
find \$BACKUP_DIR -name "odoo_filestore_*.tar.gz" -mtime +\$BACKUP_DAYS -delete

echo "Backup completed: \$NOW"
EOF

# Make the backup script executable
chmod +x /usr/local/bin/odoo-backup.sh

# Create a cron job for daily backups at 2 AM
echo "0 2 * * * /usr/local/bin/odoo-backup.sh >> /var/log/odoo-backup.log 2>&1" > /etc/cron.d/odoo-backup
chmod 644 /etc/cron.d/odoo-backup

log "INFO" "Automated backup system configured to run daily at 2 AM"

#--------------------------------------------------
# Setup security recommendations (Bitnami inspired)
#--------------------------------------------------
log "INFO" "Implementing security recommendations..."

# Create a dedicated group for accessing Odoo config with password
groupadd odoo-config
usermod -a -G odoo-config $OE_USER
chgrp odoo-config /etc/${OE_CONFIG}.conf
chmod 640 /etc/${OE_CONFIG}.conf

# Set up proper file permissions
find $OE_HOME_EXT -type d -exec chmod 755 {} \;
find $OE_HOME_EXT -type f -exec chmod 644 {} \;
find $OE_HOME_EXT/odoo/addons -type d -exec chmod 755 {} \;
find $OE_HOME_EXT/odoo/addons -type f -exec chmod 644 {} \;

# Make Odoo binary executable
chmod 755 $OE_HOME_EXT/odoo-bin

# Random password generation for Odoo admin user
if [ $GENERATE_RANDOM_PASSWORD = "True" ]; then
    log "INFO" "Generating random admin password..."
    OE_SUPERADMIN=$(< /dev/urandom tr -dc 'A-Za-z0-9!#$%&()*+,-./:;<=>?@[\]^_`{|}~' | head -c20)
    
    # Update the configuration file with the new password
    sed -i "s/admin_passwd = .*/admin_passwd = ${OE_SUPERADMIN}/" /etc/${OE_CONFIG}.conf
    
    # Store the password in a secure location
    echo "Odoo superadmin password: $OE_SUPERADMIN" > /root/.odoo_admin_password
    chmod 600 /root/.odoo_admin_password
fi

#--------------------------------------------------
# Start Odoo Service
#--------------------------------------------------
log "INFO" "Starting Odoo Service..."
systemctl start ${OE_CONFIG}

# Check if Odoo is running
sleep 5
if systemctl is-active --quiet ${OE_CONFIG}; then
    log "INFO" "Odoo service is running successfully!"
else
    log "ERROR" "Odoo service failed to start. Please check the logs at /var/log/$OE_USER/${OE_CONFIG}.log"
fi

#--------------------------------------------------
# Print installation summary
#--------------------------------------------------
log "INFO" "======================================================================"
log "INFO" "Odoo 18 Installation Complete!"
log "INFO" "----------------------------------------------------------------------"
log "INFO" "Odoo service name: $OE_CONFIG"
log "INFO" "Odoo server URL: http://localhost:$OE_PORT"
log "INFO" "User service: $OE_USER"
log "INFO" "Configuration file: /etc/${OE_CONFIG}.conf"
log "INFO" "Logs location: /var/log/$OE_USER/${OE_CONFIG}.log"
log "INFO" "PostgreSQL User: $OE_USER"
log "INFO" "Code location: $OE_HOME_EXT"
log "INFO" "Addons folder: $OE_HOME/custom/addons"
if [ $GENERATE_RANDOM_PASSWORD = "True" ]; then
    log "INFO" "Admin password: Stored in /root/.odoo_admin_password"
else
    log "INFO" "Admin password: $OE_SUPERADMIN"
fi
log "INFO" "Workers: $WORKERS"
log "INFO" "----------------------------------------------------------------------"
log "INFO" "Start Odoo service: sudo systemctl start $OE_CONFIG"
log "INFO" "Stop Odoo service: sudo systemctl stop $OE_CONFIG"
log "INFO" "Restart Odoo service: sudo systemctl restart $OE_CONFIG"
log "INFO" "Check Odoo status: sudo systemctl status $OE_CONFIG"
log "INFO" "View logs: sudo tail -f /var/log/$OE_USER/${OE_CONFIG}.log"
if [ $INSTALL_NGINX = "True" ]; then
    log "INFO" "Nginx configuration: /etc/nginx/sites-available/${OE_CONFIG}"
    log "INFO" "Website URL: http://${WEBSITE_NAME}"
    if [ $ENABLE_SSL = "True" ] && [ $ADMIN_EMAIL != "odoo@example.com" ] && [ $WEBSITE_NAME != "_" ]; then
        log "INFO" "Secure Website URL: https://${WEBSITE_NAME}"
        log "INFO" "SSL certificates: /etc/letsencrypt/live/${WEBSITE_NAME}"
    fi
fi
log "INFO" "======================================================================"
log "INFO" "Installation Completed Successfully!"
log "INFO" "======================================================================"
