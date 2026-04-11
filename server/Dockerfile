FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libx11-6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Kopíruje súbory z PODADRESÁRA server (relatívna cesta k build contextu)
COPY server/server.pck .
COPY server/server.x86_64 .

RUN chmod +x server.x86_64

EXPOSE 9080
CMD ["./server.x86_64", "--headless"]
