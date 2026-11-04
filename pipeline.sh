#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -A CONF
RUN_ID=""
RUN_DIR=""
LOG_FILE=""
CONFIG_WARNINGS=()
# Pomocne funkcije

die() {
    echo "ERROR: $1" >&2
    log ERROR "$1"
    exit "${2:-2}"
}

level_num(){
    case "$1" in
        DEBUG)
        echo 0
        ;;
        INFO)
        echo 1
        ;;
        WARN)
        echo 2
        ;;
        ERROR)
        echo 3
        ;;
    esac
}

log(){
    local nivo="$1"
    local poruka="$2"
    local linija=""

    [[ -n "$LOG_FILE" ]] || return 0
     
    (( $(level_num "$nivo") >= $(level_num "${CONF[log_level]}") )) || return 0

    linija="[$(date '+%Y-%m-%d %H:%M:%S')] $nivo: $poruka"

    if [[ -n "$LOG_FILE" ]]; then
        echo "$linija" >> "$LOG_FILE"
    fi
}


create_run_dir(){
    RUN_ID="run_$(date '+%Y%m%d_%H%M%S')"
    RUN_DIR="${CONF[work_dir]}/$RUN_ID"

    mkdir -p "$RUN_DIR"/{chunks,results,logs} || die "ne mogu da napravim folder: $RUN_DIR"
    LOG_FILE="$RUN_DIR/pipeline.log"
    touch "$LOG_FILE"
}

write_snapshot(){
    local k
    for k in "${!CONF[@]}"; do
        echo "$k=${CONF[$k]}"
    done | sort > "$RUN_DIR/config.snapshot"

}

write_meta(){
    cat > "$RUN_DIR/run.meta" <<EOF
run_id=$RUN_ID
input=$cli_input
started=$(date '+%Y-%m-%d %H:%M:%S')
status=running
EOF

}

set_defaults(){
    CONF[python]="python3"
    CONF[group_by]="region"
    CONF[chunk_lines]=100000
    CONF[workers]=4
    CONF[max_retries]=3
    CONF[backoff_base]=1
    CONF[backoff_max]=30
    CONF[hang_timeout]=10
    CONF[kill_grace]=3
    CONF[max_failed_chunks]=2
    CONF[work_dir]="./runs"
    CONF[keep_chunks]="no"
    CONF[log_level]="INFO"
}

load_config(){
    local fajl="$1"
    local linija kljuc vrednost
    [[ -f "$fajl" ]] || die "konfig fajl ne postoji: $fajl"
    [[ -r "$fajl" ]] || die "konfig fajl ne moze da se cita: $fajl"

    while IFS= read -r linija || [[ -n "$linija" ]]; do

        read -r linija <<< "$linija"

        if [[ -z "$linija" || "$linija" == \#* ]]; then
            continue
        fi
        [[ "$linija" == *=* ]] || die "neispravna linija u konfigu: $linija"
        
        kljuc="${linija%%=*}"
        vrednost="${linija#*=}"

        read -r kljuc <<< "$kljuc"
        read -r vrednost <<< "$vrednost"
        
        case "$kljuc" in
            processor|python|group_by|chunk_lines|workers|max_retries|backoff_base|backoff_max|hang_timeout|kill_grace|max_failed_chunks|work_dir|keep_chunks|log_level) 
                CONF[$kljuc]="$vrednost"
                ;;
            *)
                CONFIG_WARNINGS+=("nepoznat kljuc u konfikgu: $kljuc")
                ;;
        esac
        done < "$fajl"
}


is_pos_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

is_nonneg_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_config(){
    local k

    [[ -n "${CONF[processor]}" ]] || die "obavezan kljuc 'processor' nije zadat u konfigu"

    # pozitivni celi br
    for k in chunk_lines workers hang_timeout; do
        is_pos_int "${CONF[$k]}" ||  die "neispravna vrednost za $k: '${CONF[$k]}' (ocekuje se pozitivan ceo broj)"
    done

    for k in max_retries backoff_base backoff_max kill_grace max_failed_chunks; do
        is_nonneg_int "${CONF[$k]}" || die "neispravna vrednost za $k: '${CONF[$k]}' (ocekuje se ceo broj >= 0)"
    done

    case "${CONF[group_by]}" in
        region|category)
        ;;
        *)
        die "neispravna vrednost za group_by: '${CONF[group_by]}' (dozvoljeno: region, category)"
        ;;
    esac

    case "${CONF[keep_chunks]}" in
        yes|no)
        ;;
        *)
        die "neispravna vrednost za keep_chunks: '${CONF[keep_chunks]}' (dozvoljeno: yes, no)"
        ;;
    esac

    case "${CONF[log_level]}" in
        DEBUG|INFO|WARN|ERROR)
        ;;
        *)
        die "neispravna vrednost za log_level: '${CONF[log_level]}' (dozvoljeno: DEBUG, INFO, WARN ili ERROR)"
        ;;
    esac

    for k in python work_dir; do   
        [[ -n "${CONF[$k]}" ]] || die "vrednost za $k ne sme biti prazna"
    done

}

