#!/usr/bin/env bash
# =============================================================================
# cluster-status.sh — Estado del cluster k3s-moodle (SOLO LECTURA)
# =============================================================================
# Junta en una sola vista lo que normalmente se revisa comando por comando:
#   API por la VIP, nodos, quién tiene la VIP (lease vs ARP), etcd,
#   pods agrupados por nodo, Galera (wsrep_*), garbd, MaxScale, Longhorn
#   (volúmenes, réplicas, share-managers), PV/PVC, ingress/LB/HPA/certs
#   y los últimos eventos Warning.
#
# No modifica nada: solo kubectl get, kubectl exec de consultas, ping e ip neigh.
#
# Uso:  ./cluster-status.sh [-a] [-n] [-w SEG] [-h]
#   -a       Incluir pods de namespaces de sistema en la vista por nodo
#   -n       Rápido: sin kubectl exec (omite consultas a Galera y MaxScale)
#   -w SEG   Refrescar cada SEG segundos (Ctrl+C para salir)
#   -h       Esta ayuda
#
# Variables opcionales:
#   CLUSTER_ENV            ruta a cluster.env (default: junto al script)
#   CLUSTER_VIP            VIP de kube-vip (default: cluster.env o 192.168.1.200)
#   GALERA_EXPECTED_SIZE   wsrep_cluster_size esperado (default: 3, incluye garbd)
#   MAXCTRL_USER/MAXCTRL_PASS  credenciales de maxctrl si no son las default
#   NO_COLOR=1             sin colores
# =============================================================================
set -uo pipefail
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

if [[ -z "${KUBECONFIG:-}" ]]; then
    if [[ -r /etc/rancher/k3s/k3s.yaml ]]; then KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    else KUBECONFIG="$HOME/.kube/config"; fi
fi
export KUBECONFIG

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_ENV="${CLUSTER_ENV:-$SCRIPT_DIR/cluster.env}"
# shellcheck disable=SC1090
[[ -f "$CLUSTER_ENV" ]] && source "$CLUSTER_ENV"
VIP="${CLUSTER_VIP:-192.168.1.200}"
GALERA_EXPECTED_SIZE="${GALERA_EXPECTED_SIZE:-3}"

SYSTEM_NS_RE='^(kube-system|kube-public|kube-node-lease|longhorn-system|cert-manager)$'
KTIMEOUT=8s
EXEC_TIMEOUT=10
LEASE_STALE_SECS=15
ETCD_TLS=/var/lib/rancher/k3s/server/tls/etcd

SHOW_ALL=0; NO_EXEC=0; WATCH=""

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while getopts ":anw:h" opt; do
    case $opt in
        a) SHOW_ALL=1 ;;
        n) NO_EXEC=1 ;;
        w) [[ $OPTARG =~ ^[1-9][0-9]*$ ]] || { echo "-w requiere segundos > 0" >&2; exit 2; }
           WATCH=$OPTARG ;;
        h) usage; exit 0 ;;
        :) echo "-$OPTARG requiere un valor" >&2; exit 2 ;;
        *) echo "Opción inválida: -$OPTARG" >&2; usage >&2; exit 2 ;;
    esac
done

# ── Colores (se deciden una vez; en modo -w la salida se captura en subshell) ─
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
    R=""; G=""; Y=""; C=""; B=""; D=""; N=""
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
k()    { kubectl --request-timeout="$KTIMEOUT" "$@"; }
hdr()  { printf '\n%s%s▌ %s%s\n' "$B" "$C" "$1" "$N"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s▲%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$R" "$N" "$*"; }
info() { printf '  %s•%s %s\n' "$D" "$N" "$*"; }
cls_color() { case $1 in ok) printf '%s' "$G";; warn) printf '%s' "$Y";; done) printf '%s' "$D";; *) printf '%s' "$R";; esac; }

secs_since() {   # RFC3339 -> segundos transcurridos (99999 si no se puede parsear)
    local t; t=$(date -d "$1" +%s 2>/dev/null) || { echo 99999; return; }
    echo $(( $(date +%s) - t ))
}
node_ip() { awk -F'|' -v n="$1" '$1==n{print $2; exit}' <<<"$NODES_RAW"; }
node_by_ip() { awk -F'|' -v ip="$1" '$2==ip{print $1; exit}' <<<"$NODES_RAW"; }
crd_exists() { k get crd "$1" >/dev/null 2>&1; }

