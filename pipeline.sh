#!/usr/bin/env bash
shopt -s nullglob #  ako *.out ne nađe nijedan fajl, niz je prazan (umesto da sadrži sam tekst "*.out")
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -A CONF
RUN_ID=""
RUN_DIR=""
LOG_FILE=""
CONFIG_WARNINGS=()
MANIFEST=""
CHUNKS=()
RUN_START=0
ABORTED=0

declare -A ERR_OF        # deo → putanja do .err fajla tekuceg pokusaja
declare -A LINES_OF      # deo → broj linija u .err pri poslednjoj proveri
declare -A PROGRESS_AT   # deo → kada se broj linija poslednji put promenio
declare -A HUNG          # deo → 1 ako smo ga ubili zbog zaglavljivanja
declare -A STATE
declare -A TRIES
declare -A READY_AT
declare -A LAST_REASON 
declare -A PID_OF        # deo  PID procesa koji ga obradjuje
declare -A START_OF      # deo  vreme pocetka (za duration_s)
declare -A ATTEMPT_OF    # deo  broj tekuceg pokusaja
# Pomocne funkcije

die() {
    echo "ERROR: $1" >&2
    log ERROR "$1"
    exit "${2:-2}"
}

now(){
    date +%s.%N
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

# samo jedna instanca po pokretanju; druga izlazi odmah sa kodom 3
lock_run(){
    exec 8> "$RUN_DIR/run.lock"
    flock -n 8 || die "nad pokretanjem $RUN_ID vec radi druga instanca" 3
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


split_input(){
    local ulaz="$1"
    local zaglavlje ukupno zbir f n
    local delovi=()

    zaglavlje="$(head -n 1 "$ulaz")"
    ukupno=$(( $(wc -l < "$ulaz") - 1 ))
    (( ukupno > 0 )) || die "ulaz fajla nema redove s podacima"

    #podela bez zaglavlja
    tail -n +2 "$ulaz" | split -l "${CONF[chunk_lines]}" -d -a 5 --numeric-suffixes=1 --additional-suffix=.csv - "$RUN_DIR/chunks/chunk_" \
        || die "deljenje ulaza nije uspelo"

    delovi=( "$RUN_DIR"/chunks/chunk_*.csv )
    for f in "${delovi[@]}"; do
        { echo "$zaglavlje"; cat "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
    done

     # 3) provera: zbir redova u delovima = redovi u ulazu   
    zbir=0
    for f in "${delovi[@]}"; do
        n=$(( $(wc -l < "$f") - 1 ))
        (( zbir += n ))
    done
    (( zbir == ukupno )) || die "provera deljenja nije prosla: ulaz $ukupno redova, delovi $zbir"

    log INFO "Split into ${#delovi[@]} chunks ($ukupno rows)"
}

manifest_init(){
    local f ime n 
    MANIFEST="$RUN_DIR/manifest.csv"

    echo "chunk,status,attempts,rows,duration_s,exit_code,reason" > "$MANIFEST"
    for f in "$RUN_DIR"/chunks/chunk_*.csv; do
        ime="${f##*/}"
        ime="${ime%.csv}"
        n=$(( $(wc -l < "$f") - 1 ))
        echo "$ime,pending,0,$n,,," >> "$MANIFEST"
    done
}

# promeni red jednog dela pod kljuca
manifest_set(){
    local ime="$1" status="$2" pokusaji="$3" trajanje="$4" kod="$5" razlog="$6"
    (
        flock 9
        awk -F, -v OFS=, \
            -v c="$ime" -v s="$status" -v a="$pokusaji" -v d="$trajanje" -v e="$kod" -v r="$razlog" \
            '$1 == c { $2 = s; $3 = a; $5 = d; $6 = e; $7 = r } { print }' \
            "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
    ) 9> "$RUN_DIR/manifest.lock"
}

manifest_get(){
    local ime="$1" kolona="$2"
    awk -F, -v c="$ime" -v k="$kolona" '$1 == c { print $k }' "$MANIFEST"

}

# upisi ili promeni kljuc u run.meta
meta_set(){
    local kljuc="$1" vrednost="$2" f="$RUN_DIR/run.meta"
    awk -F= -v k="$kljuc" -v v="$vrednost" '
        $1 == k { print k "=" v; nadjen = 1; next }
        { print }
        END { if (!nadjen) print k "=" v }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# koliko delova je u datom stanju 
count_state(){
    local trazeno="$1" ime n=0
    for ime in "${CHUNKS[@]}"; do
        [[ "${STATE[$ime]}" == "$trazeno" ]] && (( n++ ))
    done
    echo "$n"
}

validate_output(){
    local izlaz="$1"
    local ulaz="$2"
    local ocekivano="group,count,sum_amount,min_amount,max_amount,sum_quantity"
    local poslednja rows_in groups redova_ulaz redova_grupa
    
    [[ -s "$izlaz" ]] || return 1
    #zaglavlje nije isto
    [[ $(head -n 1 "$izlaz") == "$ocekivano" ]] || return 1

    #linija END
    poslednja="$(tail -n 1 "$izlaz")"
    [[ "$poslednja" =~ ^#END\ rows_in=([0-9]+)\ rows_skipped=([0-9]+)\ groups=([0-9]+)$ ]] || return 1
    rows_in="${BASH_REMATCH[1]}"
    groups="${BASH_REMATCH[3]}"

    #broj redova ulaz
    redova_ulaz=$(( $(wc -l < "$ulaz") - 1 ))
    (( rows_in ==  redova_ulaz)) || return 1

    #groups = broj redova sa grupama
    redova_grupa=$(( $(wc -l < "$izlaz") - 2 ))
    (( groups == redova_grupa )) || return 1

    return 0
}

# izlazni kod
classify_exit(){
    case "$1" in
        1) echo error ;;
        2) echo usage_error ;;
        137) echo crash ;;
        *) echo unknown ;;
    esac
}

# cekanje pre k-tog ponavljanja
backoff_for(){
    local k="$1"
    local d=$(( CONF[backoff_base] * 2 ** (k - 1) ))
    (( d > CONF[backoff_max] )) && d=${CONF[backoff_max]}
    echo "$d"
}

start_chunk(){
    local ime="$1" pokusaj="$2"
    local ulaz="$RUN_DIR/chunks/$ime.csv"
    local izlaz_tmp="$RUN_DIR/chunks/$ime.$pokusaj.out.tmp"
    local err="$RUN_DIR/logs/$ime.$pokusaj.err"

    manifest_set "$ime" running "$pokusaj" "" "" "${LAST_REASON[$ime]}"
    
    "${CONF[python]}" "${CONF[processor]}" \
        --input "$ulaz" --output "$izlaz_tmp" --group-by "${CONF[group_by]}" \
        2> "$err" 8>&- &

    PID_OF[$ime]=$!
    START_OF[$ime]=$(now)
    ATTEMPT_OF[$ime]=$pokusaj
    ERR_OF[$ime]="$err"
    LINES_OF[$ime]=0
    PROGRESS_AT[$ime]=$(date +%s)
    log INFO "$ime attempt $pokusaj started (pid ${PID_OF[$ime]})"
}

# zaustavi jedan proces: SIGTERM, pa posle kill_grace sekundi SIGKILL ako je jos ziv
stop_pid(){
    local pid="$1" oznaka="$2" i
    kill -TERM "$pid" 2>/dev/null
    for (( i = 0; i < CONF[kill_grace] * 10; i++ )); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        [[ -n "$oznaka" ]] && log WARN "$oznaka still alive after ${CONF[kill_grace]}s, sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null
    fi
    wait "$pid" 2>/dev/null
}

# zaustavi sve delove koji rade i vrati ih na cekanje
stop_running(){
    local ime
    for ime in "${!PID_OF[@]}"; do
        stop_pid "${PID_OF[$ime]}"
        rm -f "$RUN_DIR/chunks/$ime.${TRIES[$ime]}.out.tmp"
        STATE[$ime]=pending
        manifest_set "$ime" pending "${TRIES[$ime]}" "" "" interrupted
        unset "PID_OF[$ime]" "START_OF[$ime]" "ATTEMPT_OF[$ime]" "ERR_OF[$ime]" "LINES_OF[$ime]" "PROGRESS_AT[$ime]"
    done
}

# proveri da li se neki deo zaglavio (nema novih linija u .err)
check_hangs(){
    local ime pid n sada
    sada=$(date +%s)

    for ime in "${!PID_OF[@]}"; do
        pid="${PID_OF[$ime]}"
        kill -0 "$pid" 2>/dev/null || continue      # zavrsio je, to obradjuje nadzornik

        n=$(wc -l < "${ERR_OF[$ime]}")
        if (( n != LINES_OF[$ime] )); then
            # ima napretka: zapamti novi broj linija i vreme
            LINES_OF[$ime]=$n
            PROGRESS_AT[$ime]=$sada
        elif (( sada - PROGRESS_AT[$ime] >= CONF[hang_timeout] )); then
            # nema napretka hang_timeout sekundi: zaglavio se
            log WARN "$ime attempt ${TRIES[$ime]} hang detected (no progress for ${CONF[hang_timeout]}s), sending SIGTERM"
            HUNG[$ime]=1
            stop_pid "$pid" "$ime"
            finish_chunk "$ime" "$?"
        fi
    done
}

finish_chunk(){
    local ime="$1" kod="$2"
    local pokusaj="${TRIES[$ime]}"
    local ulaz="$RUN_DIR/chunks/$ime.csv"
    local izlaz_tmp="$RUN_DIR/chunks/$ime.$pokusaj.out.tmp"
    local trajanje razlog cekanje

    trajanje=$(awk -v a="${START_OF[$ime]}" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }')
    unset "PID_OF[$ime]" "START_OF[$ime]" "ATTEMPT_OF[$ime]" "ERR_OF[$ime]" "LINES_OF[$ime]" "PROGRESS_AT[$ime]"
    
    if (( kod == 0 )) && validate_output "$izlaz_tmp" "$ulaz"; then
        mv "$izlaz_tmp" "$RUN_DIR/results/$ime.out"
        STATE[$ime]=done
        log INFO "$ime attempt $pokusaj done (${trajanje}s)"
        manifest_set "$ime" done "$pokusaj" "$trajanje" 0 "${LAST_REASON[$ime]}"
        return
    fi

    rm -f "$izlaz_tmp"
    if [[ -n "${HUNG[$ime]}" ]]; then
        razlog=hang
        unset "HUNG[$ime]"
    elif (( kod == 0 )); then
        razlog=corrupt
    else
        razlog=$(classify_exit "$kod")
        if [[ "$razlog" == unknown ]]; then
            log WARN "$ime attempt $pokusaj: unknown exit code $kod"
            razlog=error
        fi
    fi
    LAST_REASON[$ime]="$razlog"

    if [[ "$razlog" == usage_error ]] || (( pokusaj >= 1 + CONF[max_retries] )); then
        STATE[$ime]=failed
        log WARN "$ime attempt $pokusaj failed (exit=$kod, reason=$razlog), no more retries"
        manifest_set "$ime" failed "$pokusaj" "$trajanje" "$kod" "$razlog"
        return
    fi

    cekanje=$(backoff_for "$pokusaj")
    READY_AT[$ime]=$(( $(date +%s) + cekanje ))
    STATE[$ime]=pending
    log WARN "$ime attempt $pokusaj failed (exit=$kod, reason=$razlog), retry in ${cekanje}s"
    manifest_set "$ime" pending "$pokusaj" "$trajanje" "$kod" "$razlog"
}


process_chunks(){
    local f ime pid kod sada


    while has_work; do
        sada=$(date +%s)

        for ime in "${CHUNKS[@]}"; do
            (( ${#PID_OF[@]} < CONF[workers] )) || break
            if [[ "${STATE[$ime]}" == pending ]] && (( READY_AT[$ime] <= sada )); then
                (( TRIES[$ime]++ ))
                STATE[$ime]=running
                start_chunk "$ime" "${TRIES[$ime]}"
            fi
        done

        check_hangs

        for ime in "${!PID_OF[@]}"; do
            pid="${PID_OF[$ime]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null
                kod=$?
                finish_chunk "$ime" "$kod"
            fi
        done
        
        if (( $(count_state failed) > CONF[max_failed_chunks] )); then
            log ERROR "Too many failed chunks ($(count_state failed) > ${CONF[max_failed_chunks]}), aborting"
            stop_running
            ABORTED=1
            return
        fi

        sleep 0.2
    done
}

# početno stanje za novo pokretanje: svi delovi čekaju
init_state_new(){
    local f ime
    for f in "$RUN_DIR"/chunks/chunk_*.csv; do
        ime="${f##*/}"
        ime="${ime%.csv}"
        CHUNKS+=( "$ime" )
        STATE[$ime]=pending
        TRIES[$ime]=0
        READY_AT[$ime]=0
    done
}

# pocetno stanje za resume: procitaj manifest i popravi ga
init_state_resume(){
    local ime status pokusaji ostalo
    local n_done=0 n_pending=0 n_failed=0

    while IFS=, read -r ime status pokusaji ostalo; do
        [[ "$ime" == chunk ]] && continue          # preskoci zaglavlje
        CHUNKS+=( "$ime" )
        TRIES[$ime]=$pokusaji
        READY_AT[$ime]=0
        LAST_REASON[$ime]="${ostalo##*,}"
        
        case "$status" in
            done)
                if validate_output "$RUN_DIR/results/$ime.out" "$RUN_DIR/chunks/$ime.csv"; then
                    STATE[$ime]=done
                else
                    log WARN "$ime: result missing or invalid, back to pending"
                    STATE[$ime]=pending
                    manifest_set "$ime" pending "$pokusaji" "" "" ""
                fi
                ;;
            running)
                STATE[$ime]=pending
                manifest_set "$ime" pending "$pokusaji" "" "" interrupted
                ;;
            failed)
                STATE[$ime]=failed
                ;;
            *)
                STATE[$ime]=pending
                ;;
        esac
    done < "$MANIFEST"

    n_done=$(count_state done)
    n_pending=$(count_state pending)
    n_failed=$(count_state failed)
    log INFO "Resuming $RUN_ID: $n_done done, $n_pending pending, $n_failed failed"
    echo "Resuming $RUN_ID: $n_done done, $n_pending pending"
}

has_work(){
    local ime
    for ime in "${CHUNKS[@]}"; do
        [[ "${STATE[$ime]}" == pending || "${STATE[$ime]}" == running ]] && return 0
    done
    return 1
}

merge_results(){
    local f ime cilj
    local zaglavlje="group,count,sum_amount,avg_amount,min_amount,max_amount,sum_quantity"
    local rezultati=( "$RUN_DIR"/results/*.out )
    local delovi=( "$RUN_DIR"/chunks/chunk_*.csv ) 

    #gotovi delovi: result.csv inace result.partial.csv
    if (( ${#rezultati[@]} == ${#delovi[@]} )); then
        cilj="$RUN_DIR/result.csv"
    else
        cilj="$RUN_DIR/result.partial.csv"
    fi

    # jos jedna provera
    for f in "${rezultati[@]}"; do
        ime="${f##*/}"
        ime="${ime%.out}"
        validate_output "$f" "$RUN_DIR/chunks/$ime.csv" || die "rezultat nije ispravan: $ime"
    done

    # nema nijednog rezultata → samo zaglavlje, bez awk
    if (( ${#rezultati[@]} == 0 )); then
        echo "$zaglavlje" > "$cilj.tmp" && mv "$cilj.tmp" "$cilj"
        log WARN "No successful results, ${cilj##*/} contains only header"
        return
    fi

    # 3) spoji, sortiraj i upiši u privremeni fajl
    {
        echo "$zaglavlje"
        awk -F, '
            FNR == 1 || /^#END/ { next }
            {
                g = $1
                cnt[g] += $2
                sum[g] += $3
                qty[g] += $6
                if (!(g in mn) || $4 + 0 < mn[g]) mn[g] = $4 + 0
                if (!(g in mx) || $5 + 0 > mx[g] ) mx[g] = $5 + 0
            }
            END {
                for (g in cnt)
                    printf "%s,%d,%.2f,%.2f,%.2f,%.2f,%d\n", g, cnt[g], sum[g], sum[g] / cnt[g], mn[g], mx[g], qty[g]
            }
        ' "${rezultati[@]}" | LC_ALL=C sort -t, -k1,1
    } > "$cilj.tmp" || die "spajanje rezultata nije uspelo"

     #premesti na konacno mesto
    mv "$cilj.tmp" "$cilj"
    log INFO "Merged ${#rezultati[@]} results into ${cilj##*/}"

}

finish_run(){
    local status="$1" kod="$2" poruka="$3"
    local trajanje=$(( $(date +%s) - RUN_START ))

    meta_set finished "$(date '+%Y-%m-%d %H:%M:%S')"
    meta_set status "$status"
    log INFO "Run finished: status=$status, duration=${trajanje}s"
    echo "Run finished: $status ($poruka)"
    exit "$kod"
}

# Ctrl+C ili SIGTERM: zaustavi sve, vrati running u pending, status interrupted
on_signal(){
    trap '' INT TERM      # ignorisi nove signale dok cistimo vise Ctrl + C
    echo "Interrupted, stopping ${#PID_OF[@]} running chunks..." >&2
    log WARN "Interrupted by signal, stopping ${#PID_OF[@]} running chunks"
    stop_running
    finish_run interrupted 130 "interrupted"
}

# nadzornik, spajanje i kraj: zajedničko za run i resume
run_to_end(){
    process_chunks

    if (( ABORTED )); then
        finish_run aborted 4 "too many failed chunks"
    fi

    merge_results

    if (( $(count_state failed) == 0 )); then
        [[ "${CONF[keep_chunks]}" == no ]] && rm -rf "$RUN_DIR/chunks"
        finish_run completed 0 "result: $RUN_DIR/result.csv"
    else
        finish_run partial 1 "result: $RUN_DIR/result.partial.csv"
    fi
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
    lock_run
    RUN_START=$(date +%s)
    trap on_signal INT TERM
    write_snapshot
    write_meta
    log INFO "Run $RUN_ID started (input=$cli_input, workers=${CONF[workers]})"
    for w in "${CONFIG_WARNINGS[@]}"; do
        log WARN "$w"
    done
    split_input "$cli_input"
    manifest_init
    init_state_new
    run_to_end
    

}

cmd_resume(){
    local run_id="$1"
    [[ -n "$run_id" ]] || die "resume zahteva run_id"

    # konfig iz snapshota tog pokretanja
    set_defaults
    [[ -f "./runs/$run_id/config.snapshot" ]] || die "pokretanje ne postoji: $run_id"
    load_config "./runs/$run_id/config.snapshot"
    validate_config

    RUN_ID="$run_id"
    RUN_DIR="${CONF[work_dir]}/$RUN_ID"
    LOG_FILE="$RUN_DIR/pipeline.log"
    MANIFEST="$RUN_DIR/manifest.csv"
    [[ -d "$RUN_DIR/chunks" ]] || die "delovi ne postoje, nastavak nije moguc: $RUN_ID"

    lock_run
    RUN_START=$(date +%s)
    trap on_signal INT TERM
    meta_set status running
    log INFO "Run $RUN_ID resumed"

    init_state_resume
    run_to_end
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
