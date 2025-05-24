#!/bin/bash
################################################################################
# Script for installing Odoo 18 on Ubuntu 22.04 LTS and 24.04 LTS
# Author: Based on scripts by Yenthe Van Ginneken
# Updated for Odoo 18 with enhancements for security, durability, and configurability.
#-------------------------------------------------------------------------------
# This script will install Odoo on your Ubuntu server. It can install multiple Odoo
# instances in one Ubuntu by using different ports and instance names.
#-------------------------------------------------------------------------------
# PRE-REQUISITES:
# 1. A clean Ubuntu 22.04 LTS or 24.04 LTS server.
# 2. Root privileges (run with sudo).
# 3. If using SSL, a Fully Qualified Domain Name (FQDN) pointing to your server's IP.
#
# USAGE:
# 1. Save this script: e.g., sudo nano odoo_install.sh
# 2. Make it executable: sudo chmod +x odoo_install.sh
# 3. Configure variables below.
# 4. Run the script: sudo ./odoo_install.sh
################################################################################

# --- Script Execution Settings ---
# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# The return value of a pipeline is the status of the last command to exit with a
# non-zero status, or zero if no command exited with a non-zero status.
set -o pipefail

# --- Basic Configuration ---
# Instance name: Used for service name, config file, user (if OE_USER_PREFIX is used), etc.
# Keep it short, alphanumeric, no spaces. e.g., "prod", "staging", "myodoo"
INSTANCE_NAME="odoo18"

# Set to true to enable debug mode (more verbose output)
DEBUG_MODE="False"

# Odoo system user.
# If OE_USER_PREFIX is true, user will be ${INSTANCE_NAME} (e.g., odoo18).
# Otherwise, it will be the fixed OE_DEFAULT_USER.
OE_CREATE_INSTANCE_USER="True" # Recommended: True for better isolation of multiple instances
OE_DEFAULT_USER="odoo" # Used if OE_CREATE_INSTANCE_USER is False

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

# Install PostgreSQL v16 (Recommended for Odoo 18).
INSTALL_POSTGRESQL_16="True"

# Install and configure Nginx as a reverse proxy.
INSTALL_NGINX="True"

# Odoo superadmin password.
# If GENERATE_RANDOM_PASSWORD is "True", this will be overridden.
OE_SUPERADMIN_PASSWORD_DEFAULT="admin"
# Set to "True" to generate a strong random password for Odoo master admin.
GENERATE_RANDOM_PASSWORD="True"
# Location to store the generated admin password if GENERATE_RANDOM_PASSWORD is True.
# Ensure this location is secure and readable only by root.
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
# Number of Odoo workers. 0 = auto-calculate (CPU cores * 2 + 1, capped).
WORKERS=0
# Max cron threads.
MAX_CRON_THREADS=2
# Memory limits for Odoo workers (bytes).
LIMIT_MEMORY_HARD=$((2560 * 1024 * 1024)) # 2.5GB
LIMIT_MEMORY_SOFT=$((2048 * 1024 * 1024)) # 2GB
# CPU time limits for Odoo workers (seconds).
LIMIT_TIME_CPU=600
LIMIT_TIME_REAL=1200

# --- PostgreSQL Performance Tuning ---
DB_MAX_CONNECTIONS=150 # Max connections to PostgreSQL
DB_SHARED_BUFFERS="1GB" # Typically 25% of system RAM for dedicated DB server
DB_EFFECTIVE_CACHE_SIZE="3GB" # Typically 50-75% of system RAM for dedicated DB server
DB_WORK_MEM="32MB"
DB_MAINTENANCE_WORK_MEM="256MB"

# --- Advanced Odoo Configuration ---
ENABLE_MULTIPROCESSING="True" # Use Odoo's multiprocessing.
ENABLE_SYSLOG="True" # Log to syslog.
LOG_LEVEL="info" # debug, info, warning, error, critical
ENABLE_DB_FILTERING="True" # Enable database filtering (e.g., based on hostname).
DB_FILTER=".*" # Regex to filter databases. ".*" allows all. Use "^%d$" for domain-based.

# --- Backup Configuration ---
ENABLE_AUTO_BACKUP="True"
BACKUP_DIR_BASE="/var/backups" # Base directory for backups
BACKUP_DAYS_TO_KEEP=7 # Number of days to keep backups
BACKUP_SCHEDULE="0 2 * * *" # Daily at 2 AM

# --- Internal Variables (Derived from configuration) ---
OE_USER=$( [ "$OE_CREATE_INSTANCE_USER" = "True" ] && echo "$INSTANCE_NAME" || echo "$OE_DEFAULT_USER" )
OE_HOME="${OE_BASE_DIR}/${OE_USER}"
OE_HOME_EXT="${OE_HOME}/server"
OE_CONFIG_FILE="/etc/${INSTANCE_NAME}.conf"
OE_SERVICE_NAME="${INSTANCE_NAME}.service"
OE_LOG_DIR="/var/log/${OE_USER}"
OE_LOG_FILE="${OE_LOG_DIR}/${INSTANCE_NAME}.log"
NGINX_CONFIG_FILE="/etc/nginx/sites-available/${INSTANCE_NAME}"
NGINX_LOG_DIR="/var/log/nginx"
BACKUP_DIR="${BACKUP_DIR_BASE}/${INSTANCE_NAME}"
BACKUP_SCRIPT_PATH="/usr/local/bin/${INSTANCE_NAME}-backup.sh"
BACKUP_LOG_FILE="${OE_LOG_DIR}/${INSTANCE_NAME}-backup.log"

