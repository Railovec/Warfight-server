FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libx11-6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY game_server.x86_64 .
COPY game_server.pck .

RUN chmod +x game_server.x86_64

EXPOSE 8080
CMD ["./game_server.x86_64", "--headless"]