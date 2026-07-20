# Статика лендинга для Railway (root directory сервиса = landing/)
FROM caddy:alpine
COPY . /usr/share/caddy
# Railway передаёт порт в $PORT
CMD ["sh", "-c", "caddy file-server --root /usr/share/caddy --listen :${PORT:-8080}"]
