#!/bin/bash
################################################################################
# Script for installing Odoo 18 on Debian 12 (Bookworm)
# Based on scripts by ecosire
#-------------------------------------------------------------------------------
# This script will install Odoo 18 on your Debian server. It can install
# multiple Odoo instances by using different ports and instance names.
# Features: Nginx reverse proxy, SSL with Let's Encrypt, Python virtual env,
# automated backups, UFW firewall, SSH hardening.
#-------------------------------------------------------------------------------
# PRE-REQUISITES:
# 1. A clean Debian 12 (Bookworm) server.
# 2. Root privileges (run with sudo).
# 3. If using SSL, a Fully Qualified Domain Name (FQDN) pointing to your server's IP.
# 4. For SSH hardening (disabling password auth), ensure SSH key-based login is set up.
#
# USAGE:
# 1. Save this script: e.g., sudo nano odoo_debian_install.sh
# 2. Make it executable: sudo chmod +x odoo_debian_install.sh
# 3. Configure variables below.
# 4. Run the script: sudo ./odoo_debian_install.sh
################################################################################

# --- Script Execution Settings ---
set -e  # Exit immediately if a command exits with a non-zero status.
set -u  # Treat unset variables as an error when substituting.
set -o pipefail # The return value of a pipeline is the status of the last command to exit with a non-zero status

# --- Basic Configuration ---
# Instance name: Used for service name, config file, user (if OE_USER_PREFIX is used), etc.
# Keep it short, alphanumeric, no spaces. e.g., "prod", "staging", "myodoo"
INSTANCE_NAME="odoo18"

# Enable interactive prompts for key configurations.
# Set to "False" for fully unattended execution using script variables.
ENABLE_INTERACTIVE_PROMPTS="False"

# Set to true to enable debug mode (more verbose output)
DEBUG_MODE="False"

# Odoo system user.
# If OE_CREATE_INSTANCE_USER is true, user will be ${INSTANCE_NAME} (e.g., odoo18).
# Otherwise, it will be the fixed OE_DEFAULT_USER.
OE_CREATE_INSTANCE_USER="True" # Recommended: True for better isolation of multiple instances
OE_DEFAULT_USER="odoo"         # Used if OE_CREATE_INSTANCE_USER is False

# Odoo home directory base. Full path will be /opt/${OE_USER}
OE_BASE_DIR="/opt"

# Set to true if you want to install Wkhtmltopdf.
INSTALL_WKHTMLTOPDF="True"

# Default port for Odoo. Each instance should have a unique port.
OE_PORT="8069"
# Default long polling port. Each instance should have a unique port.
LONGPOLLING_PORT="8072"

# Odoo version.
OE_VERSION="18.0"

# Set to True to install Odoo Enterprise. Requires GitHub access to the private repo.
IS_ENTERPRISE="False"
# If IS_ENTERPRISE is "True", provide your GitHub Personal Access Token (PAT)
# with repo access. Leave empty if your SSH key is configured for git.
# ODOO_ENTERPRISE_PAT="" # Example: "ghp_YourTokenHere"

# Install PostgreSQL v15 (Default for Debian 12).
INSTALL_POSTGRESQL="True"
PG_VERSION="15" # Ensure this matches Debian 12's available version or your custom install

# Install and configure Nginx as a reverse proxy.
INSTALL_NGINX="True"

# Odoo superadmin password.
# If GENERATE_RANDOM_PASSWORD is "True", this will be overridden.
OE_SUPERADMIN_PASSWORD_DEFAULT="admin"
# Set to "True" to generate a strong random password for Odoo master admin.
GENERATE_RANDOM_PASSWORD="True"
# Location to store the generated admin password if GENERATE_RANDOM_PASSWORD is True.
ADMIN_PASSWORD_FILE="/root/.${INSTANCE_NAME}_admin_passwd"

# Website domain name for Nginx and SSL. Use "_" for localhost or IP access (no SSL).
# For SSL, this MUST be a Fully Qualified Domain Name (FQDN).
WEBSITE_NAME="yourdomain.com" # Replace with your actual domain or "_"

# Enable SSL with Let's Encrypt (Certbot).
# Requires INSTALL_NGINX="True", a valid WEBSITE_NAME (not "_"), and a valid ADMIN_EMAIL.
ENABLE_SSL="False" # Set to True and configure WEBSITE_NAME and ADMIN_EMAIL for SSL

# Email address for Let's Encrypt SSL certificate registration.
ADMIN_EMAIL="youremail@example.com" # Replace with your actual email for SSL

# --- Performance Tuning (Customize based on your server resources) ---
CPU_CORES_DETECTED=$(nproc --all)
# Number of Odoo workers. 0 = auto-calculate (CPU cores * 2 + 1, capped).
WORKERS=$(( CPU_CORES_DETECTED > 0 ? (CPU_CORES_DETECTED * 2 + 1 > 8 ? 8 : CPU_CORES_DETECTED * 2 + 1) : 4 ))
# Max cron threads.
MAX_CRON_THREADS=$(( CPU_CORES_DETECTED > 0 ? (CPU_CORES_DETECTED > 2 ? 2 : CPU_CORES_DETECTED) : 2 ))
# Memory limits for Odoo workers (bytes).
LIMIT_MEMORY_HARD=$((2560 * 1024 * 1024)) # 2.5GB
LIMIT_MEMORY_SOFT=$((2048 * 1024 * 1024)) # 2GB
# CPU time limits for Odoo workers (seconds).
LIMIT_TIME_CPU=600
LIMIT_TIME_REAL=1200

# --- PostgreSQL Performance Tuning ---
DB_MAX_CONNECTIONS=150
DB_SHARED_BUFFERS="1GB"
DB_EFFECTIVE_CACHE_SIZE="3GB"
DB_WORK_MEM="32MB"
DB_MAINTENANCE_WORK_MEM="256MB"

# --- Advanced Odoo Configuration ---
ENABLE_MULTIPROCESSING="True"
ENABLE_SYSLOG="True"
LOG_LEVEL="info" # debug, info, warning, error, critical
ENABLE_DB_FILTERING="True"
DB_FILTER=".*"

# --- Backup Configuration ---
ENABLE_AUTO_BACKUP="True"
BACKUP_DIR_BASE="/var/backups"
BACKUP_DAYS_TO_KEEP=7
BACKUP_SCHEDULE="0 2 * * *" # Daily at 2 AM

# --- Security Hardening ---
ENABLE_SSH_HARDENING="False" # Set to True to apply SSH hardening (disables root & password login)
ENABLE_UFW_FIREWALL="True"