# ── Carga de datos compartidos (una sola llamada por recurso) ────────────────
load_data() {
    LOCAL_IPS=$(ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')

    NODES_RAW=$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}|{.status.addresses[?(@.type=="InternalIP")].address}|{.status.nodeInfo.architecture}|{.status.nodeInfo.kubeletVersion}|{.spec.unschedulable}|{range .status.conditions[?(@.status=="True")]}{.type},{end}{"\n"}{end}' 2>/dev/null)
    [[ -z $NODES_RAW ]] && return 1

    local raw
    raw=$(k get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.spec.nodeName}|{.status.phase}|{.metadata.deletionTimestamp}|{range .status.containerStatuses[*]}{.ready},{.restartCount},{.state.waiting.reason}{.state.terminated.reason};{end}{"\n"}{end}' 2>/dev/null)

    # POD_TABLE: nodo|ns|pod|listos/total|estado|reinicios|clase(ok|warn|bad|done)
    POD_TABLE=$(awk -F'|' 'NF>=5 {
        ns=$1; name=$2; node=($3=="" ? "(sin-asignar)" : $3); phase=$4; del=$5
        n=split($6, cs, ";"); tot=0; rdy=0; rst=0; reason=""
        for (i=1; i<=n; i++) {
            if (cs[i]=="") continue
            split(cs[i], f, ","); tot++
            if (f[1]=="true") rdy++
            rst += f[2]
            if (f[3]!="" && reason=="") reason=f[3]
        }
        if (del!="")         st="Terminating"
        else if (reason!="") st=reason
        else                 st=phase
        if (phase=="Succeeded")                                cls="done"
        else if (st=="Running" && rdy==tot)                    cls="ok"
        else if (st ~ /^(Running|Pending|ContainerCreating|PodInitializing|Terminating)$/) cls="warn"
        else                                                   cls="bad"
        printf "%s|%s|%s|%d/%d|%s|%d|%s\n", node, ns, name, rdy, tot, st, rst, cls
    }' <<<"$raw" | sort -t'|' -k1,1 -k2,2 -k3,3)

    LOCAL_NODE=""
    local n ip _r
    while IFS='|' read -r n ip _r; do
        [[ -n $ip ]] && grep -qxF "$ip" <<<"$LOCAL_IPS" && LOCAL_NODE=$n
    done <<<"$NODES_RAW"

    VIP_LEASE_HOLDER=$(k -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
    VIP_ARP_OWNER=$(arp_owner)
}

# Quién contesta realmente por la VIP en la red (plano de datos), para
# contrastarlo con lo que dice el lease (plano de control).
arp_owner() {
    local n ip _r vipmac mac
    if grep -qxF "$VIP" <<<"$LOCAL_IPS"; then echo "${LOCAL_NODE:-$(hostname -s)}"; return; fi
    ping -c1 -W1 "$VIP" >/dev/null 2>&1
    vipmac=$(ip neigh show "$VIP" 2>/dev/null | awk '/lladdr/{print $5; exit}')
    [[ -z $vipmac ]] && return
    while IFS='|' read -r n ip _r; do
        [[ -z $ip ]] && continue
        grep -qxF "$ip" <<<"$LOCAL_IPS" && continue
        ping -c1 -W1 "$ip" >/dev/null 2>&1
        mac=$(ip neigh show "$ip" 2>/dev/null | awk '/lladdr/{print $5; exit}')
        [[ -n $mac && $mac == "$vipmac" ]] && { echo "$n"; return; }
    done <<<"$NODES_RAW"
    echo "desconocido (MAC $vipmac)"
}

# ── Secciones ────────────────────────────────────────────────────────────────
sec_api() {
    hdr "API / VIP $VIP"
    local code r
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 4 "https://$VIP:6443/readyz" 2>/dev/null)
    case $code in
        200|401|403) ok "kube-apiserver responde por la VIP (HTTP $code)" ;;
        *)           bad "kube-apiserver NO responde por la VIP (HTTP ${code:-000})" ;;
    esac
    r=$(k get --raw='/readyz/etcd' 2>/dev/null)
    if [[ $r == ok ]]; then ok "etcd sano según el apiserver local"; else bad "etcd: ${r:-sin respuesta}"; fi
}

