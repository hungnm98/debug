# PostgreSQL: benchmark 2 triệu dòng, 20 index

Script `pg_bench_20idx.sh` giữ nguyên bản dùng để benchmark. Workload gồm 40% INSERT, 40% UPDATE cột có index và 20% UPDATE cột không có index. Mặc định nạp 2.000.000 dòng, chạy lần lượt 1 → 16 → 64 client, mỗi mức 120 giây.

`run_commit_modes.sh` chạy từng commit mode **tuần tự**, khởi tạo lại bảng cho mỗi mode và xóa bảng sau test. `PGOPTIONS` đặt mode cho từng kết nối psql/pgbench; không thay đổi default server, database hoặc role.

## Các commit mode

| Mode | Commit chờ gì? |
|---|---|
| `off` | Không chờ flush WAL bền vững trước khi trả thành công. |
| `local` | Chờ flush WAL bền vững trên **primary**, không đợi standby xác nhận. |
| `on` | Chờ flush WAL trên primary; nếu có synchronous standby, chờ thêm xác nhận flush WAL của standby. |
| `remote_write` | Chờ primary flush WAL và standby ghi WAL vào filesystem; chưa yêu cầu standby flush xuống storage. |
| `remote_apply` | Chờ primary flush WAL và standby flush/replay transaction. |

`local` là **chế độ commit**, độc lập với nơi chạy client. Ví dụ `PGHOST=db.example.internal` + `synchronous_commit=local` vẫn benchmark DB remote. Pod chạy pgbench chỉ là client; dữ liệu nằm trên DB được PGHOST/PGPORT chỉ định. `local` không tắt replication và không bảo đảm standby đã nhận transaction khi failover.

