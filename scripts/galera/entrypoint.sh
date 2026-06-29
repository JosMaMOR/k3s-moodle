#!/bin/sh
# entrypoint.sh — lanza garbd en foreground para que K8s lo gestione
set -eu

# Variables inyectadas por el Deployment (alimentadas desde cluster.env)
: "${GALERA_GROUP:?Falta GALERA_GROUP (nombre del clúster Galera)}"
: "${GALERA_ADDRESS:?Falta GALERA_ADDRESS (gcomm://...:4567)}"

echo "[garbd] Grupo:     ${GALERA_GROUP}"
echo "[garbd] Dirección: ${GALERA_ADDRESS}"
echo "[garbd] Opciones:  ${GALERA_OPTIONS:-(ninguna)}"

# Arma los argumentos; --options solo si se definió
set -- --group "${GALERA_GROUP}" \
       --address "${GALERA_ADDRESS}" \
       --log /dev/stdout
if [ -n "${GALERA_OPTIONS:-}" ]; then
  set -- "$@" --options "${GALERA_OPTIONS}"
fi

# exec → garbd queda como PID 1 y recibe las señales de K8s (cierre limpio)
exec garbd "$@"