sec_nodes() {
    hdr "Nodos"
    printf '  %s%-24s %-15s %-8s %-14s %-10s %-4s %s%s\n' "$D" NODO IP ARCH VERSION ESTADO VIP NOTAS "$N"
    local n ip arch ver unsched conds st col press notes vipcell
    while IFS='|' read -r n ip arch ver unsched conds; do
        [[ -z $n ]] && continue
        if [[ ",$conds" == *",Ready,"* ]]; then st=Ready; col=$G; else st=NotReady; col=$R; fi
        [[ $unsched == true ]] && { st="$st,NoSch"; col=$Y; }
        press=$(tr ',' '\n' <<<"$conds" | grep -vx -e Ready -e '' | paste -sd, -)
        notes=""
        [[ -n $press ]] && notes+="${R}${press}${N} "
        [[ $n == "$LOCAL_NODE" ]] && notes+="${D}◀ este equipo${N}"
        if [[ $n == "$VIP_LEASE_HOLDER" ]]; then vipcell="${G}★${N}   "; else vipcell="    "; fi
        printf '  %-24s %-15s %-8s %-14s %s%-10s%s %s %s\n' \
            "$n" "$ip" "$arch" "$ver" "$col" "$st" "$N" "$vipcell" "$notes"
    done <<<"$NODES_RAW"
}

sec_kubevip() {
    hdr "kube-vip"
    local leases name holder renew s label
    leases=$(k -n kube-system get lease -o jsonpath='{range .items[*]}{.metadata.name}|{.spec.holderIdentity}|{.spec.renewTime}{"\n"}{end}' 2>/dev/null \
             | grep -E '^(plndr|kubevip)')
    if [[ -z $leases ]]; then
        warn "No encontré leases de kube-vip (plndr-* / kubevip-*) en kube-system"
    else
        while IFS='|' read -r name holder renew; do
            case $name in
                plndr-cp-lock)   label="Lease VIP control-plane" ;;
                plndr-svcs-lock) label="Lease VIP services" ;;
                *)               label="Lease $name" ;;
            esac
            s=$(secs_since "$renew")
            if [[ -z $holder ]]; then
                bad "$label: sin líder"
            elif (( s > LEASE_STALE_SECS )); then
                warn "$label → $holder, pero sin renovar hace ${s}s (¿líder caído?)"
            else
                ok "$label → ${B}${holder}${N} (renovado hace ${s}s)"
            fi
        done <<<"$leases"
    fi

    if [[ -z $VIP_ARP_OWNER ]]; then
        bad "ARP: nadie responde por $VIP en la red"
    elif [[ $VIP_ARP_OWNER == "$VIP_LEASE_HOLDER" ]]; then
        ok "ARP: $VIP la contesta $VIP_ARP_OWNER (coincide con el lease)"
    else
        warn "ARP: $VIP la contesta $VIP_ARP_OWNER, pero el lease dice ${VIP_LEASE_HOLDER:-nadie}"
    fi

    local node ns pod ready st rst cls
    while IFS='|' read -r node ns pod ready st rst cls; do
        [[ $pod == *kube-vip* ]] || continue
        printf '    %-24s %-40s %s%s%s\n' "$node" "$pod" "$(cls_color "$cls")" "$st $ready" "$N"
    done <<<"$POD_TABLE"
}