# Obrada gresaka
preflight_checks() {
    local ulaz="$1"
    local ocekivano="transaction_id,timestamp,region,category,amount,quantity"
    local zaglavlje velicina slobodno

    #python i processor
    command -v "${CONF[python]}" >/dev/null || die "python interapter ne postoji: ${CONF[python]}"
    [[ -f "${CONF[processor]}" ]] || die "processor fajl ne postoji: ${CONF[processor]}"
    #ulazni fajl
    [[ -f "$ulaz" ]] || die "ne postoji ulazni fajl: $ulaz"
    [[ -r "$ulaz" ]] || die "ulazni fajl nije za citanej: $ulaz"
    [[ -s "$ulaz" ]] || die "ulazni fajl je prazan: $ulaz"
    
    zaglavlje="$(head -n 1 "$ulaz")"
    [[ "$zaglavlje" == "$ocekivano" ]] || die "fajl ima pogresno zaglavlje: $zaglavlje (ocekivano: $ocekivano)"

    #work_dir
    mkdir -p "${CONF[work_dir]}" 2>/dev/null || die "ne mogu da napravim work_dir: ${CONF[work_dir]}"
    [[ -w "${CONF[work_dir]}" ]] || die "ne mogu da pisem u work_dir: ${CONF[work_dir]}"


    #prostor na disku
    velicina="$(stat -c %s "$ulaz")"
    slobodno="$(df --output=avail -B1 "${CONF[work_dir]}" | tail -n 1)"
    (( slobodno >= velicina*2 )) || die "nema dovoljno prostora na disku"

}


# Rezim rada

cmd_help() {
    cat <<EOF
Upotreba: ./pipeline.sh <režim> [opcije]

Režimi:
  run --input <fajl> [--config <fajl>] [--workers N] -> pokrece novu obradu
  resume <run_id> -> nastavlja prekinutu obradu
  status [<run_id>] -> prikazuje status obrade (podrazumevano poslednje)
  report <run_id> -> ispisuje izvestaj o zavrsenoj obradi
  list -> lista svih pokretanja
  clean --keep N -> Brise stara pokretanja, cuva N najnovijih
  help -> ispisuje ovo uputstvo
EOF
}

cmd_run() {
    cli_input=""
    cli_config="$SCRIPT_DIR/pipeline.conf"
    cli_workers=""

    while (($# > 0)); do
        case "$1" in
        --input)
            if [[ -z "$2" ]]; then
                die "opcija $1 zahteva vrednost"
            fi
            cli_input="$2"
            shift 2
            ;;
        --config)
            if [[ -z "$2" ]]; then
                die "opcija $1 zahteva vrednost"
            fi
            cli_config="$2"
            shift 2
            ;;
        --workers)
            if [[ -z "$2" ]]; then
                die "opcija $1 zahteva vrednost"
            fi
            cli_workers="$2"
            shift 2
            ;;
        *)
            die "nepoznata opcija: $1"
            ;;
        esac
    done

    [[ -n "$cli_input" ]] || die "opcija --input je obavezna"

    set_defaults
    load_config "$cli_config"
    if [[ -n "$cli_workers" ]]; then
        CONF[workers]="$cli_workers"
    fi
    validate_config
    preflight_checks "$cli_input"
    create_run_dir
    write_snapshot
    write_meta
    log INFO "Run $RUN_ID started (input=$cli_input, workers=${CONF[workers]})"
    for w in "${CONFIG_WARNINGS[@]}"; do
        log WARN "$w"
    done
    echo "RUN $RUN_ID started"



}

cmd_resume() {
    echo "resume: nije implementirano"
}

cmd_status() {
    echo "status: nije implementirano"
}

cmd_report() {
    echo "report: nije implementirano"
}

cmd_list() {
    echo "list: nije implementirano"
}

cmd_clean() {
    echo "clean: nije implementirano"
}

# Glavni deo

rezim="$1"
shift

case "$rezim" in
run)
    cmd_run "$@"
    ;;
resume)
    cmd_resume "$@"
    ;;
status)
    cmd_status "$@"
    ;;
report)
    cmd_report "$@"
    ;;
list)
    cmd_list "$@"
    ;;
clean)
    cmd_clean "$@"
    ;;
help)
    cmd_help
    ;;
"")
    cmd_help >&2
    exit 2
    ;;
*)
    die "nepoznat rezim: '$rezim'"
    ;;
esac
