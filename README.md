# Odoo 18 Automated Installation Scripts by Ecosire.com

**Expert Odoo Solutions & Services by [Ecosire.com](https://www.ecosire.com/)**

Streamline your Odoo 18 deployment with our professionally crafted installation scripts. At Ecosire, we specialize in providing comprehensive Odoo services, from consultation and customization to robust support and deployment. These scripts are a testament to our commitment to quality and efficiency.

This repository contains automated bash scripts for installing Odoo 18 (Community or Enterprise) on:
* **Ubuntu 22.04 LTS (Jammy Jellyfish) & 24.04 LTS (Noble Numbat)**
* **Debian 12 (Bookworm)**

Our scripts are designed for security, durability, and configurability, ensuring a stable and optimized Odoo environment.

## Key Features

These scripts offer a comprehensive set of features to get your Odoo 18 instance up and running smoothly:

* **Full Odoo 18 Installation:** Complete setup for both Community and Enterprise (requires valid GitHub credentials for Enterprise) editions.
* **Latest PostgreSQL:** Installs PostgreSQL 16 (for Ubuntu) or PostgreSQL 15 (for Debian) with performance tuning configurations applied.
* **Python Virtual Environments:** Isolates each Odoo instance in its own Python virtual environment for better dependency management and stability, crucial for multi-instance setups.
* **Nginx Reverse Proxy:** Configures Nginx with optimized settings, including security headers, GZIP compression, and proper handling of longpolling/websockets.
* **SSL Certificate Automation:** Integrates with Let's Encrypt (Certbot) for free SSL certificate issuance and automated renewal.
* **Multi-Instance Ready:** Designed with instance-specific naming for users, services, configuration files, and logs, allowing multiple isolated Odoo instances on a single server.
* **Correct `wkhtmltopdf` Installation:** Ensures the correct version of `wkhtmltopdf` required by Odoo 18 is installed for reliable PDF report generation.
* **Performance Optimization:**
    * Automatic calculation of Odoo worker processes based on CPU cores.
    * Configurable memory and CPU time limits for Odoo processes.
    * Optimized PostgreSQL configuration parameters.
* **Robust Process Management:** Creates a dedicated systemd service file for each Odoo instance, ensuring it runs reliably and restarts on failure.
* **Comprehensive Security Hardening:**
    * Secure file and directory permissions.
    * Hardened PostgreSQL access control (`pg_hba.conf`).
    * UFW (Uncomplicated Firewall) setup to allow only necessary services.
    * Optional SSH hardening (disabling root login and password authentication).
    * Secure storage of auto-generated Odoo admin passwords.
* **Automated Backup System:**
    * Configures a daily cron job to back up Odoo databases and filestores.
    * Includes backup rotation to manage disk space.
* **Extensive Configurability:** Most parameters are controlled by variables at the top of the script, allowing easy customization without deep script diving.
* **Detailed Logging:** Provides clear, step-by-step logging during the installation process and for ongoing operations (Odoo logs, backup logs).
* **Idempotent Design:** Scripts are designed to be safely re-runnable where possible (e.g., checking if users or packages already exist).

## Why Choose These Scripts? The Ecosire Advantage

Deploying Odoo correctly is critical for business success. These scripts, developed with Ecosire's deep Odoo expertise, offer:
* **Best Practices:** Incorporates industry best practices for security, performance, and stability.
* **Time Savings:** Automates a complex setup process, reducing manual effort and potential errors.
* **Reliability:** Provides a consistent and repeatable deployment method.
* **Foundation for Growth:** Sets up an Odoo environment that is scalable and maintainable.

As Odoo specialists, [Ecosire.com](https://www.ecosire.com/) can further assist you with custom module development, advanced configuration, data migration, training, and ongoing support for your Odoo platform.

## Prerequisites

* A clean server running one of the supported OS versions (Ubuntu 22.04/24.04 or Debian 12).
* Root privileges (`sudo` access).
* If enabling SSL:
    * A Fully Qualified Domain Name (FQDN) pointing to your server's public IP address.
    * A valid email address for Let's Encrypt registration.
* If enabling Enterprise Edition: Valid GitHub credentials (PAT or SSH key) with access to the Odoo Enterprise repository.
* If enabling SSH hardening (disabling password authentication): Ensure SSH key-based login is already configured for your user.

## Usage Instructions

1.  **Download/Save the Script:**
    * For Ubuntu: Save the Ubuntu-specific script as `odoo_ubuntu_install.sh`.
    * For Debian: Save the Debian-specific script as `odoo_debian_install.sh`.

2.  **Make it Executable:**
    ```bash
    sudo chmod +x odoo_ubuntu_install.sh  # Or odoo_debian_install.sh
    ```

3.  **Configure the Script:**
    Open the script with a text editor (e.g., `sudo nano odoo_ubuntu_install.sh`) and carefully review and **modify the configuration variables at the top of the script** to match your requirements. This is the most crucial step for a successful installation.

4.  **Run the Script:**
    Execute the script with `sudo`:
    ```bash
    sudo ./odoo_ubuntu_install.sh  # Or odoo_debian_install.sh
    ```
    The script will then proceed with the installation, providing detailed output.

## Key Configuration Variables

The scripts are highly configurable by editing the variables defined at the beginning. Key parameters include:

* `INSTANCE_NAME`: A unique name for your Odoo instance (affects service names, user names, config files, etc.).
* `OE_CREATE_INSTANCE_USER`: Whether to create a dedicated system user per instance.
* `OE_PORT` & `LONGPOLLING_PORT`: Ports for Odoo HTTP and longpolling services.
* `OE_VERSION`: The Odoo version to install (script is tailored for 18.0).
* `IS_ENTERPRISE` & `ODOO_ENTERPRISE_PAT`: To install Enterprise edition and provide GitHub credentials.
* `WEBSITE_NAME`: Your domain name (e.g., `odoo.yourcompany.com`) or `_` for local/IP access.
* `ENABLE_SSL` & `ADMIN_EMAIL`: To enable SSL and provide your email for Let's Encrypt.
* `GENERATE_RANDOM_PASSWORD` & `OE_SUPERADMIN_PASSWORD_DEFAULT`: For Odoo's master admin password.
* Performance settings (`WORKERS`, `MAX_CRON_THREADS`, memory limits).
* PostgreSQL tuning parameters.
* Backup settings (`ENABLE_AUTO_BACKUP`, `BACKUP_DAYS_TO_KEEP`).
* Security hardening options (`ENABLE_SSH_HARDENING`, `ENABLE_UFW_FIREWALL`).

## Post-Installation

Once the script completes, it will display a summary of your installation, including:
* Odoo service name and how to manage it (start, stop, restart, status).
* Paths to Odoo configuration and log files.
* The Odoo admin master password (if auto-generated, it will be stored in a root-owned file).
* The URL to access your Odoo instance.

It is generally recommended to reboot the server after the first installation, or at least re-login if SSH hardening changed user group memberships or SSH daemon behavior.

## Odoo Services by Ecosire.com

Need help with your Odoo implementation? [Ecosire.com](https://www.ecosire.com/) offers a full spectrum of Odoo services:
* Odoo Consultation and Business Analysis
* Odoo Implementation and Configuration
* Odoo Customization and Module Development
* Odoo Integration with Third-Party Systems
* Odoo Data Migration
* Odoo Training and Support
* Odoo Hosting and Maintenance Optimization

**Contact us today at [info@ecosire.com](mailto:info@ecosire.com) or visit [www.ecosire.com](https://www.ecosire.com/) to learn how we can help you leverage the full power of Odoo!**

---

**Disclaimer:** While these scripts are thoroughly developed, always test them in a non-production environment first. Ecosire.com is not liable for any issues that may arise from their use. Ensure you understand the configurations you are applying, especially security-related settings.
