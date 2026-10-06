#!/usr/bin/env bash
# =============================================================================
# pg_bench_20idx.sh - Do TPS thuc te cua PostgreSQL voi 1 bang 20 index
#
# Workload: INSERT + UPDATE ngau nhien chay dong thoi (pgbench custom script)
#   40%  insert         : them 1 dong moi (cap nhat ca 20 index)
#   40%  update_indexed : sua cot co index  (non-HOT, phai cap nhat index)
#   20%  update_hot     : sua cot khong co index (HOT, khong dung toi index)
#
# Cach dung:
#   export PGHOST=... PGPORT=5432 PGUSER=... PGPASSWORD=... PGDATABASE=...
#   ./pg_bench_20idx.sh init     # tao bang + nap du lieu + tao 20 index
#   ./pg_bench_20idx.sh run      # chay benchmark, in bang TPS
#   ./pg_bench_20idx.sh clean    # xoa bang test
#   ./pg_bench_20idx.sh all      # init + run (khong xoa)
#
# Tham so (bien moi truong):
#   ROWS=2000000        so dong nap ban dau
#   DURATION=120        so giay moi lan chay
#   CLIENTS="1 16 64"   cac muc so ket noi dong thoi, chay lan luot
#   W_INSERT=40 W_UPDATE_IDX=40 W_UPDATE_HOT=20   ty le workload
#   OUTDIR=./pgbench-results
#
# Yeu cau: psql va pgbench (goi postgresql-client / postgresql-contrib).
# Luu y: bai test tao tai ghi nang. Khong chay tren database dang phuc vu
#        production trong gio cao diem.
# =============================================================================
set -euo pipefail

ROWS="${ROWS:-2000000}"
DURATION="${DURATION:-120}"
CLIENTS="${CLIENTS:-1 16 64}"
W_INSERT="${W_INSERT:-40}"
W_UPDATE_IDX="${W_UPDATE_IDX:-40}"
W_UPDATE_HOT="${W_UPDATE_HOT:-20}"
OUTDIR="${OUTDIR:-./pgbench-results}"
TABLE="bench_orders_20idx"

PSQL=(psql -X -v ON_ERROR_STOP=1 -q)

need() { command -v "$1" >/dev/null 2>&1 || { echo "Thieu lenh: $1" >&2; exit 1; }; }
log()  { echo "[$(date +%H:%M:%S)] $*"; }