sec_etcd() {
    hdr "etcd"
    local members
    members=$(k get nodes -l node-role.kubernetes.io/etcd=true -o name 2>/dev/null | wc -l)
    info "Nodos con rol etcd: $members (quórum con $(( members / 2 + 1 )); tolera $(( (members - 1) / 2 )) caída(s))"

    if command -v etcdctl >/dev/null 2>&1 && [[ -r $ETCD_TLS/server-client.key ]]; then
        local out line ep ip node ver db leader
        out=$(ETCDCTL_API=3 timeout "$EXEC_TIMEOUT" etcdctl --endpoints=https://127.0.0.1:2379 \
              --cacert="$ETCD_TLS/server-ca.crt" --cert="$ETCD_TLS/server-client.crt" \
              --key="$ETCD_TLS/server-client.key" endpoint status --cluster -w simple 2>&1)
        if [[ $? -ne 0 ]]; then bad "etcdctl falló: $(head -1 <<<"$out")"; return; fi
        while IFS= read -r line; do
            [[ -z $line ]] && continue
            ep=$(awk -F', ' '{print $1}' <<<"$line")
            ver=$(awk -F', ' '{print $3}' <<<"$line")
            db=$(awk -F', ' '{for(i=4;i<=NF;i++) if ($i ~ /^[0-9.]+ [kMG]?B$/) {print $i; exit}}' <<<"$line")
            leader=$(awk -F', ' '{for(i=4;i<=NF;i++) if ($i=="true"||$i=="false") {print $i; exit}}' <<<"$line")
            ip=${ep#https://}; ip=${ip%:*}
            node=$(node_by_ip "$ip")
            if [[ $leader == true ]]; then
                printf '    %-24s %-15s v%-8s db %-9s %slíder ★%s\n' "${node:-?}" "$ip" "$ver" "$db" "$G" "$N"
            else
                printf '    %-24s %-15s v%-8s db %-9s %sfollower%s\n' "${node:-?}" "$ip" "$ver" "$db" "$D" "$N"
            fi
        done <<<"$out"
    else
        info "Instala etcdctl para ver líder Raft y tamaño de DB por miembro"
    fi
}

sec_pods() {
    hdr "Pods por nodo$( (( SHOW_ALL )) || printf ' %s(sin namespaces de sistema; -a para verlos)%s' "$D" "$N")"
    local cur="" node ns pod ready st rst cls counts tot sys badc vis rcol
    while IFS='|' read -r node ns pod ready st rst cls; do
        [[ -z $node ]] && continue
        if [[ $node != "$cur" ]]; then
            cur=$node
            counts=$(awk -F'|' -v n="$node" -v re="$SYSTEM_NS_RE" \
                '$1==n {t++; if ($2 ~ re) s++; if ($7=="bad") b++} END {printf "%d %d %d", t, s, b}' <<<"$POD_TABLE")
            read -r tot sys badc <<<"$counts"
            vis=$(( SHOW_ALL ? tot : tot - sys ))
            printf '\n  %s▸ %s%s %s(%s)%s  %d pods' "$B" "$node" "$N" "$D" "$(node_ip "$node")" "$N" "$vis"
            (( badc > 0 )) && printf ', %s%d con problemas%s' "$R" "$badc" "$N"
            (( ! SHOW_ALL && sys > 0 )) && printf ' %s[+%d de sistema ocultos]%s' "$D" "$sys" "$N"
            printf '\n'
            (( vis == 0 )) && printf '    %s(sin pods de aplicación)%s\n' "$D" "$N"
        fi
        (( ! SHOW_ALL )) && [[ $ns =~ $SYSTEM_NS_RE ]] && continue
        if (( rst > 0 )); then rcol=$Y; else rcol=$D; fi
        printf '    %-16s %-46s %-5s %s%-18s%s %s↻%s%s\n' \
            "$ns" "$pod" "$ready" "$(cls_color "$cls")" "$st" "$N" "$rcol" "$rst" "$N"
    done <<<"$POD_TABLE"
}

# Consulta wsrep dentro del contenedor (Bitnami expone la root password por env o archivo)
read -r -d '' GALERA_Q <<'EOF'
P="${MARIADB_ROOT_PASSWORD:-}"
[ -z "$P" ] && [ -n "${MARIADB_ROOT_PASSWORD_FILE:-}" ] && P=$(cat "$MARIADB_ROOT_PASSWORD_FILE")
CLI=$(command -v mariadb || command -v mysql)
MYSQL_PWD="$P" "$CLI" -uroot -N -B -e "SHOW GLOBAL STATUS LIKE 'wsrep_%'"
EOF

sec_galera() {
    hdr "Galera"
    local pods line ns pod node phase out size status state ready ccol scol tcol rcol
    pods=$(k get pods -A -l app.kubernetes.io/name=mariadb-galera \
           -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.spec.nodeName}|{.status.phase}{"\n"}{end}' 2>/dev/null)
    if [[ -z $pods ]]; then
        warn "No hay pods con label app.kubernetes.io/name=mariadb-galera"
    else
        printf '  %s%-26s %-24s %-5s %-9s %-10s %s%s\n' "$D" POD NODO SIZE STATUS ESTADO READY "$N"
        while IFS='|' read -r ns pod node phase; do
            [[ -z $pod ]] && continue
            if [[ $phase != Running ]]; then
                printf '  %-26s %-24s %s%s%s\n' "$pod" "$node" "$R" "$phase" "$N"; continue
            fi
            if (( NO_EXEC )); then
                printf '  %-26s %-24s %s(Running; -n sin consulta wsrep)%s\n' "$pod" "$node" "$D" "$N"; continue
            fi
            out=$(timeout "$EXEC_TIMEOUT" kubectl -n "$ns" exec "$pod" -- sh -c "$GALERA_Q" 2>/dev/null)
            if [[ -z $out ]]; then
                printf '  %-26s %-24s %sno pude consultar wsrep%s\n' "$pod" "$node" "$R" "$N"; continue
            fi
            size=$(awk  'tolower($1)=="wsrep_cluster_size"{print $2}' <<<"$out")
            status=$(awk 'tolower($1)=="wsrep_cluster_status"{print $2}' <<<"$out")
            state=$(awk 'tolower($1)=="wsrep_local_state_comment"{print $2}' <<<"$out")
            ready=$(awk 'tolower($1)=="wsrep_ready"{print $2}' <<<"$out")
            [[ $size == "$GALERA_EXPECTED_SIZE" ]] && ccol=$G || ccol=$Y
            [[ $status == Primary ]] && scol=$G || scol=$R
            [[ $state == Synced ]] && tcol=$G || tcol=$Y
            [[ $ready == ON ]] && rcol=$G || rcol=$R
            printf '  %-26s %-24s %s%-5s%s %s%-9s%s %s%-10s%s %s%s%s\n' "$pod" "$node" \
                "$ccol" "$size" "$N" "$scol" "$status" "$N" "$tcol" "$state" "$N" "$rcol" "$ready" "$N"
        done <<<"$pods"
    fi

    local found=0 rst cls
    while IFS='|' read -r node ns pod ready st rst cls; do
        [[ $pod =~ garbd|arbitrator ]] || continue
        found=1
        printf '  %-26s %-24s %s%s %s%s %s(árbitro)%s\n' "$pod" "$node" "$(cls_color "$cls")" "$st" "$ready" "$N" "$D" "$N"
    done <<<"$POD_TABLE"
    (( found )) || warn "No encontré pod de garbd/arbitrator"
}

sec_maxscale() {
    hdr "MaxScale"
    local node ns pod ready st rst cls out found=0
    local -a auth=()
    [[ -n ${MAXCTRL_USER:-} ]] && auth=(-u "$MAXCTRL_USER" -p "${MAXCTRL_PASS:-}")
    while IFS='|' read -r node ns pod ready st rst cls; do
        [[ $pod == *maxscale* && $cls != "done" ]] || continue
        found=1
        printf '  %s%s%s @ %s  %s%s %s%s\n' "$B" "$pod" "$N" "$node" "$(cls_color "$cls")" "$st" "$ready" "$N"
        if [[ $st == Running ]] && (( ! NO_EXEC )); then
            out=$(timeout "$EXEC_TIMEOUT" kubectl -n "$ns" exec "$pod" -- maxctrl "${auth[@]}" list servers 2>&1)
            sed 's/^/      /' <<<"$out"
        fi
    done <<<"$POD_TABLE"
    (( found )) || warn "No encontré pods de MaxScale"
}

sec_longhorn() {
    hdr "Longhorn"
    if ! crd_exists volumes.longhorn.io; then info "Longhorn no está instalado"; return; fi

    local name rdy sch col
    while IFS='|' read -r name rdy sch; do
        [[ -z $name ]] && continue
        [[ $rdy == True && $sch == True ]] && col=$G || col=$Y
        printf '  nodo %-24s %sReady=%s Schedulable=%s%s\n' "$name" "$col" "$rdy" "$sch" "$N"
    done < <(k -n longhorn-system get nodes.longhorn.io \
             -o jsonpath='{range .items[*]}{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}|{.status.conditions[?(@.type=="Schedulable")].status}{"\n"}{end}' 2>/dev/null)

    local vols reps vname state rob att vns pvc want replist rcol
    vols=$(k -n longhorn-system get volumes.longhorn.io \
           -o jsonpath='{range .items[*]}{.metadata.name}|{.status.state}|{.status.robustness}|{.status.currentNodeID}|{.status.kubernetesStatus.namespace}|{.status.kubernetesStatus.pvcName}|{.spec.numberOfReplicas}{"\n"}{end}' 2>/dev/null)
    reps=$(k -n longhorn-system get replicas.longhorn.io \
           -o jsonpath='{range .items[*]}{.spec.volumeName}|{.spec.nodeID}|{.status.currentState}{"\n"}{end}' 2>/dev/null)
    if [[ -z $vols ]]; then info "Sin volúmenes"; else
        printf '\n  %s%-34s %-10s %-10s %-24s %s%s\n' "$D" "PVC" ESTADO SALUD "ADJUNTO EN" "RÉPLICAS (nodo:estado)" "$N"
        while IFS='|' read -r vname state rob att vns pvc want; do
            [[ -z $vname ]] && continue
            case $rob in healthy) rcol=$G;; degraded) rcol=$Y;; faulted) rcol=$R;; *) rcol=$D;; esac
            replist=$(awk -F'|' -v v="$vname" '$1==v{printf "%s%s:%s", sep, $2, $3; sep=" "}' <<<"$reps")
            printf '  %-34s %-10s %s%-10s%s %-24s %s %s(want %s)%s\n' "${vns:-?}/${pvc:-$vname}" "$state" \
                "$rcol" "$rob" "$N" "${att:--}" "${replist:--}" "$D" "$want" "$N"
        done <<<"$vols"
    fi

    local node ns pod ready st rst cls found=0
    while IFS='|' read -r node ns pod ready st rst cls; do
        [[ $pod == share-manager-* ]] || continue
        (( found )) || printf '\n  %sShare-managers RWX (servidor NFS de cada volumen RWX):%s\n' "$D" "$N"
        found=1
        printf '    %-44s @ %-24s %s%s%s\n' "$pod" "$node" "$(cls_color "$cls")" "$st" "$N"
    done <<<"$POD_TABLE"
}

