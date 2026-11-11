#!/bin/bash
# EC2 최초 부팅 시 1회 실행된다 (cloud-init). 실행 로그: /var/log/cloud-init-output.log
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y nginx

# Ubuntu Nginx 패키지의 기본 환영 페이지를 /에서 그대로 제공한다.
# /health만 파일이 아닌 고정 응답으로 추가한다.
cat > /etc/nginx/sites-available/default <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;
    root /var/www/html;
    index index.nginx-debian.html;

    location = /health {
        access_log off;
        default_type text/plain;
        return 200 "OK\n";
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX

nginx -t
systemctl enable --now nginx
systemctl reload nginx