# --- Color Definitions ---
USE_COLORS="True"
if [ "$USE_COLORS" = "True" ]; then
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    GREEN=''; YELLOW=''; RED=''; BLUE=''; NC=''
fi

# --- Helper Functions ---
log_msg() { # Renamed from log to avoid conflict if 'log' command exists
    local level_color W_level=$1; shift; local message="$@"
    if [ "$W_level" = "DEBUG" ] && [ "$DEBUG_MODE" != "True" ]; then return; fi
    case "$W_level" in
        INFO) level_color="$BLUE";;
        SUCCESS) level_color="$GREEN";;
        WARNING) level_color="$YELLOW";;
        ERROR) level_color="$RED";;
        *) level_color="$NC";;
    esac
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${level_color}[$W_level]${NC} - $message"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }
generate_password() { < /dev/urandom tr -dc 'A-Za-z0-9!#$%&()*+,-./:;<=>?@[\]^_`{|}~' | head -c24; }
check_command_success() { # Combines check_command from user script with log_msg
    if [ $? -ne 0 ]; then
        log_msg "ERROR" "$1"
        exit 1
    fi
}

# --- Derived Variables (DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING) ---
OE_USER=$( [ "$OE_CREATE_INSTANCE_USER" = "True" ] && echo "$INSTANCE_NAME" || echo "$OE_DEFAULT_USER" )
OE_HOME="${OE_BASE_DIR}/${OE_USER}"
OE_HOME_EXT="${OE_HOME}/server"
OE_PYTHON_VENV="${OE_HOME}/venv"
OE_CONFIG_FILE="/etc/${INSTANCE_NAME}.conf"
OE_SERVICE_NAME="${INSTANCE_NAME}.service"
OE_LOG_DIR="/var/log/${OE_USER}"
OE_LOG_FILE="${OE_LOG_DIR}/${INSTANCE_NAME}.log"
NGINX_CONFIG_FILE_AVAILABLE="/etc/nginx/sites-available/${INSTANCE_NAME}"
NGINX_CONFIG_FILE_ENABLED="/etc/nginx/sites-enabled/${INSTANCE_NAME}"
NGINX_LOG_DIR="/var/log/nginx"
BACKUP_DIR="${BACKUP_DIR_BASE}/${INSTANCE_NAME}"
BACKUP_SCRIPT_PATH="/usr/local/bin/${INSTANCE_NAME}-backup.sh"
BACKUP_LOG_FILE="${OE_LOG_DIR}/${INSTANCE_NAME}-backup.log"


# --- Interactive Prompts (If Enabled) ---
if [ "$ENABLE_INTERACTIVE_PROMPTS" = "True" ] && [ -t 0 ] && [ -t 1 ]; then
    log_msg "INFO" "Running in interactive mode for configuration."
    read -r -p "Enter desired Odoo Instance Name [${INSTANCE_NAME}]: " temp_instance_name
    INSTANCE_NAME=${temp_instance_name:-$INSTANCE_NAME}
    # Re-evaluate derived variables if INSTANCE_NAME changed
    OE_USER=$( [ "$OE_CREATE_INSTANCE_USER" = "True" ] && echo "$INSTANCE_NAME" || echo "$OE_DEFAULT_USER" )
    OE_HOME="${OE_BASE_DIR}/${OE_USER}"; OE_HOME_EXT="${OE_HOME}/server"; OE_PYTHON_VENV="${OE_HOME}/venv}"
    OE_CONFIG_FILE="/etc/${INSTANCE_NAME}.conf"; OE_SERVICE_NAME="${INSTANCE_NAME}.service"
    OE_LOG_DIR="/var/log/${OE_USER}"; OE_LOG_FILE="${OE_LOG_DIR}/${INSTANCE_NAME}.log"
    NGINX_CONFIG_FILE_AVAILABLE="/etc/nginx/sites-available/${INSTANCE_NAME}"; NGINX_CONFIG_FILE_ENABLED="/etc/nginx/sites-enabled/${INSTANCE_NAME}"
    ADMIN_PASSWORD_FILE="/root/.${INSTANCE_NAME}_admin_passwd"
    BACKUP_DIR="${BACKUP_DIR_BASE}/${INSTANCE_NAME}"; BACKUP_SCRIPT_PATH="/usr/local/bin/${INSTANCE_NAME}-backup.sh"; BACKUP_LOG_FILE="${OE_LOG_DIR}/${INSTANCE_NAME}-backup.log"


    read -r -p "Enter Odoo Port [${OE_PORT}]: " temp_port; OE_PORT=${temp_port:-$OE_PORT}
    read -r -p "Enter Longpolling Port [${LONGPOLLING_PORT}]: " temp_lport; LONGPOLLING_PORT=${temp_lport:-$LONGPOLLING_PORT}
    read -r -p "Install Odoo Enterprise? (y/N) [${IS_ENTERPRISE}]: " temp_is_enterprise
    IS_ENTERPRISE=$(echo "$temp_is_enterprise" | grep -qi "^y" && echo "True" || echo "False")

    read -r -p "Domain name for Nginx/SSL (e.g., odoo.example.com) [${WEBSITE_NAME}]: " temp_domain
    WEBSITE_NAME=${temp_domain:-$WEBSITE_NAME}
    read -r -p "Enable SSL with Let's Encrypt? (y/N) [${ENABLE_SSL}]: " temp_enable_ssl
    ENABLE_SSL=$(echo "$temp_enable_ssl" | grep -qi "^y" && echo "True" || echo "False")
    if [ "$ENABLE_SSL" = "True" ]; then
        read -r -p "Email for SSL certificate (required for Let's Encrypt) [${ADMIN_EMAIL}]: " temp_email
        ADMIN_EMAIL=${temp_email:-$ADMIN_EMAIL}
    fi
    read -r -p "Generate random Odoo Admin Password? (Y/n) [${GENERATE_RANDOM_PASSWORD}]: " temp_gen_pass
    GENERATE_RANDOM_PASSWORD=$(echo "$temp_gen_pass" | grep -qi "^n" && echo "False" || echo "True")
    if [ "$GENERATE_RANDOM_PASSWORD" = "False" ]; then
        read -r -s -p "Enter Odoo Admin Password [${OE_SUPERADMIN_PASSWORD_DEFAULT}]: " temp_admin_pass
        echo
        OE_SUPERADMIN_PASSWORD_DEFAULT=${temp_admin_pass:-$OE_SUPERADMIN_PASSWORD_DEFAULT}
    fi
fi

# --- Pre-flight Checks & Validation ---
log_msg "INFO" "Starting Odoo ${OE_VERSION} installation for instance: ${INSTANCE_NAME} on Debian"
if [ "$(id -u)" -ne 0 ]; then log_msg "ERROR" "This script must be run as root. Please use sudo."; exit 1; fi