sec_storage() {
    hdr "PersistentVolumes"
    local pvs name phase sc cap claim aff pol pcol released=0
    pvs=$(k get pv -o jsonpath='{range .items[*]}{.metadata.name}|{.status.phase}|{.spec.storageClassName}|{.spec.capacity.storage}|{.spec.claimRef.namespace}/{.spec.claimRef.name}|{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}|{.spec.persistentVolumeReclaimPolicy}{"\n"}{end}' 2>/dev/null)
    if [[ -z $pvs ]]; then info "Sin PVs"; return; fi
    printf '  %s%-38s %-10s %-14s %-7s %-24s %s%s\n' "$D" CLAIM FASE STORAGECLASS TAMAÑO "NODO (afinidad)" POLÍTICA "$N"
    while IFS='|' read -r name phase sc cap claim aff pol; do
        [[ -z $name ]] && continue
        case $phase in Bound) pcol=$G;; Released) pcol=$Y; released=$((released+1));; Available) pcol=$D;; *) pcol=$R;; esac
        [[ $claim == / ]] && claim="(sin claim) $name"
        printf '  %-38s %s%-10s%s %-14s %-7s %-24s %s\n' "$claim" "$pcol" "$phase" "$N" "${sc:--}" "$cap" "${aff:--}" "$pol"
    done <<<"$pvs"
    (( released > 0 )) && warn "$released PV(s) en Released: con Retain no se reutilizan solos, requieren limpieza manual"
}