# --- Helper Functions ---
log() {
    local level=$1
    shift
    local message="$@"
    if [ "$level" = "DEBUG" ] && [ "$DEBUG_MODE" != "True" ]; then
        return
    fi
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - [$level] - $message"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to calculate number of worker processes
calculate_workers() {
    local cpu_count=$(nproc)
    local calculated_workers=$((cpu_count * 2 + 1))
    # Cap workers for stability on smaller systems / general use
    [ $calculated_workers -gt 8 ] && calculated_workers=8
    echo $calculated_workers
}

# Function to generate a random password
generate_password() {
    < /dev/urandom tr -dc 'A-Za-z0-9!#$%&()*+,-./:;<=>?@[\]^_`{|}~' | head -c24
}

# --- Pre-flight Checks ---
log "INFO" "Starting Odoo ${OE_VERSION} installation for instance: ${INSTANCE_NAME}"

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    log "ERROR" "This script must be run as root. Please use sudo."
    exit 1
fi

# Check OS Version
OS_CODENAME=$(lsb_release -cs)
if [[ "$OS_CODENAME" != "jammy" && "$OS_CODENAME" != "noble" ]]; then
    log "ERROR" "This script is intended for Ubuntu 22.04 LTS (jammy) or 24.04 LTS (noble)."
    log "ERROR" "Detected OS: $(lsb_release -ds). Codename: $OS_CODENAME."
    exit 1
fi
log "INFO" "Detected Ubuntu $OS_CODENAME. Proceeding with installation."

# Check for essential commands
for cmd in git curl wget adduser useradd groupadd systemctl lsb_release nproc psql createuser; do
    if ! command_exists "$cmd"; then
        log "WARNING" "Command '$cmd' not found. Attempting to install dependencies, but this might indicate a minimal system."
    fi
done

# --- Update Server ---
log "INFO" "Updating server packages..."
apt-get update
apt-get upgrade -y
apt-get install -y software-properties-common apt-transport-https curl dirmngr gnupg2

# --- Install PostgreSQL Server ---
if [ "$INSTALL_POSTGRESQL_16" = "True" ]; then
    log "INFO" "Installing PostgreSQL 16..."
    if ! command_exists psql || ! (psql --version | grep -q " 16\."); then
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
        apt-get update
        apt-get install -y postgresql-16 postgresql-client-16 postgresql-server-dev-16
    else
        log "INFO" "PostgreSQL 16 already installed or detected. Skipping installation."
    fi

    PG_CONF_DIR="/etc/postgresql/16/main"
    PG_CONF="${PG_CONF_DIR}/postgresql.conf"
    PG_HBA="${PG_CONF_DIR}/pg_hba.conf"

    log "INFO" "Configuring PostgreSQL 16..."
    if [ -f "$PG_CONF" ] && [ -f "$PG_HBA" ]; then
        # Backup original configs if not already backed up by us
        [ ! -f "${PG_CONF}.orig_odoo_script" ] && cp "${PG_CONF}" "${PG_CONF}.orig_odoo_script"
        [ ! -f "${PG_HBA}.orig_odoo_script" ] && cp "${PG_HBA}" "${PG_HBA}.orig_odoo_script"

        # Apply settings (use sed to modify existing or append if not found)
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

        # More aggressive settings for larger instances (consider making these conditional or configurable)
        for setting in \
            "synchronous_commit = off" \
            "checkpoint_timeout = 15min" \
            "checkpoint_completion_target = 0.9" \
            "wal_buffers = 16MB" \
            "default_statistics_target = 500" \
            "random_page_cost = 1.1" \
            "effective_io_concurrency = 200" \
            "min_wal_size = 1GB" \
            "max_wal_size = 4GB"; do
            param=$(echo "$setting" | cut -d'=' -f1 | xargs)
            sed -i "s/^#*$param = .*/$setting/" "$PG_CONF"
            grep -qxF "$setting" "$PG_CONF" || echo "$setting" >> "$PG_CONF"
        done

        # Secure pg_hba.conf: only allow local connections for the Odoo user via md5
        # This is a basic secure setup. Adjust if DB is on a separate server.
        # Ensure peer for admin user and md5 for odoo user
        # Remove existing lines for "local all all" to avoid overly permissive defaults
        sed -i '/^local\s*all\s*all\s*peer$/!s/^local\s*all\s*all\s*.*/# &/' "$PG_HBA"
        sed -i '/^host\s*all\s*all\s*127.0.0.1\/32\s*ident$/!s/^host\s*all\s*all\s*127.0.0.1\/32\s*.*/# &/' "$PG_HBA"
        sed -i '/^host\s*all\s*all\s*::1\/128\s*ident$/!s/^host\s*all\s*all\s*::1\/128\s*.*/# &/' "$PG_HBA"

        # Add specific rules
        grep -qxF "local   all             postgres                                peer" "$PG_HBA" || echo "local   all             postgres                                peer" >> "$PG_HBA"
        grep -qxF "local   all             all                                     peer" "$PG_HBA" || echo "local   all             all                                     peer" >> "$PG_HBA" # For general local access if needed
        grep -qxF "host    all             all             127.0.0.1/32            scram-sha-256" "$PG_HBA" || echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$PG_HBA"
        grep -qxF "host    all             all             ::1/128                 scram-sha-256" "$PG_HBA" || echo "host    all             all             ::1/128                 scram-sha-256" >> "$PG_HBA"
        # Rule for Odoo user - this assumes DB user is $OE_USER
        # If OE_USER needs to connect from non-localhost, add rules here.
        grep -qxF "local   all             ${OE_USER}                                     scram-sha-256" "$PG_HBA" || echo "local   all             ${OE_USER}                                     scram-sha-256" >> "$PG_HBA"

        log "INFO" "Restarting PostgreSQL service..."
        systemctl restart postgresql
        systemctl enable postgresql
    else
        log "WARNING" "PostgreSQL config files not found at $PG_CONF_DIR. Skipping custom configuration."
    fi
else
    log "INFO" "Installing default PostgreSQL version from Ubuntu repositories..."
    apt-get install -y postgresql postgresql-client postgresql-server-dev-all
    log "INFO" "Default PostgreSQL installed. Manual tuning might be required for optimal performance."
fi

log "INFO" "Creating PostgreSQL user '${OE_USER}'..."
# Check if user exists before creating. Use -P for password prompt if needed, or set a password.
# For simplicity in script, we create a superuser. For higher security, create a non-superuser
# and grant specific database creation rights.
if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${OE_USER}'\"" | grep -q 1; then
    su - postgres -c "createuser --superuser ${OE_USER}"
    # Optionally, set a password for the PostgreSQL user ${OE_USER}
    # OE_USER_PG_PASSWORD=$(generate_password)
    # su - postgres -c "psql -c \"ALTER USER ${OE_USER} WITH PASSWORD '${OE_USER_PG_PASSWORD}';\""
    # log "INFO" "PostgreSQL user ${OE_USER} created with a random password. Store it securely if needed."
    # Add db_password = OE_USER_PG_PASSWORD to Odoo config if password is set.
else
    log "INFO" "PostgreSQL user '${OE_USER}' already exists."
fi


# --- Install Dependencies ---
log "INFO" "Installing Python, build tools, and other system dependencies..."
apt-get install -y python3 python3-pip python3-dev python3-venv python3-wheel \
    build-essential wget git libxslt1-dev libzip-dev libldap2-dev libpq-dev \
    libsasl2-dev python3-setuptools libxml2-dev libjpeg8-dev zlib1g-dev \
    libfreetype6-dev liblcms2-dev libwebp-dev libharfbuzz-dev libfribidi-dev libxcb1-dev \
    libevent-dev libffi-dev # Added libevent-dev and libffi-dev

log "INFO" "Installing Node.js and NPM for LESS compilation..."
# Install Node.js (e.g., LTS version)
if ! command_exists node; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y nodejs
else
    log "INFO" "Node.js already installed."
fi
npm install -g rtlcss less less-plugin-clean-css

log "INFO" "Creating Python virtual environment for Odoo instance ${INSTANCE_NAME}..."
# This ensures Python dependencies are isolated per instance.
OE_PYTHON_VENV="${OE_HOME}/venv"
# Create Odoo system user first (if not exists, handled later)
# Ensure OE_HOME exists with correct permissions before creating venv as OE_USER
mkdir -p "${OE_HOME}"
# User creation is done later, temporarily create dir structure as root, then chown

log "INFO" "Installing Python packages/requirements into virtual environment..."
# The virtual environment creation and package installation will be done after OE_USER is created
# and OE_HOME has correct permissions. This is a placeholder for the logic.

# --- Install Wkhtmltopdf ---
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
    log "INFO" "Installing wkhtmltopdf for Odoo PDF reports..."
    WKHTMLTOPDF_VERSION="0.12.6.1-2" # Odoo 17/18 usually requires 0.12.6.x
    WKHTMLTOPDF_ARCH="amd64"
    if [ "$(arch)" == "aarch64" ]; then
        WKHTMLTOPDF_ARCH="arm64"
    fi
    WKHTMLTOPDF_PKG="wkhtmltox_${WKHTMLTOPDF_VERSION}.$(lsb_release -cs)_${WKHTMLTOPDF_ARCH}.deb"
    WKHTMLTOPDF_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/${WKHTMLTOPDF_PKG}"

    if ! command_exists wkhtmltopdf || ! (wkhtmltopdf --version | grep -q "0.12.6"); then
        log "DEBUG" "Downloading wkhtmltopdf from $WKHTMLTOPDF_URL"
        wget -q "$WKHTMLTOPDF_URL" -O "/tmp/${WKHTMLTOPDF_PKG}"
        apt-get install -y "/tmp/${WKHTMLTOPDF_PKG}" libxrender1 libfontconfig1 libxext6 xfonts-base xfonts-75dpi
        rm -f "/tmp/${WKHTMLTOPDF_PKG}"

        # Create symlinks if they don't point to the correct binaries already
        # The .deb package usually places them in /usr/local/bin/
        ln -snf /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf
        ln -snf /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage
        log "INFO" "wkhtmltopdf installation completed."
    else
        log "INFO" "wkhtmltopdf 0.12.6.x already installed. Skipping."
    fi
else
    log "INFO" "Skipping wkhtmltopdf installation."
fi

# --- Create Odoo System User ---
log "INFO" "Creating Odoo system user '${OE_USER}'..."
if ! id -u "${OE_USER}" >/dev/null 2>&1; then
    groupadd --system "${OE_USER}" || log "DEBUG" "Group ${OE_USER} already exists or error creating."
    adduser --system --quiet --home "${OE_HOME}" --shell=/bin/bash --ingroup "${OE_USER}" --gecos "Odoo instance ${INSTANCE_NAME}" "${OE_USER}"
    # Add user to sudo group only if absolutely necessary and you understand the security implications.
    # For normal Odoo operation, this is NOT required.
    # adduser "${OE_USER}" sudo # Generally avoid this
else
    log "INFO" "System user '${OE_USER}' already exists."
    # Ensure home directory exists and has correct ownership if user already existed
    mkdir -p "${OE_HOME}"
    chown -R "${OE_USER}":"${OE_USER}" "${OE_HOME}"
fi

# Now create Python venv as OE_USER
log "INFO" "Setting up Python virtual environment in ${OE_PYTHON_VENV}..."
su - "${OE_USER}" -c "python3 -m venv ${OE_PYTHON_VENV}"
# Activate venv and install pip packages
log "INFO" "Installing core Python dependencies for Odoo ${OE_VERSION}..."
su - "${OE_USER}" -c "source ${OE_PYTHON_VENV}/bin/activate && pip install --upgrade pip wheel setuptools"
# Odoo's requirements.txt can be quite extensive.
# Note: Some packages might have OS-level dependencies already installed above.
# For robustness, consider a two-pass install or pre-installing tricky ones like psycopg2
# For psycopg2, it's better to use psycopg2-binary unless compiling for specific reasons
su - "${OE_USER}" -c "source ${OE_PYTHON_VENV}/bin/activate && pip install psycopg2-binary"
# Install Odoo requirements
# Using https may fail if git certs are not setup, consider cloning requirements.txt first or using http if necessary
REQUIREMENTS_URL="https://raw.githubusercontent.com/odoo/odoo/${OE_VERSION}/requirements.txt"
log "INFO" "Fetching requirements from ${REQUIREMENTS_URL}"
wget -q "${REQUIREMENTS_URL}" -O "/tmp/odoo_requirements.txt"
su - "${OE_USER}" -c "source ${OE_PYTHON_VENV}/bin/activate && pip install -r /tmp/odoo_requirements.txt"
rm -f "/tmp/odoo_requirements.txt"

# --- Create Log Directory ---
log "INFO" "Creating Log directory '${OE_LOG_DIR}'..."
mkdir -p "${OE_LOG_DIR}"
chown "${OE_USER}":"${OE_USER}" "${OE_LOG_DIR}"
chmod 750 "${OE_LOG_DIR}" # Restrict access to log directory

# --- Install Odoo from GitHub ---
log "INFO" "Cloning Odoo ${OE_VERSION} from GitHub into ${OE_HOME_EXT}..."
if [ -d "${OE_HOME_EXT}/.git" ]; then
    log "INFO" "Odoo source code already exists. Fetching updates..."
    su - "${OE_USER}" -c "cd ${OE_HOME_EXT} && git fetch origin ${OE_VERSION} && git reset --hard origin/${OE_VERSION}"
else
    # Ensure parent directory exists and has correct ownership for git clone
    mkdir -p "$(dirname "${OE_HOME_EXT}")" # OE_HOME created earlier
    chown -R "${OE_USER}":"${OE_USER}" "$(dirname "${OE_HOME_EXT}")"
    # ODOO_ENTERPRISE_PAT logic for git clone is for enterprise part only.
    # Community is public.
    su - "${OE_USER}" -c "git clone --depth 1 --branch ${OE_VERSION} https://github.com/odoo/odoo.git ${OE_HOME_EXT}"
fi

# --- Enterprise Edition ---
OE_ENTERPRISE_DIR="${OE_HOME}/enterprise"
if [ "$IS_ENTERPRISE" = "True" ]; then
    log "INFO" "Setting up Odoo Enterprise Edition..."
    su - "${OE_USER}" -c "mkdir -p ${OE_ENTERPRISE_DIR}"

    # Construct the enterprise URL
    ENTERPRISE_REPO_URL="https://github.com/odoo/enterprise.git"
    # Check if ODOO_ENTERPRISE_PAT is set and not empty
    # Note: The ODOO_ENTERPRISE_PAT variable must be declared for set -u
    # This example assumes it's either empty or holds a token.
    # If you want to ensure it's declared even if empty:
    : "${ODOO_ENTERPRISE_PAT:=}" # bash parameter expansion, assigns "" if ODOO_ENTERPRISE_PAT is unset or null.
    if [ -n "$ODOO_ENTERPRISE_PAT" ]; then
        ENTERPRISE_REPO_URL="https://${ODOO_ENTERPRISE_PAT}@github.com/odoo/enterprise.git"
        log "INFO" "Using GitHub PAT for enterprise repository."
    else
        log "INFO" "Using SSH key or cached credentials for enterprise repository."
    fi

    log "INFO" "Cloning Odoo Enterprise Edition from ${OE_VERSION} branch..."
    # Try cloning, loop on auth failure.
    # Note: git clone output goes to stderr.
    CLONE_SUCCESS="false"
    MAX_ATTEMPTS=3
    CURRENT_ATTEMPT=0
    while [ "$CLONE_SUCCESS" = "false" ] && [ $CURRENT_ATTEMPT -lt $MAX_ATTEMPTS ]; do
        CURRENT_ATTEMPT=$((CURRENT_ATTEMPT + 1))
        if su - "${OE_USER}" -c "git clone --depth 1 --branch ${OE_VERSION} ${ENTERPRISE_REPO_URL} ${OE_ENTERPRISE_DIR}"; then
            CLONE_SUCCESS="true"
            log "INFO" "Odoo Enterprise cloned successfully."
        else
            log "WARNING" "Failed to clone Odoo Enterprise (Attempt ${CURRENT_ATTEMPT}/${MAX_ATTEMPTS})."
            if [ -n "$ODOO_ENTERPRISE_PAT" ]; then
                log "WARNING" "Check your GitHub Personal Access Token (PAT) and its permissions."
            else
                log "WARNING" "Ensure your SSH key is configured correctly with GitHub and has access to the Odoo Enterprise repository."
                log "WARNING" "Or, consider using a PAT by setting ODOO_ENTERPRISE_PAT variable in the script."
            fi
            if [ $CURRENT_ATTEMPT -lt $MAX_ATTEMPTS ]; then
                log "INFO" "Retrying in 10 seconds..."
                sleep 10
            else
                log "ERROR" "Failed to clone Odoo Enterprise after $MAX_ATTEMPTS attempts. Please check your credentials and repository access."
                log "ERROR" "You might need to: "
                log "ERROR" "  1. Be an official Odoo partner."
                log "ERROR" "  2. Have access to https://github.com/odoo/enterprise."
                log "ERROR" "  3. If using PAT: ensure it has 'repo' scope."
                log "ERROR" "  4. If using SSH: ensure your SSH key is added to your GitHub account and your local ssh-agent."
                # Decide if you want to exit or continue with community only
                # For now, we'll assume enterprise is critical if IS_ENTERPRISE=True
                exit 1 # Or set IS_ENTERPRISE="False" and continue
            fi
        fi
    done

    log "INFO" "Enterprise code downloaded to ${OE_ENTERPRISE_DIR}."
    log "INFO" "Installing Enterprise specific Python libraries..."
    # Enterprise requirements.txt is usually inside the enterprise repo itself.
    # Or common ones are listed, ensure these are installed in the venv.
    ENTERPRISE_REQUIREMENTS_PATH="${OE_ENTERPRISE_DIR}/requirements.txt"
    if [ -f "${ENTERPRISE_REQUIREMENTS_PATH}" ]; then
         su - "${OE_USER}" -c "source ${OE_PYTHON_VENV}/bin/activate && pip install -r ${ENTERPRISE_REQUIREMENTS_PATH}"
    else
        log "WARNING" "Enterprise requirements.txt not found at ${ENTERPRISE_REQUIREMENTS_PATH}. Installing common known dependencies."
        su - "${OE_USER}" -c "source ${OE_PYTHON_VENV}/bin/activate && pip install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL"
    fi
    # Ensure node/npm tools are available for enterprise too, already installed globally.
else
    log "INFO" "Skipping Odoo Enterprise installation."
fi

# --- Create Custom Addons Directory ---
OE_CUSTOM_ADDONS_DIR="${OE_HOME}/custom_addons"
log "INFO" "Creating custom addons directory at ${OE_CUSTOM_ADDONS_DIR}..."
su - "${OE_USER}" -c "mkdir -p ${OE_CUSTOM_ADDONS_DIR}"
# Example: If you have a git repo for custom addons:
# CUSTOM_ADDONS_GIT_REPO="your_repo_url"
# CUSTOM_ADDONS_GIT_BRANCH="main"
# if [ -n "$CUSTOM_ADDONS_GIT_REPO" ]; then
#    log "INFO" "Cloning custom addons from $CUSTOM_ADDONS_GIT_REPO..."
#    su - "${OE_USER}" -c "git clone --depth 1 --branch $CUSTOM_ADDONS_GIT_BRANCH $CUSTOM_ADDONS_GIT_REPO ${OE_CUSTOM_ADDONS_DIR}/my_custom_repo"
# fi

# --- Set Permissions and Create Config File ---
log "INFO" "Setting final permissions on Odoo home folder '${OE_HOME}'..."
chown -R "${OE_USER}":"${OE_USER}" "${OE_HOME}"
# More restrictive permissions within code directories
find "${OE_HOME_EXT}" -type d -exec chmod 750 {} \;
find "${OE_HOME_EXT}" -type f -exec chmod 640 {} \;
if [ "$IS_ENTERPRISE" = "True" ] && [ -d "${OE_ENTERPRISE_DIR}" ]; then
    find "${OE_ENTERPRISE_DIR}" -type d -exec chmod 750 {} \;
    find "${OE_ENTERPRISE_DIR}" -type f -exec chmod 640 {} \;
fi
if [ -d "${OE_CUSTOM_ADDONS_DIR}" ]; then
    find "${OE_CUSTOM_ADDONS_DIR}" -type d -exec chmod 750 {} \;
    find "${OE_CUSTOM_ADDONS_DIR}" -type f -exec chmod 640 {} \;
fi
# Ensure odoo-bin is executable by the user
chmod u+x "${OE_HOME_EXT}/odoo-bin"


log "INFO" "Creating Odoo configuration file '${OE_CONFIG_FILE}'..."
touch "${OE_CONFIG_FILE}"

# Determine Odoo admin password
FINAL_OE_SUPERADMIN_PASSWORD="${OE_SUPERADMIN_PASSWORD_DEFAULT}"
if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    log "INFO" "Generating random admin password..."
    FINAL_OE_SUPERADMIN_PASSWORD=$(generate_password)
    echo "${FINAL_OE_SUPERADMIN_PASSWORD}" > "${ADMIN_PASSWORD_FILE}"
    chmod 600 "${ADMIN_PASSWORD_FILE}"
    chown root:root "${ADMIN_PASSWORD_FILE}" # Ensure root owns it
    log "INFO" "Generated admin password stored in ${ADMIN_PASSWORD_FILE}"
else
    log "INFO" "Using default admin password. IMPORTANT: Change this password immediately after setup if it's weak!"
fi

# Calculate workers if set to auto
if [ "$WORKERS" -eq 0 ]; then
    WORKERS=$(calculate_workers)
    log "INFO" "Auto-calculated workers: $WORKERS"
fi

# Construct addons_path
ADDONS_PATHS="${OE_HOME_EXT}/addons"
if [ "$IS_ENTERPRISE" = "True" ] && [ -d "${OE_ENTERPRISE_DIR}" ]; then
    ADDONS_PATHS="${OE_ENTERPRISE_DIR},${ADDONS_PATHS}" # Enterprise addons first
fi
if [ -d "${OE_CUSTOM_ADDONS_DIR}" ]; then
    # Prepend custom addons path to give it priority.
    # Odoo loads addons from left to right; a module in a path earlier in the list
    # will "override" one with the same name in a later path.
    ADDONS_PATHS="${OE_CUSTOM_ADDONS_DIR},${ADDONS_PATHS}"
fi

# Create server config file content
# Note: db_user and db_password are only needed if the PostgreSQL user ${OE_USER}
# requires a password and it's different from the OS user, or if connection is not local peer.
# For this script, we assume local peer auth for ${OE_USER} or scram-sha-256 for localhost TCP/IP.
cat <<EOF > "${OE_CONFIG_FILE}"
[options]
; This is the password that allows database operations:
admin_passwd = ${FINAL_OE_SUPERADMIN_PASSWORD}
addons_path = ${ADDONS_PATHS}
http_port = ${OE_PORT}
logfile = ${OE_LOG_FILE}
logrotate = True ; Odoo handles its own log rotation if True
pidfile = /tmp/${INSTANCE_NAME}.pid ; Useful for service management

; Performance settings
workers = ${WORKERS}
max_cron_threads = ${MAX_CRON_THREADS}
limit_memory_hard = ${LIMIT_MEMORY_HARD}
limit_memory_soft = ${LIMIT_MEMORY_SOFT}
limit_time_cpu = ${LIMIT_TIME_CPU}
limit_time_real = ${LIMIT_TIME_REAL}

; Database connection (uncomment and set if not using peer/ident or if DB is remote)
; db_host = localhost
; db_port = 5432
db_user = ${OE_USER}
; db_password = False ; Set if PG user ${OE_USER} has a password
db_maxconn = ${DB_MAX_CONNECTIONS} ; Odoo's internal pool size
db_template = template0 ; Odoo 15+ often recommends template0 for UTF8 compatibility

; XMLRPC settings (Odoo main protocol)
xmlrpc_port = ${OE_PORT} ; Same as http_port unless specific setup
xmlrpc_interface = ; Bind to all interfaces by default, or specify an IP

; Longpolling settings for live chat, etc.
longpolling_port = ${LONGPOLLING_PORT}
proxy_mode = $( [ "$INSTALL_NGINX" = "True" ] && echo "True" || echo "False" )

; Logging
log_level = ${LOG_LEVEL}
syslog = $( [ "$ENABLE_SYSLOG" = "True" ] && echo "True" || echo "False" )

; Other options
list_db = True ; Set to False to hide database list from login page for security
dbfilter = ${DB_FILTER} ; Regex for filtering databases, e.g., "^%d$" or "^%h$"
; server_wide_modules = web,base_setup ; comma-separated list of modules to load automatically
; without_demo = True ; To disable demo data for new databases
EOF

# Secure config file permissions
chown "${OE_USER}":"${OE_USER}" "${OE_CONFIG_FILE}"
chmod 640 "${OE_CONFIG_FILE}" # Read/Write for user, Read for group, None for others
# Create a group that can read the config if needed (e.g., for monitoring)
# groupadd odooconf_readers || true
# chgrp odooconf_readers "${OE_CONFIG_FILE}"
# chmod 640 "${OE_CONFIG_FILE}"

# --- Create Systemd Service File ---
log "INFO" "Creating systemd service file '${OE_SERVICE_NAME}'..."
# EnvironmentFile could be used for some settings, but direct config is also fine.
# Consider Resource Accounting options for better control by systemd.
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
# Odoo executable is in the venv
ExecStart=${OE_PYTHON_VENV}/bin/python3 ${OE_HOME_EXT}/odoo-bin --config=${OE_CONFIG_FILE}
# StandardOutput=journal+console # Good for journald logging
StandardOutput=null # If using Odoo's logfile and syslog, avoid duplicate console output
StandardError=journal # Capture errors in journal
KillMode=mixed
Restart=always
RestartSec=5s

# Optional: Resource limits (systemd level, complements Odoo's internal limits)
# LimitNOFILE=65536
# LimitNPROC=16384
# TasksMax=infinity # Default is usually fine unless you have many workers/threads

# Optional: Security hardening
# NoNewPrivileges=true
# PrivateTmp=true
# ProtectSystem=full
# ProtectHome=true ; If true, ensure OE_HOME is writable via ReadWritePaths
# ReadWritePaths=${OE_HOME} ${OE_LOG_DIR} /tmp/ # Add other necessary paths

[Install]
WantedBy=multi-user.target
EOF

log "INFO" "Reloading systemd daemon and enabling Odoo service..."
systemctl daemon-reload
systemctl enable "${OE_SERVICE_NAME}"

# --- Install and Configure Nginx ---
if [ "$INSTALL_NGINX" = "True" ]; then
    log "INFO" "Installing and configuring Nginx..."
    if ! command_exists nginx; then
        apt-get install -y nginx
    else
        log "INFO" "Nginx already installed."
    fi
    # Create Nginx log directory if it doesn't exist
    mkdir -p "${NGINX_LOG_DIR}"

    # Nginx config for Odoo
    # SSL configuration will be added by Certbot if ENABLE_SSL is True
    cat <<EOF > "${NGINX_CONFIG_FILE}"
# Upstream for Odoo main application
upstream ${INSTANCE_NAME}_odoo {
    server 127.0.0.1:${OE_PORT};
}

# Upstream for Odoo longpolling (live chat)
upstream ${INSTANCE_NAME}_odoochat {
    server 127.0.0.1:${LONGPOLLING_PORT};
}

server {
    listen 80;
    # listen [::]:80; # Uncomment for IPv6

    server_name ${WEBSITE_NAME}; # Replace with your domain or "_" for IP/localhost

    # Security Headers (can be enhanced further)
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    # add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    # add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; font-src 'self' data:;" always; # CSP is complex, tailor it.
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always; # Only if SSL is permanently used

    # Proxy settings
    proxy_http_version 1.1; # Recommended for keepalive
    proxy_set_header Upgrade \$http_upgrade; # For websockets (though longpolling is more common for Odoo chat)
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$host;

    # Logging
    access_log ${NGINX_LOG_DIR}/${INSTANCE_NAME}-access.log;
    error_log ${NGINX_LOG_DIR}/${INSTANCE_NAME}-error.log;

    # Buffers and Timeouts (adjust as needed)
    proxy_buffers 16 64k;
    proxy_buffer_size 128k;
    proxy_read_timeout 720s; # Odoo long operations can take time
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;
    client_max_body_size 512m; # Max upload size

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types
        application/atom+xml
        application/geo+json
        application/javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rdf+xml
        application/rss+xml
        application/vnd.ms-fontobject
        application/wasm
        application/x-font-ttf
        application/x-web-app-manifest+json
        application/xhtml+xml
        application/xml
        font/opentype
        image/bmp
        image/svg+xml
        image/x-icon
        text/cache-manifest
        text/css
        text/javascript
        text/plain
        text/vcard
        text/vnd.rim.location.xloc
        text/vtt
        text/xml;

    # Longpolling (Chat)
    location /longpolling {
        proxy_pass http://${INSTANCE_NAME}_odoochat;
        proxy_read_timeout 720s; # Needs long timeout
    }

    # Main Odoo application
    location / {
        proxy_pass http://${INSTANCE_NAME}_odoo;
        proxy_redirect off;
    }

    # Cache static files (optional, Odoo handles some caching)
    location ~* /web/static/ {
        proxy_cache_valid 200 60m;
        proxy_buffering on;
        expires 864000; # 10 days
        proxy_pass http://${INSTANCE_NAME}_odoo;
    }

    # Deny access to .hg, .git, .svn directories (if any accidentally exposed)
    location ~ /\. {
        deny all;
    }
}
EOF

    # Enable the site and test Nginx config
    ln -snf "${NGINX_CONFIG_FILE}" "/etc/nginx/sites-enabled/${INSTANCE_NAME}"
    # Remove default Nginx site if it exists and this is the primary site
    if [ -f "/etc/nginx/sites-enabled/default" ] && [ "${WEBSITE_NAME}" != "_" ]; then
        rm -f /etc/nginx/sites-enabled/default
    fi

    log "INFO" "Testing Nginx configuration..."
    if nginx -t; then
        log "INFO" "Nginx configuration is OK. Restarting Nginx..."
        systemctl restart nginx
        systemctl enable nginx
    else
        log "ERROR" "Nginx configuration test failed. Please check ${NGINX_CONFIG_FILE} and Nginx error logs."
        # Optionally, do not proceed or try to revert Nginx changes
        exit 1
    fi
    log "INFO" "Nginx configured for Odoo instance ${INSTANCE_NAME}."
else
    log "INFO" "Nginx installation skipped."
fi

# --- Enable SSL with Certbot ---
if [ "$INSTALL_NGINX" = "True" ] && [ "$ENABLE_SSL" = "True" ]; then
    if [ "${WEBSITE_NAME}" = "_" ] || [ "${ADMIN_EMAIL}" = "youremail@example.com" ] || [ -z "${ADMIN_EMAIL}" ]; then
        log "WARNING" "SSL not enabled: WEBSITE_NAME must be a valid domain (not '_') and ADMIN_EMAIL must be set."
    else
        log "INFO" "Setting up SSL with Certbot for ${WEBSITE_NAME}..."
        if ! command_exists certbot; then
            # Install Certbot (using snap is recommended by EFF)
            apt-get install -y snapd || true # May already be installed
            if ! command_exists snap; then # If snapd install failed or snap command still not found
                log "WARNING" "snap command not found, trying to install certbot via apt (may be older)."
                add-apt-repository -y ppa:certbot/certbot # Might not be needed on newer Ubuntu
                apt-get update
                apt-get install -y certbot python3-certbot-nginx
            else
                 snap install core && snap refresh core || log "WARNING" "Snap core update/install failed, proceeding..."
                 snap install --classic certbot || log "ERROR" "Failed to install certbot via snap."
                 ln -snf /snap/bin/certbot /usr/bin/certbot || log "WARNING" "Failed to symlink certbot."
            fi
        fi

        if command_exists certbot; then
            log "INFO" "Requesting Let's Encrypt certificate for ${WEBSITE_NAME}..."
            # Ensure Nginx is running and configured for HTTP on port 80 for the domain
            # The --nginx plugin will attempt to modify the Nginx config
            certbot --nginx -d "${WEBSITE_NAME}" --non-interactive --agree-tos --email "${ADMIN_EMAIL}" --redirect --hsts --uir
            log "INFO" "SSL/HTTPS enabled for ${WEBSITE_NAME}!"

            log "INFO" "Setting up automatic SSL certificate renewal cron job/timer..."
            # Certbot package usually sets up a systemd timer or cron job. Check:
            # systemctl list-timers | grep certbot
            # If not, add one:
            if ! systemctl list-timers | grep -q 'certbot\.timer'; then
                 echo "0 3 * * * root certbot renew --quiet" > /etc/cron.d/certbot_renew
                 chmod 644 /etc/cron.d/certbot_renew
            fi
        else
            log "ERROR" "Certbot command not found. SSL setup failed."
        fi
    fi
else
    log "INFO" "SSL/HTTPS setup skipped."
fi

# --- Setup Firewall (UFW) ---
if command_exists ufw; then
    log "INFO" "Configuring firewall (UFW)..."
    ufw allow ssh # Ensure SSH access is not blocked!
    if [ "$INSTALL_NGINX" = "True" ]; then
        ufw allow 'Nginx Full' # Allows HTTP and HTTPS
    else
        ufw allow "${OE_PORT}/tcp" # Allow Odoo direct port
        ufw allow "${LONGPOLLING_PORT}/tcp" # Allow Odoo longpolling direct port
    fi
    # Consider other ports if needed, e.g., PostgreSQL if accessed remotely (not recommended without further security)
    # ufw deny <port> # Example to deny a port
    if ! ufw status | grep -qw active; then
        yes | ufw enable # Auto-confirm enabling UFW
        log "INFO" "UFW enabled and configured."
    else
        log "INFO" "UFW already active. Rules applied."
    fi
    ufw status verbose
else
    log "WARNING" "UFW (Uncomplicated Firewall) not found. Consider installing and configuring a firewall."
fi


# --- Setup Odoo Auto Backup ---
if [ "$ENABLE_AUTO_BACKUP" = "True" ]; then
    log "INFO" "Setting up automated database backups for instance ${INSTANCE_NAME}..."
    mkdir -p "${BACKUP_DIR}"
    chown "${OE_USER}":"${OE_USER}" "${BACKUP_DIR}"
    chmod 750 "${BACKUP_DIR}"

    # Backup script content
    # This script backs up all databases managed by this Odoo instance.
    # To backup a specific DB, change ODOO_DATABASES or pass as argument.
    cat <<EOF > "${BACKUP_SCRIPT_PATH}"
#!/bin/bash
set -e
set -u
set -o pipefail

BACKUP_ROOT_DIR="${BACKUP_DIR}"
ODOO_USER="${OE_USER}"
ODOO_CONFIG_FILE="${OE_CONFIG_FILE}"
DAYS_TO_KEEP=${BACKUP_DAYS_TO_KEEP}
DATE_FORMAT=\$(date +"%Y%m%d_%H%M%S")

# Get list of databases from Odoo config (requires parsing or a helper)
# For simplicity, this script assumes you want to back up ALL non-template databases
# or you can specify them. A more robust way is to query PostgreSQL.
# This example dumps all user databases.
DATABASES=\$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres';")

mkdir -p "\${BACKUP_ROOT_DIR}"

for DB_NAME in \${DATABASES}; do
    if [ -z "\$DB_NAME" ]; then continue; fi
    log_msg() { echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$DB_NAME - \$1"; }
    log_msg "Starting backup for database: \$DB_NAME"

    BACKUP_FILE_DB="db_\${DB_NAME}_\${DATE_FORMAT}.sql.gz"
    BACKUP_FILE_FS="fs_\${DB_NAME}_\${DATE_FORMAT}.tar.gz" # Filestore backup

    # 1. Database Dump
    log_msg "Dumping PostgreSQL database..."
    # Ensure OE_USER has rights or run as postgres user
    # Using pg_dump as postgres user is generally safer for permissions
    sudo -u postgres pg_dump "\$DB_NAME" | gzip > "\${BACKUP_ROOT_DIR}/\${BACKUP_FILE_DB}"
    log_msg "Database dump complete: \${BACKUP_ROOT_DIR}/\${BACKUP_FILE_DB}"

    # 2. Filestore Backup
    # Odoo stores filestore typically in ~/.local/share/Odoo/filestore/<database_name> or a path defined in config
    # This needs to be robustly determined. For now, assuming default relative to OE_HOME:
    # Or, if data_dir is set in Odoo config: DATA_DIR=$(grep -Po "^data_dir\s*=\s*\K.*" "${ODOO_CONFIG_FILE}")
    # Default path:
    FILESTORE_PATH="${OE_HOME}/.local/share/Odoo/filestore/\${DB_NAME}"
    # A common alternative path if data_dir is set to something like /opt/odoo/data
    # DATA_DIR_BASE=$(grep -E "^data_dir\s*=" "${ODOO_CONFIG_FILE}" | cut -d '=' -f 2 | xargs)
    # if [ -n "\$DATA_DIR_BASE" ]; then
    #    FILESTORE_PATH="\${DATA_DIR_BASE}/filestore/\${DB_NAME}"
    # fi

    if [ -d "\${FILESTORE_PATH}" ]; then
        log_msg "Backing up filestore from \${FILESTORE_PATH}..."
        # Ensure the backup user (root via cron, or OE_USER if run manually) can read this.
        # Running tar as root is easier if OE_USER owns the files.
        tar -czf "\${BACKUP_ROOT_DIR}/\${BACKUP_FILE_FS}" -C "\$(dirname "\${FILESTORE_PATH}")" "\$(basename "\${FILESTORE_PATH}")"
        log_msg "Filestore backup complete: \${BACKUP_ROOT_DIR}/\${BACKUP_FILE_FS}"
    else
        log_msg "Filestore path \${FILESTORE_PATH} not found. Skipping filestore backup."
    fi
done

# Delete old backups
log_msg "Deleting backups older than \${DAYS_TO_KEEP} days..."
find "\${BACKUP_ROOT_DIR}" -name "db_*.sql.gz" -mtime +\${DAYS_TO_KEEP} -exec rm -f {} \; -print
find "\${BACKUP_ROOT_DIR}" -name "fs_*.tar.gz" -mtime +\${DAYS_TO_KEEP} -exec rm -f {} \; -print
log_msg "Old backup cleanup complete."

log_msg "All backup operations finished for instance ${INSTANCE_NAME}."
EOF

    chmod +x "${BACKUP_SCRIPT_PATH}"
    log "INFO" "Backup script created at ${BACKUP_SCRIPT_PATH}"

    # Setup cron job for backup
    echo "${BACKUP_SCHEDULE} root ${BACKUP_SCRIPT_PATH} >> ${BACKUP_LOG_FILE} 2>&1" > "/etc/cron.d/${INSTANCE_NAME}-backup"
    chmod 644 "/etc/cron.d/${INSTANCE_NAME}-backup"
    log "INFO" "Cron job for backups configured. Logs will be at ${BACKUP_LOG_FILE}"
else
    log "INFO" "Automatic backup setup skipped."
fi


# --- Start Odoo Service ---
log "INFO" "Starting Odoo instance '${INSTANCE_NAME}' service (${OE_SERVICE_NAME})..."
systemctl start "${OE_SERVICE_NAME}"

# Check status
sleep 5 # Give it a moment to start
if systemctl is-active --quiet "${OE_SERVICE_NAME}"; then
    log "INFO" "Odoo service '${OE_SERVICE_NAME}' is running."
else
    log "ERROR" "Odoo service '${OE_SERVICE_NAME}' failed to start. Check logs:"
    log "ERROR" "  Odoo log: sudo journalctl -u ${OE_SERVICE_NAME} -n 100 --no-pager"
    log "ERROR" "  Odoo app log: ${OE_LOG_FILE} (if configured and reachable)"
    log "ERROR" "  PostgreSQL log: Check /var/log/postgresql/"
fi

# --- Final Summary ---
log "INFO" "======================================================================"
log "INFO" " Odoo ${OE_VERSION} Installation for instance '${INSTANCE_NAME}' Summary"
log "INFO" "----------------------------------------------------------------------"
log "INFO" " Odoo Service Name: ${OE_SERVICE_NAME}"
log "INFO" " Odoo System User: ${OE_USER}"
log "INFO" " Odoo Home Directory: ${OE_HOME}"
log "INFO" " Odoo Server Source: ${OE_HOME_EXT}"
log "INFO" " Odoo Python Venv: ${OE_PYTHON_VENV}"
if [ "$IS_ENTERPRISE" = "True" ]; then
log "INFO" " Odoo Enterprise Dir: ${OE_ENTERPRISE_DIR}"
fi
log "INFO" " Odoo Custom Addons: ${OE_CUSTOM_ADDONS_DIR}"
log "INFO" " Odoo Config File: ${OE_CONFIG_FILE}"
log "INFO" " Odoo Log File: ${OE_LOG_FILE}"
log "INFO" " PostgreSQL User: ${OE_USER}"

if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
log "INFO" " Odoo Admin Password: Stored in ${ADMIN_PASSWORD_FILE}"
else
log "INFO" " Odoo Admin Password: ${FINAL_OE_SUPERADMIN_PASSWORD} (CHANGE THIS IF IT'S WEAK!)"
fi

log "INFO" " Odoo Port: ${OE_PORT}"
log "INFO" " Longpolling Port: ${LONGPOLLING_PORT}"
log "INFO" " Calculated Workers: ${WORKERS}"

if [ "$INSTALL_NGINX" = "True" ]; then
    log "INFO" " Nginx Config: ${NGINX_CONFIG_FILE}"
    ACCESS_URL_SCHEME="http"
    if [ "$ENABLE_SSL" = "True" ] && [ "${WEBSITE_NAME}" != "_" ] && [ "${ADMIN_EMAIL}" != "youremail@example.com" ]; then
        ACCESS_URL_SCHEME="https"
    fi
    log "INFO" " Access URL: ${ACCESS_URL_SCHEME}://${WEBSITE_NAME}"
fi
log "INFO" " Access (Direct, if Nginx not used/bypassed): http://<your_server_ip>:${OE_PORT}"

if [ "$ENABLE_AUTO_BACKUP" = "True" ]; then
log "INFO" " Auto Backups: Enabled. Dir: ${BACKUP_DIR}. Schedule: ${BACKUP_SCHEDULE}"
log "INFO" " Backup Script: ${BACKUP_SCRIPT_PATH}"
log "INFO" " Backup Log: ${BACKUP_LOG_FILE}"
fi

log "INFO" "----------------------------------------------------------------------"
log "INFO" " Useful Commands:"
log "INFO" "   Start Odoo: sudo systemctl start ${OE_SERVICE_NAME}"
log "INFO" "   Stop Odoo: sudo systemctl stop ${OE_SERVICE_NAME}"
log "INFO" "   Restart Odoo: sudo systemctl restart ${OE_SERVICE_NAME}"
log "INFO" "   Odoo Status: sudo systemctl status ${OE_SERVICE_NAME}"
log "INFO" "   Odoo Logs (journal): sudo journalctl -u ${OE_SERVICE_NAME} -f"
log "INFO" "   Odoo App Logs: sudo tail -f ${OE_LOG_FILE}"
if [ "$INSTALL_NGINX" = "True" ]; then
log "INFO" "   Restart Nginx: sudo systemctl restart nginx"
log "INFO" "   Nginx Status: sudo systemctl status nginx"
fi
log "INFO" "======================================================================"
log "INFO" " Installation process finished."
log "INFO" " It is recommended to reboot the server or at least re-login to apply all group changes if any."
log "INFO" "======================================================================"

exit 0
