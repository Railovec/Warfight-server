#!/bin/bash
# Spusti Godot server na porte 9080 (interný)
/app/server.x86_64 --headless &

# Počkaj sekundu
sleep 1

# Spusti nginx ktorý počúva na PORT (Render) a preposiela na 9080
nginx -g "daemon off;"