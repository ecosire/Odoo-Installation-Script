#!/bin/bash

# Script Variables
OE_USER="odoo"
OE_VERSION="17.0"
IS_ENTERPRISE="False"
INSTALL_WKHTMLTOPDF="True"
INSTALL_POSTGRESQL="True"
POSTGRESQL_VERSION="16"
INSTALL_NGINX="True"
ENABLE_SSL="True"
ADMIN_EMAIL="ecosire@gmail.com"
OE_SUPERADMIN="admin"
OE_CONFIG="${OE_USER}-server"
OE_PORT="8069"
LONGPOLLING_PORT="8072"

# System Update
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y software-properties-common

# PostgreSQL Installation
if [ "$INSTALL_POSTGRESQL" = "True" ]; then
    if [ "$POSTGRESQL_VERSION" != "default" ]; then
        wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
        sudo sh -c "echo 'deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main' > /etc/apt/sources.list.d/pgdg.list"
        sudo apt-get update
        sudo apt-get install -y postgresql-$POSTGRESQL_VERSION postgresql-client-$POSTGRESQL_VERSION
    else
        sudo apt-get install -y postgresql postgresql-contrib
    fi
fi

# Create Odoo user
sudo adduser --system --quiet --shell=/bin/bash --home=/opt/$OE_USER --group $OE_USER

# Install Dependencies
sudo apt-get install -y git python3-pip build-essential wget python3-dev python3-venv python3-wheel libxslt-dev libzip-dev libldap2-dev libsasl2-dev python3-setuptools node-less

# Wkhtmltopdf Installation
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
    # Install based on Ubuntu version
    ARCH=$(arch)
    if [ "$ARCH" = "x86_64" ]; then
        WKHTMLTOX_ARCH="amd64"
    else
        WKHTMLTOX_ARCH="i386"
    fi
    WKHTMLTOX_URL="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.6/wkhtmltox_0.12.6-1.$(lsb_release -cs)_${WKHTMLTOX_ARCH}.deb"
    wget $WKHTMLTOX_URL
    sudo apt install -y ./*.deb
    rm *.deb
fi

# Clone Odoo from GitHub
sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo /opt/$OE_USER/$OE_VERSION

# Python dependencies and virtualenv
sudo python3 -m venv /opt/$OE_USER/venv
source /opt/$OE_USER/venv/bin/activate
pip3 install wheel
pip3 install -r /opt/$OE_USER/$OE_VERSION/requirements.txt
deactivate

# Odoo Configuration
sudo cp /opt/$OE_USER/$OE_VERSION/debian/odoo.conf /etc/${OE_CONFIG}.conf
sudo sed -i "s,^\(admin_passwd =\).*,\1 $OE_SUPERADMIN," /etc/${OE_CONFIG}.conf
sudo sed -i "s,^\(xmlrpc_port =\).*,\1 $OE_PORT," /etc/${OE_CONFIG}.conf
sudo sed -i "s,^\(logfile =\).*,\1 /var/log/$OE_USER/$OE_CONFIG.log," /etc/${OE_CONFIG}.conf
echo "addons_path = /opt/$OE_USER/$OE_VERSION/addons" | sudo tee -a /etc/${OE_CONFIG}.conf
sudo chown $OE_USER: /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

# Odoo Service
echo -e "[Unit]\nDescription=Odoo\nRequires=postgresql.service\nAfter=network.target postgresql.service\n\n[Service]\nType=simple\nUser=$OE_USER\nGroup=$OE_USER\nExecStart=/opt/$OE_USER/venv/bin/python3 /opt/$OE_USER/$OE_VERSION/odoo-bin -c /etc/${OE_CONFIG}.conf\n\n[Install]\nWantedBy=multi-user.target" | sudo tee /etc/systemd/system/${OE_CONFIG}.service
sudo systemctl daemon-reload
sudo systemctl enable ${OE_CONFIG}.service
sudo systemctl start ${OE_CONFIG}.service

# Nginx Configuration
if [ "$INSTALL_NGINX" = "True" ]; then
    sudo apt-get install -y nginx
    # Additional Nginx configuration steps go here
fi

# SSL Configuration
if [ "$ENABLE_SSL" = "True" ]; then
    # SSL configuration steps go here
fi

echo "Odoo installation has completed."
echo "You can access the web interface at: http://localhost:$OE_PORT"
