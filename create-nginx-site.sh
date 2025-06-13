#!/bin/bash

# ---------------- CONFIGURACIÓN GENERAL ----------------

DOMAIN="$1"
TYPE="$2"  # Opciones: php, laravel, html, vue
WEB_ROOT_BASE="/var/www"
NGINX_DIR="/etc/nginx"
SITES_AVAILABLE="$NGINX_DIR/sites-available"
SITES_ENABLED="$NGINX_DIR/sites-enabled"
WEB_ROOT="$WEB_ROOT_BASE/$DOMAIN"

# ---------------- VALIDACIÓN ----------------

if [[ -z "$DOMAIN" || -z "$TYPE" ]]; then
  echo "Uso: $0 dominio tipo"
  echo "Ejemplo: $0 midominio.com laravel"
  exit 1
fi

if [ -f "$SITES_AVAILABLE/$DOMAIN" ]; then
  echo "Ya existe configuración para $DOMAIN en $SITES_AVAILABLE"
  exit 1
fi

PHP_SOCKET=$(find /var/run/php/ -type s -name "php*-fpm.sock" | sort -Vr | head -n 1)

if [[ "$TYPE" == "php" || "$TYPE" == "laravel" ]] && [[ -z "$PHP_SOCKET" ]]; then
  echo "No se encontró socket PHP-FPM necesario para tipo '$TYPE'"
  exit 1
fi

# Crear directorio raíz si no existe
mkdir -p "$WEB_ROOT"

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

    root $WEB_ROOT;
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

    root $WEB_ROOT/public;

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
    echo "Tipo no soportado: $TYPE"
    rm -f "$SITES_AVAILABLE/$DOMAIN"
    exit 1
    ;;
esac

echo "}" >> "$SITES_AVAILABLE/$DOMAIN"

# ---------------- HABILITAR SITIO Y RECARGAR ----------------

ln -s "$SITES_AVAILABLE/$DOMAIN" "$SITES_ENABLED/" || {
  echo "Error al crear enlace simbólico"
  exit 1
}

nginx -t && systemctl reload nginx && echo "Sitio $DOMAIN habilitado." || {
  echo "Error en la configuración. Revisa $SITES_AVAILABLE/$DOMAIN"
  exit 1
}
