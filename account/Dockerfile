FROM nginxinc/nginx-unprivileged:stable-alpine
COPY account/nginx.conf /etc/nginx/conf.d/default.conf
COPY apps/fountain/priv/account_app/ /usr/share/nginx/html/
COPY apps/fountain/priv/static/assets/tokens.css /usr/share/nginx/html/assets/tokens.css
COPY apps/fountain/priv/static/images/app-icon.png /usr/share/nginx/html/images/app-icon.png
EXPOSE 8080
