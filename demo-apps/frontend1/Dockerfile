FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
RUN sed -i 's/frontend1/frontend1/g' /usr/share/nginx/html/index.html
EXPOSE 80