Nếu `synchronous_standby_names` rỗng, các mode khác `off` đều chỉ chờ WAL local, nên `local` và `on` không có khác biệt về mức đồng bộ. [Tài liệu PostgreSQL](https://www.postgresql.org/docs/17/runtime-config-wal.html#GUC-SYNCHRONOUS-COMMIT).

## Chuẩn bị kết nối

Cần Bash, `psql`, `pgbench` trong PATH. Các bài trước dùng client PostgreSQL 16 với server PostgreSQL 16 / EDB 17. Kiểm tra:

```bash
psql --version
pgbench --version

git clone git@github.com:hungnm98/debug.git
cd debug/postgres-benchmark
cp .env.example .env
cp .pgpass.example .pgpass
chmod 600 .env .pgpass
mkdir -p certs
```

Sửa `.env` và `.pgpass` trên máy chạy test. Host/port/database/user trong `.pgpass` phải khớp `.env`. Copy CA được cấp cho DB vào `certs/psql-ca.crt`. Không ghi password vào lệnh shell, script hoặc commit; `.env`, `.pgpass`, cert và kết quả test đã được gitignore.

Dòng `.pgpass` có dạng `host:port:database:user:password`; escape ký tự `:` và `\` trong các trường bằng `\`. Dấu `$` trong file này không cần escape vì đây không phải shell script. [Tài liệu password file](https://www.postgresql.org/docs/17/libpq-pgpass.html).

```bash
source .env
psql -X -c '\conninfo'
psql -X -c 'SELECT current_database(), current_user, inet_server_addr(), inet_server_port(), pg_is_in_recovery();'
psql -X -c 'SHOW synchronous_standby_names;'
```

Mẫu dùng `sslmode=require` và CA. Khi chứng chỉ khớp hostname, có thể đặt `PGSSLMODE=verify-full` để kiểm tra cả hostname. Nếu test server local không bật TLS, đặt `PGSSLMODE=disable` và bỏ `PGSSLROOTCERT`.

Dùng database dành riêng cho benchmark. Script gốc `init` có `DROP TABLE IF EXISTS bench_orders_20idx`; wrapper sẽ từ chối nếu bảng này đã tồn tại. Không chạy nhiều bản benchmark đồng thời trên cùng DB/disk. Bài ghi nặng, cần đủ dung lượng cho table/index tăng và WAL phát sinh.

## Quyền cần có

User cần CONNECT vào database, USAGE/CREATE trên schema `public`. Các thao tác INSERT/SELECT/UPDATE/DELETE/DROP trên bảng user tự tạo dùng quyền owner.

Cần `pg_trgm` để có GIN trigram ở index thứ 20. Cài extension trước bằng tài khoản được phép, hoặc user benchmark phải được phép CREATE EXTENSION. Wrapper kiểm tra đúng số dòng, đủ 20 index và GIN trigram; nếu script gốc fallback sang B-tree, wrapper sẽ dừng. Nếu extension đã có trước test thì giữ nguyên; nếu wrapper tạo mới và user sở hữu, wrapper xóa extension cuối test, không dùng CASCADE.

CHECKPOINT không bắt buộc: script gốc thử trước mỗi mức client và bỏ qua khi không có quyền. Ghi nhận khác biệt này khi so sánh với bài chạy bằng admin.

## Chạy một hoặc nhiều mode

```bash
source .env

# Một lượt local: init → 1/16/64 client → clean
./run_commit_modes.sh local

# Ba lượt, mỗi lượt init mới, chạy tuần tự
./run_commit_modes.sh off local on

# Không truyền tham số cũng mặc định off → local → on
./run_commit_modes.sh

# Hai mode bổ sung nếu muốn kiểm tra mức chờ standby khác
./run_commit_modes.sh remote_write remote_apply
```

Mặc định mỗi mode cần 6 phút đo TPS cộng thời gian init/index/clean. Kết quả được lưu vào thư mục riêng `pgbench-results/<UTC timestamp>-<random suffix>/<mode>/`, gồm:

- `synchronous-commit.txt`: mode được SHOW từ phiên test.
- `initial-count.json`: số dòng, số index, GIN trigram.
- `init.log`, `run.log`, `clean.log`, `cleanup-verified.txt`.
- `summary-*.txt`: bảng TPS/latency/WAL.
- `run-*-c*.txt`: chi tiết pgbench cho từng mức client.

Có thể đổi cấu hình bằng biến môi trường:

```bash
# Smoke test nhỏ; kết quả không dùng đánh giá hiệu năng
ROWS=200 DURATION=1 CLIENTS="1" ./run_commit_modes.sh off local on

# Bài đầy đủ
ROWS=2000000 DURATION=120 CLIENTS="1 16 64" ./run_commit_modes.sh local
```

## Chạy trực tiếp script gốc

Nếu muốn tự quản lý init/run/clean, luôn đặt cùng mode cho cả ba bước:

```bash
source .env
export PGOPTIONS='-c search_path=public -c synchronous_commit=local'
./pg_bench_20idx.sh init
./pg_bench_20idx.sh run
./pg_bench_20idx.sh clean
unset PGOPTIONS
```

Các lệnh trực tiếp này không có guard/cleanup tự động của wrapper. Script gốc giữ lại extension pg_trgm sau clean.

## Chạy pgbench trong pod Kubernetes

Pod cần có Bash, psql, pgbench và tar. Chuẩn bị `.env`, `.pgpass` và CA như trên; PGHOST phải là địa chỉ DB cần benchmark. Copy folder này vào pod client được phép sử dụng credential:

```bash
# Chạy từ thư mục debug (parent của postgres-benchmark)
NS=debugger
POD=postgres-0
CONTAINER=postgres
kubectl cp ./postgres-benchmark "$NS/$POD:/tmp/postgres-benchmark" -c "$CONTAINER"
kubectl exec -n "$NS" "$POD" -c "$CONTAINER" -- bash -c \
  'cd /tmp/postgres-benchmark && chmod 600 .env .pgpass && source .env && ./run_commit_modes.sh local'
```

Với DB remote, dữ liệu và WAL vẫn nằm trên DB remote, không nằm trên PVC của pod client. Để loại bỏ mạng giữa client/server, chạy pgbench ngay trên máy/container của **DB đích** và dùng localhost hoặc Unix socket.

Tải kết quả và xóa file tạm trong pod sau khi test/monitor kết thúc:

```bash
kubectl cp "$NS/$POD:/tmp/postgres-benchmark/pgbench-results" ./results-from-pod -c "$CONTAINER"
kubectl exec -n "$NS" "$POD" -c "$CONTAINER" -- rm -rf /tmp/postgres-benchmark
```

## Monitor và đọc kết quả

Mở terminal thứ hai trên cùng máy/pod client, dùng cùng cấu hình kết nối:

```bash
cd postgres-benchmark
source .env
./monitor_db.sh > db-monitor.jsonl
# Ctrl+C sau khi benchmark xong
```

Mặc định lấy mẫu mỗi 5 giây: pg_stat_database, pg_stat_wal, wait event của các phiên pgbench thuộc user hiện tại. Cần PostgreSQL 14+ cho pg_stat_wal. `INTERVAL=10 ./monitor_db.sh` thay đổi chu kỳ. Nếu view không khả dụng/quyền không đủ, monitor báo lỗi; benchmark không phụ thuộc monitor.

- `IPC / SyncRep`: chờ xác nhận replication. Khi so sánh on/local, xem phần chờ này có biến mất hay không.
- `IO / WalSync` và `LWLock / WALWrite`: chờ liên quan WAL local.
- `LWLock / BufferContent`: chờ truy cập data page trong bộ nhớ.

Đây là mẫu quan sát, không phải thời gian chờ cộng dồn. WAL là toàn cluster, có thể gồm database khác. Counter `blks_read` không phải I/O vật lý ở storage; timing WAL/I/O chỉ có ý nghĩa khi server bật track_wal_io_timing/track_io_timing. [Tài liệu PostgreSQL về monitoring](https://www.postgresql.org/docs/17/monitoring-stats.html).

`kubectl top pod` của pod pgbench đo **client** nếu PGHOST trỏ DB remote. Muốn CPU/RAM/I/O server cần exporter, metrics hoặc công cụ OS trên chính máy DB đích.

TPS/latency là số pgbench báo. Tham số `-T 120` có thể kéo dài do chờ giao dịch cuối; script chia WAL delta cố định 120s và dùng MiB/s dù nhãn MB/s. Không có p95/p99 vì không log latency từng transaction. UPDATE cột không có index không đảm bảo mọi UPDATE đó là HOT.

Mỗi mode init mới cùng số dòng/schema/index nhưng dữ liệu random không giống byte-for-byte. Cache, checkpoint, autovacuum và workload bên ngoài vẫn thay đổi; không quy riêng chênh lệch TPS cho disk hay replication nếu chưa kiểm soát các điều kiện này.
