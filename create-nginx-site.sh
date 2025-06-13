#!/bin/bash

# ---------------- CONFIGURACIÓN GENERAL ----------------
WEB_ROOT_BASE="/var/www"
NGINX_DIR="/etc/nginx"
SITES_AVAILABLE="$NGINX_DIR/sites-available"
SITES_ENABLED="$NGINX_DIR/sites-enabled"

# ---------------- INPUT INTERACTIVO ----------------
read -p "🔤 Ingresa el nombre del dominio (ej. app.tudominio.com): " DOMAIN
read -p "🔧 Tipo de proyecto (laravel, php, html, vue): " TYPE

# ---------------- VALIDACIÓN BÁSICA ----------------
if [[ -z "$DOMAIN" || -z "$TYPE" ]]; then
  echo "❌ Dominio y tipo son requeridos."
  exit 1
fi

# Verificar DNS antes de intentar generar certificado
if ! dig +short "$DOMAIN" | grep -qE '^[0-9.]+'; then
  echo "❌ El dominio $DOMAIN no apunta a esta máquina. Configura su DNS antes de continuar."
  exit 1
fi

# Eliminar configuración anterior si existe
if [ -f "$SITES_AVAILABLE/$DOMAIN" ]; then
  echo "⚠️ Reemplazando configuración previa de $DOMAIN..."
  rm -f "$SITES_AVAILABLE/$DOMAIN"
  rm -f "$SITES_ENABLED/$DOMAIN"
fi

# ---------------- RUTA Y PHP SOCKET ----------------
WEB_ROOT="$WEB_ROOT_BASE/$DOMAIN"
PHP_SOCKET=$(find /var/run/php/ -type s -name "php*-fpm.sock" | sort -Vr | head -n 1)

if [[ "$TYPE" =~ ^(php|laravel)$ ]] && [[ -z "$PHP_SOCKET" ]]; then
  echo "❌ No se encontró socket PHP-FPM necesario."
  exit 1
fi

mkdir -p "$WEB_ROOT"
echo "📁 Root creado en $WEB_ROOT"

# ---------------- GENERAR CONFIGURACIÓN ----------------
cat > "$SITES_AVAILABLE/$DOMAIN" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
EOF

# Laravel root en /public
if [[ "$TYPE" == "laravel" ]]; then
  mkdir -p "$WEB_ROOT/public"
  echo "    root $WEB_ROOT/public;" >> "$SITES_AVAILABLE/$DOMAIN"
else
  echo "    root $WEB_ROOT;" >> "$SITES_AVAILABLE/$DOMAIN"
fi

cat >> "$SITES_AVAILABLE/$DOMAIN" <<EOF
    index index.php index.html index.htm;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    client_max_body_size 50M;
EOF

case "$TYPE" in
  laravel)
cat >> "$SITES_AVAILABLE/$DOMAIN" <<EOF

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
EOF
    ;;
  php)
cat >> "$SITES_AVAILABLE/$DOMAIN" <<EOF

    location / {
        try_files \$uri =404;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
EOF
    ;;
  html)
cat >> "$SITES_AVAILABLE/$DOMAIN" <<EOF

    location / {
        try_files \$uri \$uri/ =404;
    }
EOF
    ;;
  vue)
cat >> "$SITES_AVAILABLE/$DOMAIN" <<EOF

    location / {
        try_files \$uri \$uri/ /index.html;
    }
EOF
    ;;
  *)
    echo "❌ Tipo de proyecto no soportado: $TYPE"
    rm -f "$SITES_AVAILABLE/$DOMAIN"
    exit 1
    ;;
esac

echo "}" >> "$SITES_AVAILABLE/$DOMAIN"

# ---------------- CERTIFICADO SSL ----------------
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

if [ ! -d "$CERT_DIR" ]; then
  echo "🔐 Intentando generar certificado SSL para $DOMAIN..."
  certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@$DOMAIN || {
    echo "❌ Certbot falló. Revisa el dominio o el log: /var/log/letsencrypt/letsencrypt.log"
    rm -f "$SITES_AVAILABLE/$DOMAIN"
    exit 1
  }
else
  echo "✅ Certificado SSL ya existente."
fi

# ---------------- HABILITAR SITIO ----------------
ln -s "$SITES_AVAILABLE/$DOMAIN" "$SITES_ENABLED/" 2>/dev/null

nginx -t && systemctl reload nginx && \
echo "✅ Sitio $DOMAIN creado y habilitado en Nginx." || {
  echo "❌ Error al validar o recargar Nginx."
  rm -f "$SITES_ENABLED/$DOMAIN"
  exit 1
}
