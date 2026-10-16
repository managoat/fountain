FROM nginxinc/nginx-unprivileged:stable-alpine
COPY account/nginx.conf /etc/nginx/conf.d/default.conf
COPY apps/fountain/priv/account_app/ /usr/share/nginx/html/
EXPOSE 8080
