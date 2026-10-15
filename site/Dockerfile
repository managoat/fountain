# The pages are rendered by CI (mix site.build) before docker build, so the
# image is nginx plus dist/ and the multi-arch build needs no BEAM.
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist/ /usr/share/nginx/html/
EXPOSE 8080