OS_ID=$(grep -oP '(?<=^ID=).*' /etc/os-release | tr -d '"')
OS_VERSION_CODENAME=$(grep -oP '(?<=^VERSION_CODENAME=).*' /etc/os-release | tr -d '"')
if [[ "$OS_ID" != "debian" ]] || [[ "$OS_VERSION_CODENAME" != "bookworm" ]]; then
    log_msg "ERROR" "This script is intended for Debian 12 (bookworm)."
    log_msg "ERROR" "Detected OS: $OS_ID, Codename: $OS_VERSION_CODENAME."
    exit 1
fi
log_msg "INFO" "Detected Debian $OS_VERSION_CODENAME. Proceeding."

if [ "$INSTALL_NGINX" = "True" ] && [ "$ENABLE_SSL" = "True" ]; then
    if [ "$WEBSITE_NAME" = "_" ] || [ "$WEBSITE_NAME" = "yourdomain.com" ]; then
        log_msg "ERROR" "Website name must be a valid FQDN for SSL. Current: '$WEBSITE_NAME'"
        exit 1
    fi
    if [ "$ADMIN_EMAIL" = "youremail@example.com" ] || [ -z "$ADMIN_EMAIL" ]; then
        log_msg "ERROR" "A valid admin email is required for SSL. Current: '$ADMIN_EMAIL'"
        exit 1
    fi
fi
if [ "$ENABLE_SSH_HARDENING" = "True" ]; then
    log_msg "WARNING" "SSH Hardening is enabled. Ensure SSH key-based login is configured for your user, as password authentication will be disabled."
    sleep 5
fi

log_msg "INFO" "Odoo instance details:"
echo -e "  Instance Name: ${BLUE}${INSTANCE_NAME}${NC}"
echo -e "  Odoo User: ${BLUE}${OE_USER}${NC}"
echo -e "  Odoo Home: ${BLUE}${OE_HOME}${NC}"
echo -e "  Odoo Port: ${BLUE}${OE_PORT}${NC}"
echo -e "  Longpolling Port: ${BLUE}${LONGPOLLING_PORT}${NC}"
echo -e "  Enterprise Edition: ${BLUE}${IS_ENTERPRISE}${NC}"
[ "$INSTALL_NGINX" = "True" ] && echo -e "  Nginx Proxy: ${BLUE}Enabled${NC}" && \
    echo -e "    Website Name: ${BLUE}${WEBSITE_NAME}${NC}" && \
    echo -e "    SSL (Let's Encrypt): ${BLUE}${ENABLE_SSL}${NC}"
[ "$ENABLE_AUTO_BACKUP" = "True" ] && echo -e "  Automated Backups: ${BLUE}Enabled${NC}"
echo -e "  Workers: ${BLUE}${WORKERS}${NC}, Max Cron Threads: ${BLUE}${MAX_CRON_THREADS}${NC}"

# --- System Update and Base Dependencies ---
log_msg "INFO" "Updating system packages and installing base dependencies..."
export DEBIAN_FRONTEND=noninteractive # Avoid prompts
apt-get update -qq
check_command_success "Failed to update package lists"
apt-get upgrade -y -qq
check_command_success "Failed to upgrade packages"
apt-get install -y -qq software-properties-common gnupg2 curl wget git apt-transport-https dirmngr ca-certificates
check_command_success "Failed to install base dependencies"

# --- PostgreSQL Installation and Configuration ---
if [ "$INSTALL_POSTGRESQL" = "True" ]; then
    log_msg "INFO" "Installing PostgreSQL ${PG_VERSION}..."
    if ! command_exists psql || ! (psql --version | grep -q " ${PG_VERSION}\."); then
        # Debian 12 should have PG15 in main repo. If specific source needed:
        # curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
        # echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
        # apt-get update -qq
        apt-get install -y -qq "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" "postgresql-server-dev-${PG_VERSION}"
        check_command_success "Failed to install PostgreSQL ${PG_VERSION}"
    else
        log_msg "INFO" "PostgreSQL ${PG_VERSION} already installed or detected."
    fi

    PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
    PG_CONF="${PG_CONF_DIR}/postgresql.conf"
    PG_HBA="${PG_CONF_DIR}/pg_hba.conf"

    log_msg "INFO" "Configuring PostgreSQL ${PG_VERSION}..."
    if [ -f "$PG_CONF" ] && [ -f "$PG_HBA" ]; then
        [ ! -f "${PG_CONF}.orig_odoo_script" ] && cp "${PG_CONF}" "${PG_CONF}.orig_odoo_script"
        [ ! -f "${PG_HBA}.orig_odoo_script" ] && cp "${PG_HBA}" "${PG_HBA}.orig_odoo_script"

        sed -i "s/^#*max_connections = .*/max_connections = $DB_MAX_CONNECTIONS/" "$PG_CONF"
        grep -qxF "max_connections = $DB_MAX_CONNECTIONS" "$PG_CONF" || echo "max_connections = $DB_MAX_CONNECTIONS" >> "$PG_CONF"
        sed -i "s/^#*shared_buffers = .*/shared_buffers = $DB_SHARED_BUFFERS/" "$PG_CONF"
        grep -qxF "shared_buffers = $DB_SHARED_BUFFERS" "$PG_CONF" || echo "shared_buffers = $DB_SHARED_BUFFERS" >> "$PG_CONF"
        sed -i "s/^#*effective_cache_size = .*/effective_cache_size = $DB_EFFECTIVE_CACHE_SIZE/" "$PG_CONF"
        grep -qxF "effective_cache_size = $DB_EFFECTIVE_CACHE_SIZE" "$PG_CONF" || echo "effective_cache_size = $DB_EFFECTIVE_CACHE_SIZE" >> "$PG_CONF"
        sed -i "s/^#*work_mem = .*/work_mem = $DB_WORK_MEM/" "$PG_CONF"
        grep -qxF "work_mem = $DB_WORK_MEM" "$PG_CONF" || echo "work_mem = $DB_WORK_MEM" >> "$PG_CONF"
        sed -i "s/^#*maintenance_work_mem = .*/maintenance_work_mem = $DB_MAINTENANCE_WORK_MEM/" "$PG_CONF"
        grep -qxF "maintenance_work_mem = $DB_MAINTENANCE_WORK_MEM" "$PG_CONF" || echo "maintenance_work_mem = $DB_MAINTENANCE_WORK_MEM" >> "$PG_CONF"

        # Secure pg_hba.conf
        sed -i '/^local\s*all\s*all\s*peer$/!s/^local\s*all\s*all\s*.*/# &/' "$PG_HBA"
        grep -qxF "local   all             postgres                                peer" "$PG_HBA" || echo "local   all             postgres                                peer" >> "$PG_HBA"
        grep -qxF "local   all             all                                     peer" "$PG_HBA" || echo "local   all             all                                     peer" >> "$PG_HBA"
        grep -qxF "host    all             all             127.0.0.1/32            scram-sha-256" "$PG_HBA" || echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$PG_HBA"
        grep -qxF "host    all             all             ::1/128                 scram-sha-256" "$PG_HBA" || echo "host    all             all             ::1/128                 scram-sha-256" >> "$PG_HBA"
        grep -qxF "local   all             ${OE_USER}                                     scram-sha-256" "$PG_HBA" || echo "local   all             ${OE_USER}                                     scram-sha-256" >> "$PG_HBA"

        log_msg "INFO" "Restarting PostgreSQL service..."
        systemctl restart "postgresql@${PG_VERSION}-main"
        check_command_success "Failed to restart PostgreSQL"
        systemctl enable "postgresql@${PG_VERSION}-main"
        check_command_success "Failed to enable PostgreSQL"
    else
        log_msg "WARNING" "PostgreSQL config files not found at $PG_CONF_DIR. Skipping custom configuration."
    fi
