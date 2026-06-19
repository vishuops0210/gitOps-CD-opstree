FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
RUN sed -i 's/APP_NAME/APP_NAME/g' /usr/share/nginx/html/index.html
EXPOSE 80