# -----------------------------------------------------------------------------
do_init() {
  need psql
  log "Tao bang ${TABLE} va nap ${ROWS} dong..."
  "${PSQL[@]}" -v rows="${ROWS}" <<'SQL'
DROP TABLE IF EXISTS bench_orders_20idx;

CREATE TABLE bench_orders_20idx (
    id           bigserial PRIMARY KEY,                -- index 1: btree (PK)
    user_id      bigint        NOT NULL,
    account_id   bigint        NOT NULL,
    order_no     text          NOT NULL,
    status       smallint      NOT NULL,
    side         smallint      NOT NULL,
    symbol       text          NOT NULL,
    price        numeric(20,8) NOT NULL,
    amount       numeric(20,8) NOT NULL,
    filled       numeric(20,8) NOT NULL DEFAULT 0,
    fee          numeric(20,8) NOT NULL DEFAULT 0,     -- khong co index
    version      integer       NOT NULL DEFAULT 0,     -- khong co index
    ref_code     text          NOT NULL,
    note         text          NOT NULL,
    tags         text[]        NOT NULL,
    meta         jsonb         NOT NULL,
    ip           inet          NOT NULL,
    client_uuid  uuid          NOT NULL,
    created_at   timestamptz   NOT NULL,
    updated_at   timestamptz   NOT NULL,
    expires_at   timestamptz   NOT NULL
) WITH (fillfactor = 85);

-- Nap du lieu truoc, tao index sau cho nhanh.
INSERT INTO bench_orders_20idx
    (user_id, account_id, order_no, status, side, symbol, price, amount,
     ref_code, note, tags, meta, ip, client_uuid,
     created_at, updated_at, expires_at)
SELECT
    (random() * 199999)::bigint + 1,
    (random() * 499999)::bigint + 1,
    'ORD-' || g,
    (random() * 3)::int,
    (random())::int,
    'SYM' || ((random() * 49)::int + 1),
    round((random() * 100000)::numeric, 8),
    round((random() * 10000)::numeric, 8),
    'RC' || upper(substr(md5(g::text), 1, 10)),
    'note ' || md5((g * 7)::text),
    ARRAY['t' || (g % 20), 't' || ((g / 20) % 20)],
    jsonb_build_object('src', g % 5, 'k', g % 1000, 'u', g % 200000),
    '0.0.0.0'::inet + (random() * 2147483647)::bigint,
    md5(g::text || 'u')::uuid,
    now() - ((:rows - g) * interval '1 second'),
    now() - (random() * interval '30 days'),
    now() + (random() * interval '30 days')
FROM generate_series(1, :rows) AS g;

-- ---- 19 index con lai (cong PK = 20) ---------------------------------------
-- btree thuong
CREATE UNIQUE INDEX b20_order_no_uq    ON bench_orders_20idx (order_no);                          -- 2
CREATE INDEX b20_user_id               ON bench_orders_20idx (user_id);                           -- 3
CREATE INDEX b20_updated_at            ON bench_orders_20idx (updated_at);                        -- 4
CREATE INDEX b20_amount_desc           ON bench_orders_20idx (amount DESC NULLS LAST);            -- 5
-- btree nhieu cot
CREATE INDEX b20_user_created          ON bench_orders_20idx (user_id, created_at DESC);          -- 6
CREATE INDEX b20_symbol_status_created ON bench_orders_20idx (symbol, status, created_at);        -- 7
CREATE INDEX b20_symbol_price          ON bench_orders_20idx (symbol, price);                     -- 8
-- btree covering (INCLUDE)
CREATE INDEX b20_account_cover         ON bench_orders_20idx (account_id)
                                          INCLUDE (amount, filled, status);                       -- 9
-- partial index
CREATE INDEX b20_open_orders           ON bench_orders_20idx (user_id, symbol) WHERE status = 0;  -- 10
CREATE INDEX b20_expiring              ON bench_orders_20idx (expires_at) WHERE status IN (0, 1); -- 11
-- expression index
CREATE INDEX b20_ref_lower             ON bench_orders_20idx (lower(ref_code));                   -- 12
CREATE INDEX b20_created_day           ON bench_orders_20idx
                                          (((created_at AT TIME ZONE 'UTC')::date));              -- 13
-- hash
CREATE INDEX b20_client_uuid_hash      ON bench_orders_20idx USING hash (client_uuid);            -- 14
-- GIN
CREATE INDEX b20_meta_gin              ON bench_orders_20idx USING gin (meta jsonb_path_ops);     -- 15
CREATE INDEX b20_tags_gin              ON bench_orders_20idx USING gin (tags);                    -- 16
-- BRIN
CREATE INDEX b20_created_brin          ON bench_orders_20idx USING brin (created_at);             -- 17
-- GiST
CREATE INDEX b20_ip_gist               ON bench_orders_20idx USING gist (ip inet_ops);            -- 18
-- SP-GiST
CREATE INDEX b20_ref_spgist            ON bench_orders_20idx USING spgist (ref_code);             -- 19

-- 20: GIN trigram neu co pg_trgm, khong thi dung btree text_pattern_ops
DO $$
BEGIN
    BEGIN
        CREATE EXTENSION IF NOT EXISTS pg_trgm;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Khong tao duoc pg_trgm (%), dung btree text_pattern_ops cho cot note', SQLERRM;
    END;
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
        EXECUTE 'CREATE INDEX b20_note_trgm ON bench_orders_20idx USING gin (note gin_trgm_ops)';
    ELSE
        EXECUTE 'CREATE INDEX b20_note_pattern ON bench_orders_20idx (note text_pattern_ops)';
    END IF;
END $$;

VACUUM ANALYZE bench_orders_20idx;
SQL
  log "Xong. Danh sach index:"
  show_size
}

# -----------------------------------------------------------------------------
show_size() {
  psql -X -c "
    SELECT count(*)                                          AS so_index,
           pg_size_pretty(pg_table_size('${TABLE}'))         AS bang,
           pg_size_pretty(pg_indexes_size('${TABLE}'))       AS tong_index,
           pg_size_pretty(pg_total_relation_size('${TABLE}')) AS tong
    FROM pg_indexes WHERE tablename = '${TABLE}';"
}

show_settings() {
  psql -X -c "
    SELECT name, setting, unit FROM pg_settings
    WHERE name IN ('server_version','shared_buffers','synchronous_commit','fsync',
                   'full_page_writes','wal_level','wal_compression','max_wal_size',
                   'checkpoint_timeout','synchronous_standby_names','max_connections')
    ORDER BY name;"
}

