#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -A CONF

# Pomocne funkcije

die() {
    echo "ERROR: $1" >&2
    exit "${2:-2}"
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
                echo "WARN: nepoznat kljuc: $kljuc" >&2
                ;;
        esac
        done < "$fajl"
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

    for k in "${!CONF[@]}"; do
        echo "$k=${CONF[$k]}"
    done

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
