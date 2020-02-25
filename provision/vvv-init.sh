#!/usr/bin/env bash
# Provision WordPress Stable

set -eo pipefail

echo " * Custom site template provisioner ${VVV_SITE_NAME} - downloads and installs a copy of WP stable for testing, building client sites, etc"

DOMAIN=`get_primary_host "${VVV_SITE_NAME}".test`
DOMAINS=`get_hosts "${DOMAIN}"`
SITE_TITLE=`get_config_value 'site_title' "${DOMAIN}"`
WP_VERSION=`get_config_value 'wp_version' 'latest'`
WP_TYPE=`get_config_value 'wp_type' "single"`
WP_LOCALE=$(get_config_value 'locale' 'en_US')
DB_NAME=`get_config_value 'db_name' "${VVV_SITE_NAME}"`
DB_NAME=${DB_NAME//[\\\/\.\<\>\:\"\'\|\?\!\*-]/}
ADMIN_NAME=`get_config_value 'admin_name' "shoreline-admin"`
ADMIN_EMAIL=`get_config_value 'admin_email' "team@shoreline.media"`
ADMIN_PASSWORD=`get_config_value 'admin_password' "password"`
HTDOCS_REPO=`get_config_value 'htdocs' ""`

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

initial_wpconfig() {
  echo "Configuring WordPress Stable..."
  WP_CACHE_KEY_SALT=`date +%s | sha256sum | head -c 64`
  noroot wp core config --dbname="${DB_NAME}" --dbuser=wp --dbpass=wp --quiet --extra-php <<PHP

define( 'WP_CACHE', true );
define( 'WP_CACHE_KEY_SALT', '$WP_CACHE_KEY_SALT' );
define( 'WP_DEBUG', true );
define( 'WP_DEBUG_LOG', true );
define( 'WP_DEBUG_DISPLAY', false );
define( 'SCRIPT_DEBUG', true );
define( 'WP_DISABLE_FATAL_ERROR_HANDLER', true );
define( 'SAVEQUERIES', false );
define( 'JETPACK_DEV_DEBUG', true );
@ini_set( 'display_errors', 0 );
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
  noroot cat <<EOF >> /home/vagrant/.bashrc

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

# Install Composer
install_composer() {
  cd ${VVV_PATH_TO_SITE}
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  php -r "if (hash_file('SHA384', 'composer-setup.php') === '669656bab3166a7aff8a7506b8cb2d1c292f042046c5a994c43155c0be6190fa0355160742ab2e1c88d40d5be660b410') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); } echo PHP_EOL;"
  php composer-setup.php
  php -r "unlink('composer-setup.php');"

  # Install composer required libraries
  cd ${VVV_PATH_TO_SITE}
  noroot composer update && noroot composer install
}

setup_database
setup_nginx_folders

# Setup Nginx config
copy_nginx_configs


cd ${VVV_PATH_TO_SITE}/public_html

if [ -z "${HTDOCS_REPO}" ]; then

  # Setup our WPEngine starter project in the htdocs/public_html folder
  # before that folder is created
  echo "\nChecking out WPEngine starter project at ${HTDOCS_REPO}"


  # Create git repository, add origin remote and do first pull
  echo "\n Initializing git repo in htdocs/public_html folder"
  git init
  echo "\nAdding git remote"
  git remote add origin ${HTDOCS_REPO}
  echo "\nPulling master branch from ${HTDOCS_REPO}"
  git pull --recurse-submodules origin master
  cd ${VVV_PATH_TO_SITE}

fi


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

install_composer
install_yarn
yarn_global

# Replace domains in config template
sed -i "s#{{DOMAINS_HERE}}#${DOMAINS}#" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"

# Install Liquidprompt on first provision only
if [[ ! -d "/home/vagrant/liquidprompt" ]]; then
  install_liquidprompt
fi


echo " * Site Template provisioner script completed for ${VVV_SITE_NAME}"
