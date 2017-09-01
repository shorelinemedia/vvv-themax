#!/usr/bin/env bash
# Provision WordPress Stable

DOMAIN=`get_primary_host "${VVV_SITE_NAME}".dev`
DOMAINS=`get_hosts "${DOMAIN}"`
SITE_TITLE=`get_config_value 'site_title' "${DOMAIN}"`
WP_VERSION=`get_config_value 'wp_version' 'latest'`
WP_TYPE=`get_config_value 'wp_type' "single"`
DB_NAME=`get_config_value 'db_name' "${VVV_SITE_NAME}"`
DB_NAME=${DB_NAME//[\\\/\.\<\>\:\"\'\|\?\!\*-]/}
ADMIN_NAME=`get_config_value 'admin_name' "shoreline-admin"`
ADMIN_EMAIL=`get_config_value 'admin_email' "team@shoreline.media"`
ADMIN_PASSWORD=`get_config_value 'admin_password' "password"`
HTDOCS_REPO=`get_config_value 'htdocs' "git@bitbucket.org:shorelinemedia/shoreline-wpe-starter.git"`

mailcatcher_setup() {
  # Mailcatcher
  #
  # Installs mailcatcher using RVM. RVM allows us to install the
  # current version of ruby and all mailcatcher dependencies reliably.
  local pkg
  local rvm_version
  local mailcatcher_version

  rvm_version="$(/usr/bin/env rvm --silent --version 2>&1 | grep 'rvm ' | cut -d " " -f 2)"
  # RVM key D39DC0E3
  # Signatures introduced in 1.26.0
  gpg -q --no-tty --batch --keyserver "hkp://keyserver.ubuntu.com:80" --recv-keys D39DC0E3
  gpg -q --no-tty --batch --keyserver "hkp://keyserver.ubuntu.com:80" --recv-keys BF04FF17

  printf " * RVM [not installed]\n Installing from source"
  curl --silent -L "https://raw.githubusercontent.com/rvm/rvm/stable/binscripts/rvm-installer" | sudo bash -s stable --ruby
  source "/usr/local/rvm/scripts/rvm"

  mailcatcher_version="$(/usr/bin/env mailcatcher --version 2>&1 | grep 'mailcatcher ' | cut -d " " -f 2)"
  echo " * Mailcatcher [not installed]"
  /usr/bin/env rvm default@mailcatcher --create do gem install mailcatcher --no-rdoc --no-ri
  /usr/bin/env rvm wrapper default@mailcatcher --no-prefix mailcatcher catchmail

}

mailcatcher_setup

# Create an SSH config file on host to make sure host forwarding works
noroot cat <<EOF >> ~/.ssh/config

Host bitbucket.org shoreline-bitbucket
  HostName bitbucket.org
  User git
  IdentitiesOnly yes
  ForwardAgent yes

Host github.com shoreline-github
  Hostname github.com
  User git
  IdentitiesOnly yes
  ForwardAgent yes

EOF

# Setup our WPEngine starter project in the htdocs/public_html folder
# before that folder is created
echo "\nChecking out WPEngine starter project at ${HTDOCS_REPO}"

# If there is no public_html directory, create it
if [[ ! -d "${VVV_PATH_TO_SITE}/public_html" ]]; then
  cd ${VVV_PATH_TO_SITE} && mkdir public_html
else
  echo "\nThere's already an htdocs/public_html folder (skipping directory creation)"
fi

# Create git repository, add origin remote and do first pull
cd ${VVV_PATH_TO_SITE}/public_html
echo "\n Initializing git repo in htdocs/public_html folder"
git init
echo "\nAdding git remote"
git remote add origin ${HTDOCS_REPO}
echo "\nPulling master branch from ${HTDOCS_REPO}"
git pull --recurse-submodules origin master
cd ${VVV_PATH_TO_SITE}


# Make a database, if we don't already have one
echo -e "\nCreating database '${DB_NAME}' (if it's not already there)"
mysql -u root --password=root -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME}"
mysql -u root --password=root -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO wp@localhost IDENTIFIED BY 'wp';"
echo -e "\n DB operations done.\n\n"

# Nginx Logs
mkdir -p ${VVV_PATH_TO_SITE}/log
touch ${VVV_PATH_TO_SITE}/log/error.log
touch ${VVV_PATH_TO_SITE}/log/access.log

# Install and configure the latest stable version of WordPress
if [[ ! -f "${VVV_PATH_TO_SITE}/public_html/wp-load.php" ]]; then
    echo "Downloading WordPress..."
	noroot wp core download --version="${WP_VERSION}"
fi

if [[ ! -f "${VVV_PATH_TO_SITE}/public_html/wp-config.php" ]]; then
  echo "Configuring WordPress Stable..."
  WP_CACHE_KEY_SALT=`date +%s | sha256sum | head -c 64`
  noroot wp core config --dbname="${DB_NAME}" --dbuser=wp --dbpass=wp --quiet --extra-php <<PHP

define( 'WP_CACHE', true );
define( 'WP_CACHE_KEY_SALT', '$WP_CACHE_KEY_SALT' );
define( 'WP_DEBUG', true );
define( 'WP_DEBUG_LOG', true );
define( 'WP_DEBUG_DISPLAY', false );
define( 'SAVEQUERIES', false );
define( 'JETPACK_DEV_DEBUG', true );
@ini_set( 'display_errors', 0 );
define( 'WP_LOCAL_DEV', true );
define( 'WP_ENV', 'development' );

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

cp -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf.tmpl" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
sed -i "s#{{DOMAINS_HERE}}#${DOMAINS}#" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"

# Install Composer
cd ${VVV_PATH_TO_SITE}
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php -r "if (hash_file('SHA384', 'composer-setup.php') === '669656bab3166a7aff8a7506b8cb2d1c292f042046c5a994c43155c0be6190fa0355160742ab2e1c88d40d5be660b410') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); } echo PHP_EOL;"
php composer-setup.php
php -r "unlink('composer-setup.php');"

# Install composer required libraries
cd ${VVV_PATH_TO_SITE}
noroot composer update && noroot composer install

# Activate plugins we installed with composer
noroot wp plugin activate wordpress-seo mailchimp-for-wp members


# Install bower & gulp
echo "---Installing bower & gulp for dependency management & dev tools---"
npm install -g bower gulp-cli
