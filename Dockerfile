FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    ca-certificates \
    libfontconfig1 \
    libxcursor1 \
    libxinerama1 \
    libxrandr2 \
    nginx \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY server.x86_64 /app/server.x86_64
COPY server.pck /app/server.pck
COPY nginx.conf /etc/nginx/nginx.conf
COPY start.sh /app/start.sh

RUN chmod +x /app/server.x86_64
RUN chmod +x /app/start.sh

CMD ["/app/start.sh"]