write_scripts() {
  local d="$1"

  cat > "${d}/insert.sql" <<'SQL'
\set uid   random(1, 200000)
\set acc   random(1, 500000)
\set sym   random(1, 50)
\set st    random(0, 3)
\set side  random(0, 1)
\set price random(1, 10000000)
\set amt   random(1, 1000000)
\set ipn   random(0, 2147483647)
INSERT INTO bench_orders_20idx
    (user_id, account_id, order_no, status, side, symbol, price, amount,
     ref_code, note, tags, meta, ip, client_uuid,
     created_at, updated_at, expires_at)
VALUES
    (:uid, :acc,
     'ORD-' || md5(random()::text || clock_timestamp()::text),
     :st, :side, 'SYM' || :sym, :price / 100.0, :amt / 100.0,
     'RC' || upper(substr(md5(random()::text), 1, 10)),
     'note ' || md5(random()::text),
     ARRAY['t' || (:uid % 20), 't' || (:acc % 20)],
     jsonb_build_object('src', :side, 'k', :amt % 1000, 'u', :uid),
     '0.0.0.0'::inet + :ipn,
     md5(random()::text || clock_timestamp()::text)::uuid,
     now(), now(), now() + interval '7 days');
SQL

  cat > "${d}/update_indexed.sql" <<'SQL'
\set id random(1, :maxid)
\set st random(0, 3)
\set f  random(0, 1000000)
UPDATE bench_orders_20idx
   SET status     = :st,
       filled     = :f / 100.0,
       updated_at = now(),
       meta       = meta || jsonb_build_object('k', :f % 1000)
 WHERE id = :id;
SQL

  cat > "${d}/update_hot.sql" <<'SQL'
\set id random(1, :maxid)
\set f  random(0, 1000000)
UPDATE bench_orders_20idx
   SET fee     = :f / 1000.0,
       version = version + 1
 WHERE id = :id;
SQL
}

# -----------------------------------------------------------------------------
do_run() {
  need psql; need pgbench
  mkdir -p "${OUTDIR}"
  local work; work="$(mktemp -d)"
  trap 'rm -rf "${work}"' RETURN
  write_scripts "${work}"

  local maxid
  maxid="$(psql -X -At -c "SELECT max(id) FROM ${TABLE}")"
  [ -n "${maxid}" ] || { echo "Bang ${TABLE} chua co du lieu. Chay 'init' truoc." >&2; exit 1; }

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local summary="${OUTDIR}/summary-${stamp}.txt"
  local ncpu; ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

  {
    echo "=== pg_bench_20idx ${stamp} ==="
    echo "Host: ${PGHOST:-local}  DB: ${PGDATABASE:-}  Rows ban dau: ${maxid}"
    echo "Workload: insert ${W_INSERT}% / update_indexed ${W_UPDATE_IDX}% / update_hot ${W_UPDATE_HOT}%"
    echo "Moi lan chay: ${DURATION}s"
    echo
    show_settings
    show_size
  } | tee "${summary}"

  printf '\n%-8s %12s %14s %14s %12s\n' "clients" "TPS" "lat_avg(ms)" "lat_stddev" "WAL(MB/s)" | tee -a "${summary}"

  local c
  for c in ${CLIENTS}; do
    local threads=$(( c < ncpu ? c : ncpu ))
    local out="${OUTDIR}/run-${stamp}-c${c}.txt"

    psql -X -q -c "CHECKPOINT" 2>/dev/null || true   # can quyen; bo qua neu khong co
    local lsn0; lsn0="$(psql -X -At -c "SELECT pg_current_wal_lsn()")"

    log "Chay ${c} client trong ${DURATION}s..." >&2
    pgbench -n \
      -f "${work}/insert.sql@${W_INSERT}" \
      -f "${work}/update_indexed.sql@${W_UPDATE_IDX}" \
      -f "${work}/update_hot.sql@${W_UPDATE_HOT}" \
      -D maxid="${maxid}" \
      -c "${c}" -j "${threads}" -T "${DURATION}" -P 10 -r \
      > "${out}" 2>&1 || { echo "pgbench loi, xem ${out}" >&2; tail -20 "${out}" >&2; exit 1; }

    local wal_mb
    wal_mb="$(psql -X -At -c "SELECT round(pg_wal_lsn_diff(pg_current_wal_lsn(), '${lsn0}') / 1024.0 / 1024.0 / ${DURATION}, 2)")"

    local tps lat sd
    tps="$(awk '/^tps = /{print $3; exit}' "${out}")"
    lat="$(awk -F'= ' '/^latency average/{print $2; exit}' "${out}" | awk '{print $1}')"
    sd="$(awk -F'= ' '/^latency stddev/{print $2; exit}' "${out}" | awk '{print $1}')"
    printf '%-8s %12s %14s %14s %12s\n' "${c}" "${tps:-?}" "${lat:-?}" "${sd:-?}" "${wal_mb:-?}" | tee -a "${summary}"
  done

  {
    echo
    echo "Kich thuoc sau khi test:"
    show_size
  } | tee -a "${summary}"

  echo
  log "Tom tat: ${summary}"
  log "Chi tiet tung lan chay (TPS moi 10s, latency tung loai lenh): ${OUTDIR}/run-${stamp}-c*.txt"
}

# -----------------------------------------------------------------------------
do_clean() {
  need psql
  psql -X -q -c "DROP TABLE IF EXISTS ${TABLE}"
  log "Da xoa bang ${TABLE}."
}

case "${1:-}" in
  init)  do_init ;;
  run)   do_run ;;
  clean) do_clean ;;
  all)   do_init; do_run ;;
  *)     sed -n '2,29p' "$0"; exit 1 ;;
esac