fi

log_msg "INFO" "Creating PostgreSQL user '${OE_USER}'..."
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${OE_USER}'" | grep -q 1; then
    sudo -u postgres createuser --superuser "${OE_USER}"
    check_command_success "Failed to create PostgreSQL user ${OE_USER}"
else
    log_msg "INFO" "PostgreSQL user '${OE_USER}' already exists."
fi

# --- Python & Odoo Dependencies ---
log_msg "INFO" "Installing Python, build tools, and Odoo system dependencies..."
apt-get install -y -qq \
    python3 python3-pip python3-dev python3-venv python3-wheel \
    build-essential libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
    libtiff5-dev libjpeg62-turbo-dev libopenjp2-7-dev zlib1g-dev \
    libfreetype6-dev libwebp-dev libharfbuzz-dev libfribidi-dev \
    libxcb1-dev libpq-dev libevent-dev libffi-dev libssl-dev \
    libpng-dev libjpeg-dev # Added libssl-dev, libpng-dev, libjpeg-dev for good measure
check_command_success "Failed to install Python and Odoo system dependencies"

log_msg "INFO" "Installing Node.js and NPM for LESS/SASS compilation..."
# Debian 12 Bookworm provides Node.js 18.x which is usually sufficient.
# If a newer version is needed, use NodeSource.
if ! command_exists node; then
    # Using NodeSource for a more recent LTS version
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y -qq nodejs
    check_command_success "Failed to install Node.js"
else
    log_msg "INFO" "Node.js already installed. Version: $(node -v)"
fi
npm install -g rtlcss less less-plugin-clean-css
check_command_success "Failed to install global npm packages (rtlcss, less)"

# --- Install Wkhtmltopdf ---
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
    log_msg "INFO" "Installing wkhtmltopdf for Odoo PDF reports..."
    WKHTMLTOPDF_MAJOR_VERSION="0.12.6" # Base version for Odoo 16-18
    # Find a suitable package for Debian Bookworm
    WKHTMLTOPDF_FULL_VERSION="0.12.6.1-3" # Example, may need adjustment
    WKHTMLTOPDF_ARCH=$(dpkg --print-architecture)

    WKHTMLTOPDF_PKG="wkhtmltox_${WKHTMLTOPDF_FULL_VERSION}.bookworm_${WKHTMLTOPDF_ARCH}.deb"
    WKHTMLTOPDF_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_FULL_VERSION}/${WKHTMLTOPDF_PKG}"
    
    # Check local wkhtmltopdf version
    CURRENT_WKHTMLTOPDF_VERSION=$(wkhtmltopdf --version 2>/dev/null | grep -oP 'wkhtmltopdf \K[0-9\.]+')
    
    if [[ "$CURRENT_WKHTMLTOPDF_VERSION" == *"$WKHTMLTOPDF_MAJOR_VERSION"* ]]; then
        log_msg "INFO" "wkhtmltopdf version ${CURRENT_WKHTMLTOPDF_VERSION} (matching ${WKHTMLTOPDF_MAJOR_VERSION}.x) already installed. Skipping."
    else
        log_msg "INFO" "Attempting to install wkhtmltopdf version ${WKHTMLTOPDF_FULL_VERSION} for ${WKHTMLTOPDF_ARCH}."
        log_msg "DEBUG" "Downloading wkhtmltopdf from $WKHTMLTOPDF_URL"
        # Dependencies for wkhtmltopdf from .deb
        apt-get install -y -qq libxrender1 libfontconfig1 libxext6 xfonts-base xfonts-75dpi libjpeg62-turbo libpng16-16
        check_command_success "Failed to install wkhtmltopdf dependencies"

        wget -q "$WKHTMLTOPDF_URL" -O "/tmp/${WKHTMLTOPDF_PKG}"
        if [ $? -eq 0 ]; then
            dpkg -i "/tmp/${WKHTMLTOPDF_PKG}" || apt-get -fy install # Try to fix broken dependencies if dpkg fails
            check_command_success "Failed to install wkhtmltopdf package /tmp/${WKHTMLTOPDF_PKG}"
            rm -f "/tmp/${WKHTMLTOPDF_PKG}"

            ln -snf /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf
            ln -snf /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage
            log_msg "SUCCESS" "wkhtmltopdf ${WKHTMLTOPDF_FULL_VERSION} installation completed."
        else
            log_msg "WARNING" "Failed to download ${WKHTMLTOPDF_PKG}. Trying 'apt install wkhtmltopdf' as fallback (might be older version)."
            apt-get install -y -qq wkhtmltopdf
            if ! wkhtmltopdf --version | grep -q "$WKHTMLTOPDF_MAJOR_VERSION"; then
                 log_msg "WARNING" "Installed wkhtmltopdf via apt is not version ${WKHTMLTOPDF_MAJOR_VERSION}.x. PDF rendering might have issues."
            else
                 log_msg "SUCCESS" "wkhtmltopdf (from apt) installation completed."
            fi
        fi
    fi
else
    log_msg "INFO" "Skipping wkhtmltopdf installation."
fi


# --- Create Odoo System User & Directories ---
log_msg "INFO" "Creating Odoo system user '${OE_USER}' and directories..."
if ! id -u "${OE_USER}" >/dev/null 2>&1; then
    groupadd --system "${OE_USER}" || log_msg "DEBUG" "Group ${OE_USER} already exists."
    adduser --system --quiet --home "${OE_HOME}" --shell=/bin/bash --ingroup "${OE_USER}" --gecos "Odoo instance ${INSTANCE_NAME}" "${OE_USER}"
    check_command_success "Failed to create Odoo system user ${OE_USER}"