sec_net() {
    hdr "Ingress / LoadBalancer / HPA / Certificados"
    local ns name hosts _tls host code t ips ports cur des min max cpu ready after days col
    while IFS='|' read -r ns name ips ports; do
        [[ -z $name ]] && continue
        printf '  LB  %-32s %-18s %s\n' "$ns/$name" "${ips:-<pending>}" "$ports"
    done < <(k get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}|{.metadata.name}|{.status.loadBalancer.ingress[*].ip}|{.spec.ports[*].port}{"\n"}{end}' 2>/dev/null)

    while IFS='|' read -r ns name hosts _tls; do
        [[ -z $name ]] && continue
        for host in $hosts; do
            read -r code t < <(curl -sk -o /dev/null -w '%{http_code} %{time_total}' --max-time 10 \
                               --resolve "$host:443:$VIP" "https://$host/" 2>/dev/null || echo "000 -")
            if [[ $code =~ ^[23] ]]; then col=$G; else col=$R; fi
            printf '  ING %-32s https://%-28s vía VIP → %sHTTP %s%s en %ss\n' "$ns/$name" "$host" "$col" "$code" "$N" "$t"
        done
    done < <(k get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.spec.rules[*].host}|{.spec.tls[*].secretName}{"\n"}{end}' 2>/dev/null)

    while IFS='|' read -r ns name cur des min max cpu; do
        [[ -z $name ]] && continue
        printf '  HPA %-32s %s réplicas (deseadas %s, rango %s-%s), CPU %s%%\n' \
            "$ns/$name" "${cur:-?}" "${des:-?}" "${min:-1}" "$max" "${cpu:-?}"
    done < <(k get hpa -A -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.status.currentReplicas}|{.status.desiredReplicas}|{.spec.minReplicas}|{.spec.maxReplicas}|{.status.currentMetrics[0].resource.current.averageUtilization}{"\n"}{end}' 2>/dev/null)

    if crd_exists certificates.cert-manager.io; then
        while IFS='|' read -r ns name ready after; do
            [[ -z $name ]] && continue
            days="?"
            [[ -n $after ]] && days=$(( ( $(date -d "$after" +%s 2>/dev/null || date +%s) - $(date +%s) ) / 86400 ))
            if [[ $ready == True ]]; then col=$G; else col=$R; fi
            printf '  CRT %-32s %sReady=%s%s, vence en %s días\n' "$ns/$name" "$col" "${ready:-?}" "$N" "$days"
        done < <(k get certificates.cert-manager.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}|{.status.notAfter}{"\n"}{end}' 2>/dev/null)
    fi
}

