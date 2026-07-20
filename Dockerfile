# Railway строит из корня репозитория. Этот Dockerfile переопределяет
# авто-детект (иначе Railway пытается собрать Package.swift под Linux и падает).
# Раздаём статический лендинг из landing/ через Caddy.
FROM caddy:alpine
COPY landing/ /usr/share/caddy
# Railway передаёт порт в $PORT
CMD ["sh", "-c", "caddy file-server --root /usr/share/caddy --listen :${PORT:-8080}"]
