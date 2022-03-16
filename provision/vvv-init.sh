#!/usr/bin/env bash
# Provision WordPress Stable

# Quit out of the provisioner if something fails, like checking out htdocs
set -eo pipefail

echo " * Custom site template provisioner ${VVV_SITE_NAME} - downloads and installs a copy of WP stable for testing, building client sites, etc"

DOMAIN=$(get_primary_host "${VVV_SITE_NAME}".test)
DOMAINS=$(get_hosts "${DOMAIN}")
SITE_TITLE=$(get_config_value 'site_title' "${DOMAIN}")
WP_VERSION=$(get_config_value 'wp_version' 'latest')
WP_TYPE=$(get_config_value 'wp_type' "single")
WP_LOCALE=$(get_config_value 'locale' 'en_US')
DB_NAME=$(get_config_value 'db_name' "${VVV_SITE_NAME}")
DB_NAME=${DB_NAME//[\\\/\.\<\>\:\"\'\|\?\!\*-]/}
ADMIN_NAME=$(get_config_value 'admin_name' 'shoreline-admin')
ADMIN_EMAIL=$(get_config_value 'admin_email' 'team@shoreline.media')
ADMIN_PASSWORD=$(get_config_value 'admin_password' 'password')
HTDOCS_REPO=$(get_config_value 'htdocs' '')
WEBP_EXPRESS=$(get_config_value 'webp_express' '')

# Configure SSH Key permissions
configure_keys() {
  # Update permissions for SSH Keys
  if [ -f "/home/vagrant/.ssh/id_rsa" ]; then
    chmod 600 /home/vagrant/.ssh/id_rsa
  fi
  if [ -f "/home/vagrant/.ssh/id_rsa.pub" ]; then
    chmod 644 /home/vagrant/.ssh/id_rsa.pub
  fi
}

# Make a database, if we don't already have one
setup_database() {
  echo -e " * Creating database '${DB_NAME}' (if it's not already there)"
  mysql -u root --password=root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`"
  echo -e " * Granting the wp user priviledges to the '${DB_NAME}' database"
  mysql -u root --password=root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO wp@localhost IDENTIFIED BY 'wp';"
  echo -e " * DB operations done."
}

setup_nginx_folders() {
  echo " * Setting up the log subfolder for Nginx logs"
  noroot mkdir -p "${VVV_PATH_TO_SITE}/log"
  noroot touch "${VVV_PATH_TO_SITE}/log/nginx-error.log"
  noroot touch "${VVV_PATH_TO_SITE}/log/nginx-access.log"
  echo " * Creating public_html folder if it doesn't exist already"
  noroot mkdir -p "${VVV_PATH_TO_SITE}/public_html"
}

copy_nginx_configs() {
  echo " * Copying the sites Nginx config template"
  if [ -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-custom.conf" ]; then
    echo " * A vvv-nginx-custom.conf file was found"
    cp -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-custom.conf" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  else
    echo " * Using the default vvv-nginx-default.conf, to customize, create a vvv-nginx-custom.conf"
    cp -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-default.conf" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  fi

  LIVE_URL=$(get_config_value 'live_url' '')
  if [ ! -z "$LIVE_URL" ]; then
    echo " * Adding support for Live URL redirects to NGINX of the website's media"
    # replace potential protocols, and remove trailing slashes
    LIVE_URL=$(echo "${LIVE_URL}" | sed 's|https://||' | sed 's|http://||'  | sed 's:/*$::')

    redirect_config=$((cat <<END_HEREDOC
if (!-e \$request_filename) {
  rewrite ^/[_0-9a-zA-Z-]+(/wp-content/uploads/.*) \$1;
}
if (!-e \$request_filename) {
  rewrite ^/wp-content/uploads/(.*)\$ \$scheme://${LIVE_URL}/wp-content/uploads/\$1 redirect;
}
END_HEREDOC
    ) |
    # pipe and escape new lines of the HEREDOC for usage in sed
    sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n\\1/g'
    )
    sed -i -e "s|\(.*\){{LIVE_URL}}|\1${redirect_config}|" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  else
    sed -i "s#{{LIVE_URL}}##" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  fi
}

setup_nginx_certificates() {
  sed -i "s#{vvv_tls_cert}#ssl_certificate /srv/certificates/${VVV_SITE_NAME}/dev.crt;#" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  sed -i "s#{vvv_tls_key}#ssl_certificate_key /srv/certificates/${VVV_SITE_NAME}/dev.key;#" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
}

initial_wpconfig() {
  echo "Configuring WordPress Stable..."
  WP_CACHE_KEY_SALT=`date +%s | sha256sum | head -c 64`
  noroot wp core config --dbname="${DB_NAME}" --dbuser=wp --dbpass=wp --quiet --extra-php <<PHP

/*define( 'WP_DEBUG', true );*/
define( 'WP_DEBUG_LOG', true );
define( 'WP_DEBUG_DISPLAY', false );
define( 'SCRIPT_DEBUG', true );
define( 'WP_DISABLE_FATAL_ERROR_HANDLER', true );
define( 'SAVEQUERIES', false );
define( 'JETPACK_DEV_DEBUG', true );
@ini_set( 'display_errors', 0 );
define( 'WP_ENVIRONMENT_TYPE', 'development' );
define( 'WP_LOCAL_DEV', true );
define( 'WP_ENV', 'development' );
// Disable File Editor
define('DISALLOW_FILE_EDIT', true);
/** WP ROCKET DISABLED DURING LOCAL DEV**/
define( 'DONOTCACHEPAGE', true );
define( 'DONOTROCKETOPTIMIZE', true );
/* WP MAIL SMTP Force sending to mailhog locally */
define( 'WPMS_ON', true );
define( 'WPMS_MAILER', 'smtp' );
define( 'WPMS_SMTP_HOST', 'vvv.test' );
define( 'WPMS_SMTP_PORT', '1025' );
define( 'WPMS_SMTP_AUTH', false );
define( 'WPMS_SMTP_AUTOTLS', false );
define( 'WPMS_SSL', '' );
define( 'WPMS_SMTP_USER', '' );
define( 'WPMS_SMTYP_PASS', '' );
define( 'WPMS_SMTP_AUTOTLS', false );
define( 'WPMS_SSL', '' );

/* Disable ManageWP plugin for local/dev */
define( 'MWP_SKIP_BOOTSTRAP', true );


/** Contact Form 7 **/
// Stop adding <br> and <p> tags to forms and emails
define ( 'WPCF7_AUTOP', false );
// Restrict Access to the Contact Forms to Admins only
define( 'WPCF7_ADMIN_READ_CAPABILITY', 'manage_options' );
define( 'WPCF7_ADMIN_READ_WRITE_CAPABILITY', 'manage_options' );

// Match any requests made via xip.io.
if ( isset( \$_SERVER['HTTP_HOST'] ) && preg_match('/^(${VVV_SITE_NAME})\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(.xip.io)\z/', \$_SERVER['HTTP_HOST'] ) ) {
define( 'WP_HOME', 'http://' . \$_SERVER['HTTP_HOST'] );
define( 'WP_SITEURL', 'http://' . \$_SERVER['HTTP_HOST'] );
}

PHP
}

# Install liquid prompt for pretty command line formatting
install_liquidprompt() {
  noroot mkdir /home/vagrant/liquidprompt
  noroot git clone https://github.com/nojhan/liquidprompt.git /home/vagrant/liquidprompt
  source /home/vagrant/liquidprompt/liquidprompt

  # Copy liquidprompt config
  noroot cp /home/vagrant/liquidprompt/liquidpromptrc-dist /home/vagrant/.config/liquidpromptrc

  # Add to .bashrc
  noroot cat <<- "EOF" >> /home/vagrant/.bashrc

# Only load Liquid Prompt in interactive shells, not from a script or from scp
[[ $- = *i* ]] && source /home/vagrant/liquidprompt/liquidprompt

EOF

  # Update settings in config
  PATHLENGTH=16
  sed "s/LP_PATH_LENGTH\=[0-9]*/LP_PATH_LENGTH=${PATHLENGTH}/" /home/vagrant/.config/liquidpromptrc
}

# Install yarn as a new alternative to npm
install_yarn() {
  curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
  echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list

  sudo apt update
  sudo apt install --no-install-recommends yarn
}

# Install bower & gulp
yarn_global() {
  echo "---Installing bower & gulp for dependency management & dev tools---"
  yarn global add bower gulp-cli
}

# Setup Composer
setup_composer() {
  # Install composer required libraries
  cd ${VVV_PATH_TO_SITE}
  noroot composer update 
  # noroot composer install --no-dev
  echo -e "Run 'composer install --no-dev' to install base plugins and 'composer install --dev' to install developer plugins"
}

# Add nginx rules to support webp express plugin
# Uses same rules as suggested by WPEngine at https://wpengine.com/support/webp-image-optimization/
add_webp_express_to_nginx() {
  config_filename=vvv-nginx-webp-express.conf

  # Check if file exists first!
  if [[ ! -f "/etc/nginx/${config_filename}" ]]; then
    # Get config file into variable
    webp_express_config=$(<"${VVV_PATH_TO_SITE}/provision/${config_filename}")
    # Output config file to /etc/nginx/vvv-nginx-webp-express.conf
    echo "${webp_express_config}" >> "/etc/nginx/${config_filename}"
  fi


  # Check if webp express is set in config
  if [ ! -z "$WEBP_EXPRESS" ]; then
    # Replace with empty string
    #sed -i "s#{{WEBP_EXPRESS}}##" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
    # Replace {{WEBP_EXPRESS}} reference with include to /etc/nginx/vvv-nginx-webp-express.conf
    sed -i "s#{{WEBP_EXPRESS}}#include      /etc/nginx/${config_filename};#" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  else
    # Replace with empty string
    sed -i "s#{{WEBP_EXPRESS}}##" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  fi

}

# Checkout HTDOCS repo
checkout_htdocs_repo() {
  if [[ ! -z "$HTDOCS_REPO" ]]; then

    # Only checkout GIT repo on initial provision
    if [[ ! -f "${VVV_PATH_TO_SITE}/public_html/wp-load.php" ]]; then
      cd ${VVV_PATH_TO_SITE}/public_html


      # Setup our WPEngine starter project in the htdocs/public_html folder
      # before that folder is created
      echo "Checking out project from ${HTDOCS_REPO} to ${VVV_PATH_TO_SITE}/public_html/"


      # Create git repository, add origin remote and do first pull
      echo "Initializing git repo in htdocs/public_html folder"
      noroot git init
      echo "Adding git remote"
      noroot git remote add origin "${HTDOCS_REPO}"
      echo "Pulling master branch from ${HTDOCS_REPO}"
      noroot git pull --recurse-submodules origin master --force
      cd ${VVV_PATH_TO_SITE}
    fi

  fi
}

replace_custom_provision_scripts() {
  # Copy conf file with curly brace placeholders to actual file not controlled by git
  cp -f "${VVV_PATH_TO_SITE}/provision/.update-local.sh.conf" "${VVV_PATH_TO_SITE}/provision/update-local.sh"

  # Replace the {curly_brace_placeholder} text with info from vvv config
  sed -i "s#{vvv_primary_domain}#${DOMAIN}#" "${VVV_PATH_TO_SITE}/provision/update-local.sh"
  sed -i "s#{vvv_site_name}#${VVV_SITE_NAME}#" "${VVV_PATH_TO_SITE}/provision/update-local.sh"
  sed -i "s#{vvv_path_to_site}#${VVV_PATH_TO_SITE}#" "${VVV_PATH_TO_SITE}/provision/update-local.sh"
}

configure_keys
setup_database
setup_nginx_folders

# Setup Nginx config
copy_nginx_configs

# Replace domains in config template
sed -i "s#{{DOMAINS_HERE}}#${DOMAINS}#" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"

setup_nginx_certificates
add_webp_express_to_nginx
checkout_htdocs_repo

cd ${VVV_PATH_TO_SITE}/public_html

# Install and configure the latest stable version of WordPress
if [[ ! -f "${VVV_PATH_TO_SITE}/public_html/wp-load.php" ]]; then
    echo "Downloading WordPress..."
	noroot wp core download --version="${WP_VERSION}"
fi

if [[ ! -f "${VVV_PATH_TO_SITE}/public_html/wp-config.php" ]]; then
  initial_wpconfig
fi

if ! $(noroot wp core is-installed); then
  echo "Installing WordPress Stable..."

  if [ "${WP_TYPE}" = "subdomain" ]; then
    INSTALL_COMMAND="multisite-install --subdomains"
  elif [ "${WP_TYPE}" = "subdirectory" ]; then
    INSTALL_COMMAND="multisite-install"
  else
    INSTALL_COMMAND="install"
  fi

  noroot wp core ${INSTALL_COMMAND} --url="${DOMAIN}" --quiet --title="${SITE_TITLE}" --admin_name="${ADMIN_NAME}" --admin_email="${ADMIN_EMAIL}" --admin_password="${ADMIN_PASSWORD}"
else
  echo "Updating WordPress Stable..."
  cd ${VVV_PATH_TO_SITE}/public_html
  noroot wp core update --version="${WP_VERSION}"
fi

setup_composer
install_yarn
yarn_global

# Install Liquidprompt on first provision only
if [[ ! -d "/home/vagrant/liquidprompt" ]]; then
  install_liquidprompt
fi

# Replace variables in custom provision scripts
replace_custom_provision_scripts


echo " * Site Template provisioner script completed for ${VVV_SITE_NAME}"