sec_events() {
    hdr "Últimos eventos Warning"
    local ev
    ev=$(k get events -A --field-selector type=Warning --sort-by=.lastTimestamp \
         -o jsonpath='{range .items[*]}{.lastTimestamp}|{.metadata.namespace}|{.involvedObject.kind}/{.involvedObject.name}|{.reason}|{.message}{"\n"}{end}' 2>/dev/null \
         | awk -F'|' '$1 ~ /^[0-9]{4}-/' | tail -n 8)
    if [[ -z $ev ]]; then ok "Sin eventos Warning recientes"; return; fi
    local ts ns obj reason msg
    while IFS='|' read -r ts ns obj reason msg; do
        printf '  %s%s%s %-14s %-40s %s%-18s%s %s\n' "$D" "$(date -d "$ts" '+%H:%M:%S' 2>/dev/null || echo "$ts")" "$N" \
            "$ns" "${obj:0:40}" "$Y" "$reason" "$N" "${msg:0:100}"
    done <<<"$ev"
}

# ── Render ───────────────────────────────────────────────────────────────────
render() {
    printf '%s k3s-moodle · estado del cluster%s   %s   %s(desde %s)%s\n' \
        "$B" "$N" "$(date '+%F %T')" "$D" "${LOCAL_NODE:-$(hostname -s)}" "$N"
    if ! load_data; then
        bad "No pude consultar el API con KUBECONFIG=$KUBECONFIG"
        sec_api
        return 1
    fi
    sec_api
    sec_nodes
    sec_kubevip
    sec_etcd
    sec_pods
    sec_galera
    sec_maxscale
    sec_longhorn
    sec_storage
    sec_net
    sec_events
    echo
}

# ── Main ─────────────────────────────────────────────────────────────────────
command -v kubectl >/dev/null 2>&1 || { echo "kubectl no está en PATH" >&2; exit 1; }
[[ -r $KUBECONFIG ]] || { echo "No puedo leer $KUBECONFIG (¿corres como root?)" >&2; exit 1; }

if [[ -n $WATCH ]]; then
    trap 'printf "%s\n" "$N"; exit 0' INT TERM
    while true; do
        out=$(render 2>&1)
        clear
        printf '%s\n%s(refresco cada %ss · Ctrl+C para salir)%s\n' "$out" "$D" "$WATCH" "$N"
        sleep "$WATCH"
    done
else
    render
fi
