# PostgreSQL benchmark trên EKS

## Cấu hình EBS

| Thuộc tính | Giá trị |
|---|---|
| Driver | `ebs.csi.aws.com` — EBS CSI add-on + IRSA đang có |
| StorageClass | `postgres-io2` |
| Loại | `io2` Block Express |
| Data | PVC `data-postgres-0`: **100 GiB / 32.000 IOPS** |
| WAL | PVC `wal-postgres-0`: **100 GiB / 32.000 IOPS**, volume riêng |
| Filesystem / encryption | ext4 / bật mã hóa bằng khóa EBS mặc định |
| Binding / reclaim | `WaitForFirstConsumer` / `Retain` |

AWS hiện cấp mọi volume io2 bằng Block Express; không cần parameter `blockExpress`.
io2 có trần 256.000 IOPS / 4.000 MiB/s trên Nitro, nhưng **32.000 IOPS trên mỗi ổ là cấu hình của manifest này**.
Muốn 256.000 IOPS cần ít nhất 256 GiB và node có đủ giới hạn EBS; không tự động đạt mức đó khi chọn io2.
Không đặt parameter `throughput` của gp3 vào StorageClass io2.

Nguồn: [AWS io2](https://docs.aws.amazon.com/ebs/latest/userguide/provisioned-iops.html),
[EBS CSI parameters](https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/master/docs/parameters.md),
[EKS EBS CSI](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html).

Chọn **node EC2 Nitro x86_64**, có ít nhất 32 vCPU và đủ RAM allocatable cho PG 48 GiB + fio 2 GiB + hệ thống.
Ví dụ `r6in.8xlarge`: 32 vCPU / 256 GiB, EBS baseline 100.000 IOPS và 3.125 MB/s.
Đây là gợi ý; Karpenter tự cấp node theo resource requests và NodePool hiện có. Manifest chỉ chọn Linux/amd64, không cần label `remi=debug`, không khóa hostname hoặc instance type.
Giới hạn EBS của instance dùng chung cho các volume gắn vào node, gồm cả root disk. Để khai thác đồng thời hai ổ 32.000 IOPS, cần node có EBS baseline ít nhất 64.000 IOPS cộng phần I/O của root disk/workload khác.
Karpenter không chọn IOPS EBS theo resource requests CPU/RAM; cần kiểm tra instance thực tế sau khi scale. Nếu cần bảo đảm loại node, giới hạn instance type trong NodePool theo bảng AWS.
[Thông số EC2](https://docs.aws.amazon.com/ec2/latest/instancetypes/mo.html).

## Nội dung psql.yaml

File `psql.yaml` đã nhúng toàn bộ script vào ConfigMap, chỉ chứa workload trong namespace có sẵn.
Namespace `postgres-benchmark`, StorageClass `postgres-io2` và Secret `postgres-auth` phải tồn tại trước.
StorageClass nằm riêng trong `ebs.yaml`; admin apply một lần nếu chưa có.
Không sửa file triển khai LPEX cũ.

- Dùng namespace `postgres-benchmark` có sẵn, một StatefulSet `postgres`, một replica.
- PostgreSQL 16: request/limit **24 CPU / 48 GiB**, cùng cấu hình LPEX: `shared_buffers=12GB`, `effective_cache_size=36GB`, `synchronous_commit=off`, `fsync=on` và `full_page_writes=on` mặc định PostgreSQL.
- Exporter sidecar trong cùng pod: 100m CPU / 256 MiB, metrics cổng 9187.
- Hai PVC io2 riêng, mỗi PVC 100 GiB / 32.000 IOPS: data `data-postgres-0` và WAL `wal-postgres-0`.
- PGDATA ở `/var/lib/postgresql/data/pgdata`; `POSTGRES_INITDB_WALDIR=/var/lib/postgresql/wal/pg_wal` tạo symlink `PGDATA/pg_wal` sang volume WAL riêng ngay lúc initdb.
- Hai CronJob `pgbench-off`, `pgbench-on`: pod client PostgreSQL 16 kết nối qua DNS Service, tạo 2 triệu dòng và 20 index, chạy lần lượt 1 / 16 / 64 clients, mỗi mức 120 giây, rồi xóa bảng test. Mỗi client request/limit 4 CPU / 2 GiB.
- CronJob `fio-ebs`: chỉ mount PVC data, cùng node với PostgreSQL; đo ổ data bằng file tạm ngoài PGDATA. RWO cho phép nhiều pod cùng node mount volume.
- Service nội bộ; không Ingress, certificate hoặc NetworkPolicy. Không thêm PgBouncer vào bài đo PG này.

Các image chính được khóa digest. CronJob SQL dùng PostgreSQL 16 client, không dùng kubectl, không gọi Kubernetes API và không mount ServiceAccount token.

## Quyền triển khai

Đã bỏ `Namespace`, `StorageClass`, `ServiceAccount`, `Role` và `RoleBinding` khỏi `psql.yaml`.
Các job SQL kết nối bằng user/password PostgreSQL qua Service DNS, nên không cần quyền `pods/exec` hay benchmark RBAC.
Namespace đã có vẫn dùng `metadata.namespace: postgres-benchmark` trên từng workload.

User deploy cần quyền quản lý ConfigMap, Service, StatefulSet, CronJob và Secret trong namespace; quyền chạy Job/xem pod/log dùng khi kích hoạt test.
Nếu `postgres-io2` chưa tồn tại thì admin cần apply `ebs.yaml`; bỏ StorageClass khỏi workload không tự tạo volume class hay cấp quyền cluster.

## Apply

Dùng context EKS và namespace `postgres-benchmark` Đại ca đã tạo. Admin apply StorageClass nếu chưa có:

```bash
kubectl apply -f ebs.yaml
```

Sau khi StorageClass đã có, user deploy chỉ cần Secret và `psql.yaml` ở namespace này.

Không cần gắn label thủ công. Karpenter provision node phù hợp 24 CPU / 48 GiB cho PG; mỗi pod benchmark SQL/fio cần thêm 4 CPU / 2 GiB và có affinity bắt buộc cùng hostname với PG để mount PVC data RWO.
NodePool cần cho phép Linux/amd64 và có limits đủ; nếu NodePool có taint riêng, bổ sung toleration tương ứng cho PG và các job benchmark.
StorageClass có `WaitForFirstConsumer`, vì vậy **hai volume sẽ được tạo cùng AZ** của node được chọn.
[Karpenter scheduling](https://karpenter.sh/docs/concepts/scheduling/).

Tạo password **một lần** trong namespace đã có; không dùng password database thật:

```bash
(
  set -eu
  umask 077
  secret_dir=$(mktemp -d)
  trap 'rm -rf "$secret_dir"' EXIT
  openssl rand -hex 24 > "$secret_dir/postgres-password"
  openssl rand -hex 24 > "$secret_dir/monitor-password"
  kubectl -n postgres-benchmark create secret generic postgres-auth \
    --from-file=postgres-password="$secret_dir/postgres-password" \
    --from-file=monitor-password="$secret_dir/monitor-password"
)
kubectl apply -f psql.yaml
kubectl -n postgres-benchmark rollout status statefulset/postgres --timeout=15m
kubectl -n postgres-benchmark get pod,pvc
```

Nếu Secret đã tồn tại thì giữ nguyên và apply YAML; không chạy lại phần tạo Secret.
PG chỉ đọc password khi init volume mới; thay Secret không tự đổi password của database đã có dữ liệu.
PVC và EBS đều `Retain`: xóa StatefulSet/namespace không tự xóa EBS; cần tự dọn volume để ngừng tính phí.
Hai ổ cộng lại **200 GiB và 64.000 provisioned IOPS** đều tính phí; mức tiền phụ thuộc region và thời gian giữ volume.

Bản hai PVC dành cho deploy mới. Nếu đã apply bản một PVC, không apply trực tiếp lên StatefulSet cũ: `volumeClaimTemplates` không sửa được tại chỗ và `POSTGRES_INITDB_WALDIR` chỉ có tác dụng khi initdb mới.
Giữ nguyên dữ liệu cũ; cần quy trình recreate StatefulSet và di chuyển WAL khi PostgreSQL đã dừng, hoặc deploy trong namespace mới. Không chỉ đổi env rồi coi WAL đã chuyển ổ.
[PostgreSQL WAL directory](https://www.postgresql.org/docs/16/wal-internals.html).

## Chạy từng bài và lấy kết quả

Ba CronJob mặc định **suspend=true**. Chạy thủ công để xem kết quả từng bài, rồi mới chuyển bài tiếp theo:

```bash
run_test() {
  local cron="$1" job="${1}-$(date +%s)"
  kubectl -n postgres-benchmark create job "$job" --from="cronjob/$cron" || return
  kubectl -n postgres-benchmark wait --for=condition=complete "job/$job" --timeout=65m || {
    kubectl -n postgres-benchmark logs "job/$job" --all-containers=true
    kubectl -n postgres-benchmark describe "job/$job"
    return 1
  }
  kubectl -n postgres-benchmark logs "job/$job" --all-containers=true
}
run_test pgbench-off
# Xem report rồi chạy dòng tiếp theo.
run_test pgbench-on
# Xem report rồi chạy fio.
run_test fio-ebs
```

Đo SQL từ pod client riêng qua **postgres.postgres-benchmark.svc.cluster.local:5432**; không exec vào pod PG.
Server giữ 24 CPU / 48 GiB; client dùng riêng 4 CPU / 2 GiB. Kết quả hiện tại có độ trễ mạng qua Service và không hoàn toàn tương đương bài localhost trước đó.
Có thể đổi env `PGHOST` trong hai CronJob sang địa chỉ IP nội bộ nếu cần; DNS Service ổn định khi pod PG được thay thế.
Mode chỉ áp dụng cho session benchmark qua `PGOPTIONS`; default server vẫn `off` sau mỗi bài.
Với một primary và không standby, `on` và `local` đều chờ WAL flush trên primary.
`wal_level=minimal`, `max_wal_senders=0` giống cấu hình LPEX: bộ này dành cho test một node.

Các job dùng chung `flock` trên PVC, nên SQL off/on và fio không chạy đồng thời dù tạo job cùng lúc.
`concurrencyPolicy=Forbid` riêng lẻ không đủ để khóa giữa ba CronJob.
Job chờ khóa tối đa 30 phút, deadline tổng 60 phút, không tự retry bài ghi dữ liệu.
Không xóa `.benchmark.lock` khi có tiến trình giữ khóa.
[CronJob concurrency](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/#concurrency-policy).

Muốn chạy hằng ngày, unsuspend từng CronJob:

```bash
kubectl -n postgres-benchmark patch cronjob pgbench-off -p '{"spec":{"suspend":false}}'
kubectl -n postgres-benchmark patch cronjob pgbench-on -p '{"spec":{"suspend":false}}'
kubectl -n postgres-benchmark patch cronjob fio-ebs -p '{"spec":{"suspend":false}}'
```

Lịch mặc định 00:00 / 01:00 / 02:00 theo `Asia/Ho_Chi_Minh`; khóa vẫn bảo vệ khi một bài chạy lâu.
Không tạo job lặp lại trước khi xem trạng thái bài trước.
Job/pod benchmark tự xóa sau 24 giờ kể từ khi kết thúc; report trên PVC vẫn giữ nguyên.

Kết quả lưu trên PVC trong `/var/lib/postgresql/data/benchmark-results/`; bảng TPS/latency cũng có trong log Job.
Lệnh copy report dưới đây là tùy chọn và cần user có quyền `pods/exec`; CronJob không dùng quyền này:

```bash
kubectl -n postgres-benchmark cp -c postgres \
  postgres-0:/var/lib/postgresql/data/benchmark-results ./eks-results
kubectl -n postgres-benchmark top pod postgres-0 --containers
```

Report SQL gồm TPS/latency/WAL MB/s, xác nhận commit mode, số dòng/20 index, log init/clean và `database.jsonl`.
`container-resources.log` ghi CPU tích lũy, RAM và I/O cgroup mỗi giây; database/WAL/wait events lấy mỗi 5 giây.
`memory.current` gồm cache; `memory.stat` giúp phân biệt anon/file. Cgroup v1 có bộ đếm CPU/RAM/blkio tương ứng.
CPU/RAM/I/O cgroup của report SQL đo **container client**, không phải server PG. Dùng `kubectl top pod postgres-0 --containers` (nếu có Metrics Server) hoặc giám sát node/pod để xem CPU/RAM server; exporter cung cấp số liệu database. WAL counters vẫn là toàn instance server.
Không coi I/O cgroup là số liệu riêng của EBS khi có nhiều thiết bị.
Exporter: `http://postgres-exporter.postgres-benchmark.svc.cluster.local:9187/metrics`.
DNS kết nối từ pod khác: `postgres.postgres-benchmark.svc.cluster.local:5432`, database/user `postgres`, password từ Secret `postgres-auth`.

## Bài fio

Chỉ đo ổ **data**; CronJob fio không mount PVC WAL.
Chạy tuần tự: pre-write 40 GiB → randread 4k → randwrite 4k → randread 8k → randwrite 8k → fdatasync → mixed.
Pre-write ghi đủ mọi block để random read không đo các extent chưa ghi.
Bốn bài random dùng libaio/direct, 4 jobs × 10 GiB, iodepth 32, mỗi bài 60s.
Fsync dùng sync/write, 8k, 2 GiB, fdatasync mỗi block, 60s.
Mixed dùng 8k, 70% read / 30% write, 4 jobs, iodepth 32, 300s.
Các file riêng nằm trong `.fio-*` ở gốc PVC data, tự xóa khi bài kết thúc; giữ JSON kết quả gồm IOPS, bandwidth và latency percentiles trong thư mục report `data/` trên PVC data.
Cần tối thiểu 52 GiB trống **trên ổ data** trước khi chạy; nếu data làm đầy PVC, tăng dung lượng trước.
Không ghi block device và không đụng file PostgreSQL. Khi pod bị kill cứng, kiểm tra và dọn **đúng thư mục `.fio-*` của bài đã chết** trước khi chạy lại.
PG vẫn bật nhưng không chạy benchmark SQL cùng lúc; checkpoint/autovacuum hoặc workload ngoài bộ test vẫn có thể ảnh hưởng I/O.
Để so sánh, dùng node riêng và dừng các client khác.

Có thể đổi `FIO_SIZE`, `FIO_FSYNC_SIZE`, `FIO_RUNTIME`, `FIO_MIXED_RUNTIME`, `FIO_MIN_FREE_BYTES` trong env của fio khi smoke-test; mặc định giữ bài Đại ca yêu cầu.
Script nằm trong `scripts/`, bản thực thi đã nhúng vào YAML. Nếu sửa script nguồn, cần cập nhật ConfigMap tương ứng trong `psql.yaml`.

## Kiểm tra trước bàn giao

Đã kiểm tra schema Kubernetes 1.34 bằng kubeconform strict: toàn bộ 9 object trong `psql.yaml` hợp lệ.
Đã smoke-test pod client PostgreSQL 16 riêng qua DNS Docker nội bộ, UID 999, drop capabilities: off/on với 200 dòng, đủ 20 index, một client / một giây; default server vẫn off và cleanup thành công. Client không gọi Kubernetes API hay mount volume WAL.
Đã kiểm tra WAL symlink sang volume riêng và khóa giữa hai container cùng volume data. Bản fio hiện tại chỉ mount ổ data; đã smoke-test bảy report fio, monitor CPU/RAM/I/O và xóa scratch mà không cần volume WAL.
Smoke fio dùng file nhỏ, một giây và giả lập amd64 trên máy local; **không dùng các số đó làm kết quả hiệu năng EBS**.
Chưa apply lên EKS, nên việc provision volume, IAM thực tế, AZ, capacity của node và admission policy cần được xác nhận khi Đại ca apply.
