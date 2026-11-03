#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pomocne funkcije

die() {
    echo "ERROR: $1" >&2
    exit "${2:-2}"
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

    echo "input=$cli_input"
    echo "config=$cli_config"
    echo "workers=$cli_workers"

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