else
    log_msg "INFO" "System user '${OE_USER}' already exists."
    mkdir -p "${OE_HOME}"
    chown -R "${OE_USER}":"${OE_USER}" "${OE_HOME}"
fi
# Log directory
mkdir -p "${OE_LOG_DIR}"
chown "${OE_USER}":"${OE_USER}" "${OE_LOG_DIR}"
chmod 750 "${OE_LOG_DIR}"

# --- Python Virtual Environment & Odoo Source Code ---
log_msg "INFO" "Setting up Python virtual environment in ${OE_PYTHON_VENV}..."
sudo -u "${OE_USER}" python3 -m venv "${OE_PYTHON_VENV}"
check_command_success "Failed to create Python virtual environment"

log_msg "INFO" "Installing core Python dependencies for Odoo ${OE_VERSION} into venv..."
# shellcheck source=/dev/null
sudo -u "${OE_USER}" bash -c "source ${OE_PYTHON_VENV}/bin/activate && pip install --upgrade pip wheel setuptools psycopg2-binary"
check_command_success "Failed to install core pip packages into venv"

log_msg "INFO" "Cloning Odoo ${OE_VERSION} from GitHub into ${OE_HOME_EXT}..."
if [ -d "${OE_HOME_EXT}/.git" ]; then
    log_msg "INFO" "Odoo source code already exists. Fetching updates..."
    sudo -u "${OE_USER}" git -C "${OE_HOME_EXT}" fetch origin "${OE_VERSION}"
    sudo -u "${OE_USER}" git -C "${OE_HOME_EXT}" reset --hard "origin/${OE_VERSION}"
    check_command_success "Failed to update Odoo source"
else
    sudo -u "${OE_USER}" git clone --depth 1 --branch "${OE_VERSION}" https://github.com/odoo/odoo.git "${OE_HOME_EXT}"
    check_command_success "Failed to clone Odoo community repository"
fi

log_msg "INFO" "Installing Odoo Python requirements from ${OE_HOME_EXT}/requirements.txt..."
REQUIREMENTS_FILE="${OE_HOME_EXT}/requirements.txt"
if [ -f "$REQUIREMENTS_FILE" ]; then
    # Some packages in requirements.txt might need specific handling or versions
    # Pin Werkzeug for Odoo versions that require it (e.g. Odoo < 17 often needs < 2.4 or < 3.0)
    # For Odoo 18, this is less likely to be an issue, but good to be aware.
    # Example: sudo -u "${OE_USER}" bash -c "source ${OE_PYTHON_VENV}/bin/activate && pip install Werkzeug==2.3.7"
    sudo -u "${OE_USER}" bash -c "source ${OE_PYTHON_VENV}/bin/activate && pip install -r ${REQUIREMENTS_FILE}"
    check_command_success "Failed to install Odoo Python requirements from file"
else
    log_msg "ERROR" "Odoo requirements.txt not found at ${REQUIREMENTS_FILE}"
    exit 1
fi


# --- Enterprise Edition ---
OE_ENTERPRISE_DIR_ADDONS="${OE_HOME}/enterprise_addons" # Changed path to avoid conflict if 'enterprise' is a module name
if [ "$IS_ENTERPRISE" = "True" ]; then
    log_msg "INFO" "Setting up Odoo Enterprise Edition..."
    sudo -u "${OE_USER}" mkdir -p "${OE_ENTERPRISE_DIR_ADDONS}"

    ENTERPRISE_REPO_URL="https://github.com/odoo/enterprise.git"
    : "${ODOO_ENTERPRISE_PAT:=}"
    if [ -n "$ODOO_ENTERPRISE_PAT" ]; then
        ENTERPRISE_REPO_URL="https://${ODOO_ENTERPRISE_PAT}@github.com/odoo/enterprise.git"
        log_msg "INFO" "Using GitHub PAT for enterprise repository."
    else
        log_msg "INFO" "Using SSH key or cached credentials for enterprise repository."
        log_msg "WARNING" "Ensure your SSH key for user '${OE_USER}' (or current user if running git manually) has access to the Odoo Enterprise repository."
    fi

    log_msg "INFO" "Cloning Odoo Enterprise Edition (${OE_VERSION} branch)..."
    MAX_ATTEMPTS=3; CURRENT_ATTEMPT=0; CLONE_SUCCESS="false"
    while [ "$CLONE_SUCCESS" = "false" ] && [ $CURRENT_ATTEMPT -lt $MAX_ATTEMPTS ]; do
        CURRENT_ATTEMPT=$((CURRENT_ATTEMPT + 1))
        if sudo -u "${OE_USER}" git clone --depth 1 --branch "${OE_VERSION}" "${ENTERPRISE_REPO_URL}" "${OE_ENTERPRISE_DIR_ADDONS}"; then
            CLONE_SUCCESS="true"; log_msg "SUCCESS" "Odoo Enterprise cloned."
        else
            log_msg "WARNING" "Failed to clone Odoo Enterprise (Attempt ${CURRENT_ATTEMPT}/${MAX_ATTEMPTS})."
            # Simplified warning for script
            if [ $CURRENT_ATTEMPT -eq $MAX_ATTEMPTS ]; then log_msg "ERROR" "Max attempts reached. Check credentials/access."; exit 1; fi
            sleep 5
        fi
    done

    log_msg "INFO" "Installing Enterprise specific Python libraries..."
    ENTERPRISE_REQ_FILE="${OE_ENTERPRISE_DIR_ADDONS}/requirements.txt"
    if [ -f "${ENTERPRISE_REQ_FILE}" ]; then
         sudo -u "${OE_USER}" bash -c "source ${OE_PYTHON_VENV}/bin/activate && pip install -r ${ENTERPRISE_REQ_FILE}"
         check_command_success "Failed to install enterprise requirements"
    else
        log_msg "WARNING" "Enterprise requirements.txt not found. Installing common known dependencies."
        sudo -u "${OE_USER}" bash -c "source ${OE_PYTHON_VENV}/bin/activate && pip install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL"
        check_command_success "Failed to install common enterprise dependencies"
    fi
fi

# --- Custom Addons Directory & Permissions ---
OE_CUSTOM_ADDONS_DIR="${OE_HOME}/custom_addons"
log_msg "INFO" "Creating custom addons directory at ${OE_CUSTOM_ADDONS_DIR}..."
sudo -u "${OE_USER}" mkdir -p "${OE_CUSTOM_ADDONS_DIR}"

