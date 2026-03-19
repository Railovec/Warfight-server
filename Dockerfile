FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    ca-certificates \
    libfontconfig1 \
    libxcursor1 \
    libxinerama1 \
    libxrandr2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Kopíruj OBA súbory
COPY server.x86_64 /app/server.x86_64
COPY server.pck /app/server.pck

RUN chmod +x /app/server.x86_64

CMD ["./server.x86_64", "--headless"]