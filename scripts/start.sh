#!/bin/bash

# Disable Strict Host checking for non interactive git clones

mkdir -p -m 0700 /root/.ssh
echo -e "Host *\n\tStrictHostKeyChecking no\n" >> /root/.ssh/config

if [[ "$GIT_USE_SSH" == "1" ]] ; then
  echo -e "Host *\n\tUser ${GIT_USERNAME}\n\n" >> /root/.ssh/config
fi

if [ ! -z "$SSH_KEY" ]; then
 echo $SSH_KEY > /root/.ssh/id_rsa.base64
 base64 -d /root/.ssh/id_rsa.base64 > /root/.ssh/id_rsa
 chmod 600 /root/.ssh/id_rsa
fi

# Set custom webroot
if [ ! -z "$WEBROOT" ]; then
 sed -i "s#root /var/www/html;#root ${WEBROOT};#g" /etc/nginx/sites-available/default.conf
else
 webroot=/var/www/html
fi

# Setup git variables
if [ ! -z "$GIT_EMAIL" ]; then
 git config --global user.email "$GIT_EMAIL"
fi
if [ ! -z "$GIT_NAME" ]; then
 git config --global user.name "$GIT_NAME"
 git config --global push.default simple
fi

# Dont pull code down if the .git file/folder exists
if [ ! -e "/var/www/html/.git" ]; then
 # Pull down code from git for our site!
 if [ ! -z "$GIT_REPO" ]; then
   # Remove the test index file if you are pulling in a git repo
   if [ ! -z ${REMOVE_FILES} ] && [ ${REMOVE_FILES} == 0 ]; then
     echo "skiping removal of files"
   else
     rm -Rf /var/www/html/*
   fi
   GIT_COMMAND='git clone '
   if [ ! -z "$GIT_BRANCH" ]; then
     GIT_COMMAND=${GIT_COMMAND}" -b ${GIT_BRANCH}"
   fi

   if [ -z "$GIT_USERNAME" ] && [ -z "$GIT_PERSONAL_TOKEN" ]; then
     GIT_COMMAND=${GIT_COMMAND}" ${GIT_REPO}"
   else
    if [[ "$GIT_USE_SSH" == "1" ]]; then
      GIT_COMMAND=${GIT_COMMAND}" ${GIT_REPO}"
    else
      GIT_COMMAND=${GIT_COMMAND}" https://${GIT_USERNAME}:${GIT_PERSONAL_TOKEN}@${GIT_REPO}"
    fi
   fi
   ${GIT_COMMAND} /var/www/html || exit 1
   chown -Rf nginx.nginx /var/www/html
 fi
fi

# Try auto install for composer
if [ -f "/var/www/html/composer.lock" ]; then
  composer install --no-dev --working-dir=/var/www/html
fi

# Enable custom nginx config files if they exist
if [ -f /var/www/html/conf/nginx/nginx-site.conf ]; then
  if [[ "$NGINX_ENVSUBST" = "1" ]] ; then
    envsubst "$NGINX_ENVSUBST_VARS" < /var/www/html/conf/nginx/nginx-site.conf > /etc/nginx/sites-available/default.conf
  else
    cp /var/www/html/conf/nginx/nginx-site.conf /etc/nginx/sites-available/default.conf
  fi
fi

if [ -f /var/www/html/conf/nginx/nginx-site-ssl.conf ]; then
  if [[ "$NGINX_ENVSUBST" = "1" ]] ; then
    envsubst "$NGINX_ENVSUBST_VARS" < /var/www/html/conf/nginx/nginx-site-ssl.conf > /etc/nginx/sites-available/default-ssl.conf
  else
    cp /var/www/html/conf/nginx/nginx-site-ssl.conf /etc/nginx/sites-available/default-ssl.conf
  fi
fi

# Configure FPM
# Ugly, refactor to single sed command later
if [ ! -z "$FPM_pm" ]
then
  sed -i -E "s@\s*;*\s*(pm\s*=\s*).*@\1${FPM_pm}@g" "${fpm_conf}"
fi

if [ ! -z "$FPM_pm_max_children" ]
then
  sed -i -E "s@\s*;*\s*(pm.max_children\s*=\s*).*@\1${FPM_pm_max_children}@g" "${fpm_conf}"
fi

if [ ! -z "$FPM_pm_start_servers" ]
then
  sed -i -E "s@\s*;*\s*(pm.start_servers\s*=\s*).*@\1${FPM_pm_start_servers}@g" "${fpm_conf}"
fi

if [ ! -z "$FPM_pm_min_spare_servers" ]
then
  sed -i -E "s@\s*;*\s*(pm.min_spare_servers\s*=\s*).*@\1${FPM_pm_min_spare_servers}@g" "${fpm_conf}"
fi

if [ ! -z "$FPM_pm_max_spare_servers" ]
then
  sed -i -E "s@\s*;*\s*(pm.max_spare_servers\s*=\s*).*@\1${FPM_pm_max_spare_servers}@g" "${fpm_conf}"
fi

if [ ! -z "$FPM_pm_max_requests" ]
then
  sed -i -E "s@\s*;*\s*(pm.max_requests\s*=\s*).*@\1${FPM_pm_max_requests}@g" "${fpm_conf}"
fi

if [ ! -z "$FPM_pm_process_idle_timeout" ]
then
  sed -i -E "s@\s*;*\s*(pm.process_idle_timeout\s*=\s*).*@\1${FPM_pm_process_idle_timeout}@g" "${fpm_conf}"
fi

# Display PHP error's or not
if [[ "$ERRORS" != "1" ]] ; then
 echo php_flag[display_errors] = off >> "${fpm_conf}"
else
 echo php_flag[display_errors] = on >> "${fpm_conf}"
fi

# Display Version Details or not
if [[ "$HIDE_NGINX_HEADERS" == "0" ]] ; then
 sed -i "s/server_tokens off;/server_tokens on;/g" /etc/nginx/nginx.conf
else
 sed -i "s/expose_php = On/expose_php = Off/g" "${fpm_conf}"
fi

# Pass real-ip to logs when behind ELB, etc
if [[ ! -z "$NGINX_REAL_IP_HEADER" ]] ; then
  NGINX_REAL_IP_FROM=(${NGINX_REAL_IP_FROM})
  CONF_NGINX_REAL_IP_FROM=''

  for (( i=0; i<${#NGINX_REAL_IP_FROM[@]}; i++ ))
  do
    CONF_NGINX_REAL_IP_FROM+="set_real_ip_from ${NGINX_REAL_IP_FROM[$i]}; "
  done
fi

if [[ ! -z "$NGINX_REAL_IP_HEADER" ]] ; then
 sed -i -E "s/#(real_ip_header) X-Forwarded-For;/\1 $NGINX_REAL_IP_HEADER;/" /etc/nginx/sites-available/default.conf
 sed -i "s/#set_real_ip_from/set_real_ip_from/" /etc/nginx/sites-available/default.conf
 if [ ! -z "$NGINX_REAL_IP_FROM" ]; then
  sed -i -E "s|set_real_ip_from 0\.0\.0\.0/0;|${CONF_NGINX_REAL_IP_FROM}|" /etc/nginx/sites-available/default.conf
 fi
fi
# Do the same for SSL sites
if [ -f /etc/nginx/sites-available/default-ssl.conf ]; then
 if [[ ! -z "$NGINX_REAL_IP_HEADER" ]] ; then
  sed -i -E "s/#(real_ip_header) X-Forwarded-For;/\1 $NGINX_REAL_IP_HEADER;/" /etc/nginx/sites-available/default-ssl.conf
  sed -i "s/#set_real_ip_from/set_real_ip_from/" /etc/nginx/sites-available/default-ssl.conf
  if [ ! -z "$NGINX_REAL_IP_FROM" ]; then
   sed -i -E "s|set_real_ip_from 0\.0\.0\.0/0;|${CONF_NGINX_REAL_IP_FROM}|" /etc/nginx/sites-available/default-ssl.conf
  fi
 fi
fi

# Increase the memory_limit
if [ ! -z "$PHP_MEM_LIMIT" ]; then
 sed -i "s/memory_limit = 128M/memory_limit = ${PHP_MEM_LIMIT}M/g" "${php_conf}"
fi

# Increase the post_max_size
if [ ! -z "$PHP_POST_MAX_SIZE" ]; then
 sed -i "s/post_max_size = 100M/post_max_size = ${PHP_POST_MAX_SIZE}M/g" "${php_conf}"
fi

# Increase the upload_max_filesize
if [ ! -z "$PHP_UPLOAD_MAX_FILESIZE" ]; then
 sed -i "s/upload_max_filesize = 100M/upload_max_filesize= ${PHP_UPLOAD_MAX_FILESIZE}M/g" "${php_conf}"
fi

if [ ! -z "$PUID" ]; then
  if [ -z "$PGID" ]; then
    PGID=${PUID}
  fi
  deluser nginx
  addgroup -g ${PGID} nginx
  adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx -u ${PUID} nginx
fi

# Run custom scripts
if [[ "$RUN_SCRIPTS" == "1" ]] ; then
  if [ -d "/var/www/html/scripts/" ]; then
    # make scripts executable incase they aren't
    chmod -Rf 750 /var/www/html/scripts/*
    # run scripts in number order
    for i in `ls /var/www/html/scripts/`; do /var/www/html/scripts/$i ; done
  else
    echo "Can't find script directory"
  fi
fi

# Start supervisord and services
exec /usr/bin/supervisord -n -c /etc/supervisord.conf

