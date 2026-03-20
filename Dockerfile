# 1. Použijeme stabilný základ Linuxu
FROM ubuntu:22.04

# 2. Nainštalujeme knižnice, ktoré Godot potrebuje, aby vôbec naštartoval
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libfontconfig1 \
    libxcursor1 \
    libxinerama1 \
    libxrandr2 \
    librenderdoc-dev \
    && rm -rf /var/lib/apt/lists/*

# 3. Nastavíme priečinok, kde sa bude vnútri servera pracovať
WORKDIR /app

# 4. Skopírujeme tvoj vyexportovaný súbor (musí sa volať server.x86_64)
COPY server.x86_64 /app/server.x86_64

# 5. Povieme systému, že tento súbor sa dá spustiť ako program
RUN chmod +x /app/server.x86_64

# 6. Príkaz na spustenie servera v "headless" móde (bez obrazovky)
# Render automaticky posiela PORT, Godot ho musí spracovať v kóde
CMD ["./server.x86_64", "--headless"]