log_msg "INFO" "Setting final permissions on Odoo home folder '${OE_HOME}'..."
# This chown might be redundant if user creation and git clone were done correctly as OE_USER
chown -R "${OE_USER}":"${OE_USER}" "${OE_HOME}"
find "${OE_HOME_EXT}" -type d -exec chmod 750 {} \;
find "${OE_HOME_EXT}" -type f -exec chmod 640 {} \;
if [ "$IS_ENTERPRISE" = "True" ] && [ -d "${OE_ENTERPRISE_DIR_ADDONS}" ]; then
    find "${OE_ENTERPRISE_DIR_ADDONS}" -type d -exec chmod 750 {} \;
    find "${OE_ENTERPRISE_DIR_ADDONS}" -type f -exec chmod 640 {} \;
fi
if [ -d "${OE_CUSTOM_ADDONS_DIR}" ]; then # Permissions for custom addons
    find "${OE_CUSTOM_ADDONS_DIR}" -type d -exec chmod 750 {} \;
    find "${OE_CUSTOM_ADDONS_DIR}" -type f -exec chmod 640 {} \;
fi
sudo -u "${OE_USER}" chmod u+x "${OE_HOME_EXT}/odoo-bin" # Ensure executable

# --- Odoo Configuration File ---
log_msg "INFO" "Creating Odoo configuration file '${OE_CONFIG_FILE}'..."
FINAL_OE_SUPERADMIN_PASSWORD="${OE_SUPERADMIN_PASSWORD_DEFAULT}"
if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    FINAL_OE_SUPERADMIN_PASSWORD=$(generate_password)
    echo "${FINAL_OE_SUPERADMIN_PASSWORD}" > "${ADMIN_PASSWORD_FILE}"
    chmod 600 "${ADMIN_PASSWORD_FILE}"; chown root:root "${ADMIN_PASSWORD_FILE}"
    log_msg "INFO" "Generated admin password stored in ${ADMIN_PASSWORD_FILE}"
fi

ADDONS_PATHS="${OE_CUSTOM_ADDONS_DIR},${OE_HOME_EXT}/addons" # Custom addons first
if [ "$IS_ENTERPRISE" = "True" ] && [ -d "${OE_ENTERPRISE_DIR_ADDONS}" ]; then
    ADDONS_PATHS="${OE_ENTERPRISE_DIR_ADDONS},${ADDONS_PATHS}" # Enterprise addons highest priority after custom
fi

cat <<EOF > "${OE_CONFIG_FILE}"
[options]
admin_passwd = ${FINAL_OE_SUPERADMIN_PASSWORD}
addons_path = ${ADDONS_PATHS}
http_port = ${OE_PORT}
logfile = ${OE_LOG_FILE}
logrotate = True
pidfile = /tmp/${INSTANCE_NAME}.pid
workers = ${WORKERS}
max_cron_threads = ${MAX_CRON_THREADS}
limit_memory_hard = ${LIMIT_MEMORY_HARD}
limit_memory_soft = ${LIMIT_MEMORY_SOFT}
limit_time_cpu = ${LIMIT_TIME_CPU}
limit_time_real = ${LIMIT_TIME_REAL}
db_host = False ; Uses local socket by default
db_port = False ; Uses local socket by default
db_user = ${OE_USER}
db_password = False ; Assumes peer/ident auth or scram-sha-256 for local PG user
db_maxconn = ${DB_MAX_CONNECTIONS}
db_template = template0
xmlrpc_interface = 127.0.0.1 # Recommended to bind to localhost if behind a proxy
longpolling_port = ${LONGPOLLING_PORT}
proxy_mode = $( [ "$INSTALL_NGINX" = "True" ] && echo "True" || echo "False" )
log_level = ${LOG_LEVEL}
syslog = $( [ "$ENABLE_SYSLOG" = "True" ] && echo "True" || echo "False" )
list_db = True
dbfilter = ${DB_FILTER}
# server_wide_modules = web,base_setup
# without_demo = all # Use 'all' to disable demo data for all new databases
EOF
chown "${OE_USER}":"${OE_USER}" "${OE_CONFIG_FILE}"; chmod 640 "${OE_CONFIG_FILE}"

# --- Systemd Service File ---
log_msg "INFO" "Creating systemd service file '${OE_SERVICE_NAME}'..."
cat <<EOF > "/etc/systemd/system/${OE_SERVICE_NAME}"
[Unit]
Description=Odoo ${OE_VERSION} instance ${INSTANCE_NAME}
Requires=postgresql.service network-online.target $([ "$INSTALL_NGINX" = "True" ] && echo "nginx.service" || echo "")
After=postgresql.service network-online.target $([ "$INSTALL_NGINX" = "True" ] && echo "nginx.service" || echo "")

[Service]
Type=simple
User=${OE_USER}
Group=${OE_USER}
PermissionsStartOnly=true
ExecStart=${OE_PYTHON_VENV}/bin/python3 ${OE_HOME_EXT}/odoo-bin --config=${OE_CONFIG_FILE}
StandardOutput=journal+console # Or null if Odoo logfile/syslog is preferred
StandardError=journal
KillMode=mixed
Restart=always
RestartSec=5s
WorkingDirectory=${OE_HOME_EXT} # Set working directory

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable "${OE_SERVICE_NAME}"
check_command_success "Failed to enable Odoo service ${OE_SERVICE_NAME}"

# --- Nginx Installation and Configuration ---
if [ "$INSTALL_NGINX" = "True" ]; then
    log_msg "INFO" "Installing and configuring Nginx..."
    if ! command_exists nginx; then apt-get install -y -qq nginx; fi
    check_command_success "Failed to install Nginx"
    mkdir -p "${NGINX_LOG_DIR}"

    cat <<EOF > "${NGINX_CONFIG_FILE_AVAILABLE}"
upstream ${INSTANCE_NAME}_odoo { server 127.0.0.1:${OE_PORT}; }
upstream ${INSTANCE_NAME}_odoochat { server 127.0.0.1:${LONGPOLLING_PORT}; }

