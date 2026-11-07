#!/bin/sh
# AssistentD | prepara n8n antes de encenderlo:
# registra la conexion a la base de datos y publica los tres flujos.
set -e
echo "[AssistentD] Registrando la conexion con la base de datos..."
umask 077
cat > /tmp/conexion.json <<JSON
[{"id":"adxBaseDatos0001","name":"Base AssistentD","type":"postgres",
  "data":{"host":"${DB_POSTGRESDB_HOST}","port":${DB_POSTGRESDB_PORT},"database":"${DB_POSTGRESDB_DATABASE}",
          "user":"${DB_POSTGRESDB_USER}","password":"${DB_POSTGRESDB_PASSWORD}","ssl":"disable",
          "allowUnauthorizedCerts":false,"maxConnections":10}}]
JSON
n8n import:credentials --input=/tmp/conexion.json
rm -f /tmp/conexion.json

FLUJOS="adxConversacion1 adxServicios0001 adxRutinas000001"
echo "[AssistentD] Actualizando flujos..."
for id in $FLUJOS; do n8n unpublish:workflow --id="$id" >/dev/null 2>&1 || true; done
n8n import:workflow --separate --input=/adx/flujos
for id in $FLUJOS; do n8n publish:workflow --id="$id"; done
echo "[AssistentD] Motor preparado."
