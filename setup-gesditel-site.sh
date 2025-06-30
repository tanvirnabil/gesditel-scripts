#!/bin/bash

# Check for required argument
if [ -z "$1" ]; then
  echo "❌ Usage: $0 <subdomain>"
  exit 1
fi

SUBDOMAIN="$1"
CONFIG_PATH="/etc/apache2/sites-available"
WWW_PATH="/var/www/html"
CERT_PATH="/etc/ssl/wildcard/certificate.pem"
APP_DIR="qalliEz"

# File paths
CONFIG1="${CONFIG_PATH}/config-${SUBDOMAIN}.gesditel.app.conf"
CONFIG2="${CONFIG_PATH}/${SUBDOMAIN}.gesditel.app.conf"

echo "📄 Creating Apache config for config-${SUBDOMAIN}.gesditel.app..."
cat > "$CONFIG1" <<EOF
<VirtualHost *:80>
 ServerName config-${SUBDOMAIN}.gesditel.app
 Redirect permanent / https://config-${SUBDOMAIN}.gesditel.app/
</VirtualHost>
<VirtualHost *:443>
 ServerName config-${SUBDOMAIN}.gesditel.app
 DocumentRoot ${WWW_PATH}
 SSLEngine on
 SSLCertificateFile ${CERT_PATH}
 <Directory ${WWW_PATH}>
 Options Indexes FollowSymLinks
 AllowOverride All
 Require all granted
 </Directory>
</VirtualHost>
EOF

echo "📄 Creating Apache config for ${SUBDOMAIN}.gesditel.app..."
cat > "$CONFIG2" <<EOF
<VirtualHost *:80>
 ServerName ${SUBDOMAIN}.gesditel.app
 Redirect permanent / https://${SUBDOMAIN}.gesditel.app/
</VirtualHost>
<VirtualHost *:443>
 ServerName ${SUBDOMAIN}.gesditel.app
 DocumentRoot ${WWW_PATH}/${APP_DIR}
 SSLEngine on
 SSLCertificateFile ${CERT_PATH}
 <Directory ${WWW_PATH}/${APP_DIR}>
 Options Indexes FollowSymLinks
 AllowOverride All
 Require all granted
 </Directory>
</VirtualHost>
EOF

echo "✅ Enabling sites..."
sudo a2ensite "config-${SUBDOMAIN}.gesditel.app.conf"
sudo a2ensite "${SUBDOMAIN}.gesditel.app.conf"

echo "🔄 Reloading Apache..."
sudo systemctl reload apache2

echo "🔧 Replacing domain inside project files..."
grep -rl "demo.gesditel.app" "${WWW_PATH}/${APP_DIR}" | xargs -I {} sed -i "s/demo.gesditel.app/${SUBDOMAIN}.gesditel.app/g" {}

echo "✅ Done! Apache config and domain replacement completed for ${SUBDOMAIN}.gesditel.app"