server {
    listen 80;
    # listen [::]:80; # Uncomment for IPv6
    server_name ${WEBSITE_NAME};

    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    # add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; connect-src 'self' wss: https:; img-src 'self' data: https:; style-src 'self' 'unsafe-inline' https:; font-src 'self' data: https:;" always; # CSP: Tailor carefully!
    # Strict-Transport-Security will be added by Certbot if SSL is enabled

    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$host;

    access_log ${NGINX_LOG_DIR}/${INSTANCE_NAME}-access.log;
    error_log ${NGINX_LOG_DIR}/${INSTANCE_NAME}-error.log;

    proxy_buffers 32 64k; proxy_buffer_size 128k;
    proxy_read_timeout 720s; proxy_connect_timeout 720s; proxy_send_timeout 720s;
    client_max_body_size 512m;

    gzip on; gzip_vary on; gzip_proxied any; gzip_comp_level 6;
    gzip_types application/atom+xml application/geo+json application/javascript application/json application/ld+json application/manifest+json application/rdf+xml application/rss+xml application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/javascript text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/xml;

    location /longpolling { proxy_pass http://${INSTANCE_NAME}_odoochat; proxy_read_timeout 720s; }
    location / { proxy_pass http://${INSTANCE_NAME}_odoo; proxy_redirect off; }
    location ~* /web/static/ { proxy_cache_valid 200 60m; proxy_buffering on; expires 864000; proxy_pass http://${INSTANCE_NAME}_odoo; }
    location ~ /\. { deny all; }
}
EOF
    ln -snf "${NGINX_CONFIG_FILE_AVAILABLE}" "${NGINX_CONFIG_FILE_ENABLED}"
    if [ -f "/etc/nginx/sites-enabled/default" ] && [ "${WEBSITE_NAME}" != "_" ]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
    if nginx -t; then
        log_msg "INFO" "Nginx configuration OK. Restarting Nginx..."
        systemctl restart nginx; systemctl enable nginx
        check_command_success "Failed to restart/enable Nginx"
    else
        log_msg "ERROR" "Nginx configuration test failed. Check ${NGINX_CONFIG_FILE_AVAILABLE}"; exit 1;
    fi
fi

# --- SSL with Certbot ---
if [ "$INSTALL_NGINX" = "True" ] && [ "$ENABLE_SSL" = "True" ]; then
    log_msg "INFO" "Setting up SSL with Certbot for ${WEBSITE_NAME}..."
    if ! command_exists certbot; then
        # Try Debian package first, then snap
        if apt-cache show python3-certbot-nginx > /dev/null 2>&1; then
            apt-get install -y -qq python3-certbot-nginx
            check_command_success "Failed to install certbot via apt"
        else
            log_msg "INFO" "python3-certbot-nginx not found via apt, trying snap..."
            if ! command_exists snap; then apt-get install -y -qq snapd; snap wait system seed.loaded; fi
            check_command_success "Failed to install snapd"
            snap install core; snap refresh core
            snap install --classic certbot
            ln -snf /snap/bin/certbot /usr/bin/certbot
            check_command_success "Failed to install certbot via snap"
        fi
    fi
    if command_exists certbot; then
        certbot --nginx -d "${WEBSITE_NAME}" --non-interactive --agree-tos --email "${ADMIN_EMAIL}" --redirect --hsts --uir
        check_command_success "Certbot SSL certificate generation failed"
        log_msg "SUCCESS" "SSL/HTTPS enabled for ${WEBSITE_NAME}!"
        # Certbot package usually sets up a systemd timer for renewal.
    else
        log_msg "ERROR" "Certbot command not found. SSL setup failed."
    fi
fi

# --- Firewall (UFW) ---
if [ "$ENABLE_UFW_FIREWALL" = "True" ]; then
    log_msg "INFO" "Configuring UFW firewall..."
    if ! command_exists ufw; then apt-get install -y -qq ufw; fi
    check_command_success "Failed to install UFW"
    ufw allow ssh # ESSENTIAL!
    if [ "$INSTALL_NGINX" = "True" ]; then
        ufw allow 'Nginx Full' # HTTP & HTTPS
    else # Direct Odoo access
        ufw allow "${OE_PORT}/tcp"
        ufw allow "${LONGPOLLING_PORT}/tcp"
    fi
    if ! ufw status | grep -qw active; then
        yes | ufw enable # Auto-confirm enabling UFW
        log_msg "SUCCESS" "UFW enabled and configured."
    else
        log_msg "INFO" "UFW already active. Rules applied."
    fi
    # ufw status verbose # Optionally show status
fi

# --- SSH Hardening ---
if [ "$ENABLE_SSH_HARDENING" = "True" ]; then
    log_msg "INFO" "Applying SSH hardening..."
    SSHD_CONFIG="/etc/ssh/sshd_config"
    if [ -f "$SSHD_CONFIG" ]; then
        cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak_odoo_script"
        sed -i 's/^#*PermitRootLogin .*/PermitRootLogin no/' "$SSHD_CONFIG"
        sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' "$SSHD_CONFIG"
        sed -i 's/^#*X11Forwarding .*/X11Forwarding no/' "$SSHD_CONFIG"
        sed -i 's/^#*ClientAliveInterval .*/ClientAliveInterval 300/' "$SSHD_CONFIG"
        sed -i 's/^#*ClientAliveCountMax .*/ClientAliveCountMax 2/' "$SSHD_CONFIG"
        grep -qxF "AllowTcpForwarding no" "$SSHD_CONFIG" || echo "AllowTcpForwarding no" >> "$SSHD_CONFIG"
        # Test config before restart (requires sshd -t)
        if sshd -t; then
            systemctl restart sshd
            check_command_success "Failed to restart sshd after hardening"
            log_msg "SUCCESS" "SSH hardening applied. Root login and password authentication disabled."
        else
            log_msg "ERROR" "sshd_config test failed. Reverting changes from backup."
            cp "${SSHD_CONFIG}.bak_odoo_script" "$SSHD_CONFIG"
            systemctl restart sshd
        fi
    else
        log_msg "WARNING" "SSH config file ${SSHD_CONFIG} not found. Skipping SSH hardening."
    fi
fi


# --- Automated Backups ---
if [ "$ENABLE_AUTO_BACKUP" = "True" ]; then
    log_msg "INFO" "Setting up automated database backups for instance ${INSTANCE_NAME}..."
    mkdir -p "${BACKUP_DIR}"; chown "${OE_USER}":"${OE_USER}" "${BACKUP_DIR}"; chmod 750 "${BACKUP_DIR}"
    cat <<EOF > "${BACKUP_SCRIPT_PATH}"
#!/bin/bash
set -e; set -u; set -o pipefail
BACKUP_ROOT_DIR="${BACKUP_DIR}"; ODOO_USER="${OE_USER}"; ODOO_CONFIG_FILE="${OE_CONFIG_FILE}"
DAYS_TO_KEEP=${BACKUP_DAYS_TO_KEEP}; DATE_FORMAT=\$(date +"%Y%m%d_%H%M%S")
DATABASES=\$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres' AND datname <> '${OE_USER}';") # Exclude template, postgres, and user role DBs

log_b() { echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1 - \$2"; }
mkdir -p "\${BACKUP_ROOT_DIR}"
for DB_NAME in \${DATABASES}; do
    if [ -z "\$DB_NAME" ]; then continue; fi
    log_b "\$DB_NAME" "Starting backup for database: \$DB_NAME"
    BACKUP_FILE_DB="db_\${DB_NAME}_\${DATE_FORMAT}.sql.gz"
    BACKUP_FILE_FS="fs_\${DB_NAME}_\${DATE_FORMAT}.tar.gz"
    sudo -u postgres pg_dump "\$DB_NAME" | gzip > "\${BACKUP_ROOT_DIR}/\${BACKUP_FILE_DB}"
    log_b "\$DB_NAME" "Database dump complete: \${BACKUP_ROOT_DIR}/\${BACKUP_FILE_DB}"
    DATA_DIR_BASE=\$(grep -Po "^data_dir\\s*=\\s*\\K.*" "${ODOO_CONFIG_FILE}" || echo "${OE_HOME}/.local/share/Odoo")
    FILESTORE_PATH="\${DATA_DIR_BASE}/filestore/\${DB_NAME}"
    if [ -d "\${FILESTORE_PATH}" ]; then
        log_b "\$DB_NAME" "Backing up filestore from \${FILESTORE_PATH}..."
        tar -czf "\${BACKUP_ROOT_DIR}/\${BACKUP_FILE_FS}" -C "\$(dirname "\${FILESTORE_PATH}")" "\$(basename "\${FILESTORE_PATH}")"
        log_b "\$DB_NAME" "Filestore backup complete: \${BACKUP_ROOT_DIR}/\${BACKUP_FILE_FS}"
    else
        log_b "\$DB_NAME" "Filestore path \${FILESTORE_PATH} not found. Skipping."
    fi
done
log_b "SYSTEM" "Deleting backups older than \${DAYS_TO_KEEP} days..."
find "\${BACKUP_ROOT_DIR}" -name "db_*.sql.gz" -mtime +\${DAYS_TO_KEEP} -exec rm -f {} \; -print
find "\${BACKUP_ROOT_DIR}" -name "fs_*.tar.gz" -mtime +\${DAYS_TO_KEEP} -exec rm -f {} \; -print
log_b "SYSTEM" "Backup operations finished for instance ${INSTANCE_NAME}."
EOF
    chmod +x "${BACKUP_SCRIPT_PATH}"
    echo "${BACKUP_SCHEDULE} root ${BACKUP_SCRIPT_PATH} >> ${BACKUP_LOG_FILE} 2>&1" > "/etc/cron.d/${INSTANCE_NAME}-backup"
    chmod 644 "/etc/cron.d/${INSTANCE_NAME}-backup"
    log_msg "SUCCESS" "Automated backup system configured. Script: ${BACKUP_SCRIPT_PATH}"
fi

# --- Start Odoo Service & Final Summary ---
log_msg "INFO" "Starting Odoo instance '${INSTANCE_NAME}' service (${OE_SERVICE_NAME})..."
systemctl start "${OE_SERVICE_NAME}"
sleep 5 # Give it a moment
if systemctl is-active --quiet "${OE_SERVICE_NAME}"; then
    log_msg "SUCCESS" "Odoo service '${OE_SERVICE_NAME}' is running."
else
    log_msg "ERROR" "Odoo service '${OE_SERVICE_NAME}' failed to start. Check logs:"
    log_msg "ERROR" "  Journal: sudo journalctl -u ${OE_SERVICE_NAME} -n 100 --no-pager"
    log_msg "ERROR" "  Odoo Log: ${OE_LOG_FILE}"
fi

log_msg "INFO" "========================= ODOO INSTALLATION COMPLETE ========================="
echo -e "${GREEN}Odoo ${OE_VERSION} instance '${INSTANCE_NAME}' summary:${NC}"
echo -e "  Service Name: ${BLUE}${OE_SERVICE_NAME}${NC}"
echo -e "  System User: ${BLUE}${OE_USER}${NC} (Home: ${OE_HOME})"
echo -e "  Source: ${BLUE}${OE_HOME_EXT}${NC} (Venv: ${OE_PYTHON_VENV})"
[ "$IS_ENTERPRISE" = "True" ] && echo -e "  Enterprise Addons: ${BLUE}${OE_ENTERPRISE_DIR_ADDONS}${NC}"
echo -e "  Custom Addons: ${BLUE}${OE_CUSTOM_ADDONS_DIR}${NC}"
echo -e "  Config File: ${BLUE}${OE_CONFIG_FILE}${NC}"
echo -e "  Log File: ${BLUE}${OE_LOG_FILE}${NC}"
if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    echo -e "  Odoo Admin Password: ${YELLOW}Stored in ${ADMIN_PASSWORD_FILE}${NC}"
else
    echo -e "  Odoo Admin Password: ${YELLOW}${FINAL_OE_SUPERADMIN_PASSWORD} (CHANGE THIS IF WEAK!)${NC}"
fi
echo -e "  Odoo Port: ${BLUE}${OE_PORT}${NC}, Longpolling Port: ${BLUE}${LONGPOLLING_PORT}${NC}"
if [ "$INSTALL_NGINX" = "True" ]; then
    ACCESS_URL_SCHEME=$([ "$ENABLE_SSL" = "True" ] && echo "https" || echo "http")
    echo -e "  Nginx Config: ${BLUE}${NGINX_CONFIG_FILE_AVAILABLE}${NC}"
    echo -e "  Access URL: ${GREEN}${ACCESS_URL_SCHEME}://${WEBSITE_NAME}${NC}"
else
    echo -e "  Access URL (Direct): ${GREEN}http://<your_server_ip>:${OE_PORT}${NC}"
fi
[ "$ENABLE_AUTO_BACKUP" = "True" ] && echo -e "  Auto Backups: Dir: ${BLUE}${BACKUP_DIR}${NC}, Schedule: ${BACKUP_SCHEDULE}"
echo -e "${GREEN}Useful Commands:${NC}"
echo -e "  Start: ${YELLOW}sudo systemctl start ${OE_SERVICE_NAME}${NC}"
echo -e "  Stop: ${YELLOW}sudo systemctl stop ${OE_SERVICE_NAME}${NC}"
echo -e "  Restart: ${YELLOW}sudo systemctl restart ${OE_SERVICE_NAME}${NC}"
echo -e "  Status: ${YELLOW}sudo systemctl status ${OE_SERVICE_NAME}${NC}"
echo -e "  Logs (journal): ${YELLOW}sudo journalctl -u ${OE_SERVICE_NAME} -f -n 100${NC}"
echo -e "  Logs (app): ${YELLOW}sudo tail -f ${OE_LOG_FILE}${NC}"
log_msg "INFO" "=============================================================================="
exit 0
