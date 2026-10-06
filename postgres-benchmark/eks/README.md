# PostgreSQL benchmark trên EKS

## Cấu hình EBS

| Thuộc tính | Giá trị |
|---|---|
| Driver | `ebs.csi.aws.com` — EBS CSI add-on + IRSA đang có |
| StorageClass | `postgres-io2` |
| Loại | `io2` Block Express |
| Dung lượng | 100 GiB |
| Provisioned IOPS | 32.000 |
| Filesystem / encryption | ext4 / bật mã hóa bằng khóa EBS mặc định |
| Binding / reclaim | `WaitForFirstConsumer` / `Retain` |

AWS hiện cấp mọi volume io2 bằng Block Express; không cần parameter `blockExpress`.
io2 có trần 256.000 IOPS / 4.000 MiB/s trên Nitro, nhưng **32.000 IOPS là cấu hình của manifest này**.
Muốn 256.000 IOPS cần ít nhất 256 GiB và node có đủ giới hạn EBS; không tự động đạt mức đó khi chọn io2.
Không đặt parameter `throughput` của gp3 vào StorageClass io2.

Nguồn: [AWS io2](https://docs.aws.amazon.com/ebs/latest/userguide/provisioned-iops.html),
[EBS CSI parameters](https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/master/docs/parameters.md),
[EKS EBS CSI](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html).

Chọn **node EC2 Nitro x86_64**, có ít nhất 32 vCPU và đủ RAM allocatable cho PG 48 GiB + fio 2 GiB + hệ thống.
Ví dụ `r6in.8xlarge`: 32 vCPU / 256 GiB, EBS baseline 100.000 IOPS và 3.125 MB/s.
Đây là gợi ý; manifest không tạo node hay khóa instance type. Đại ca chưa cung cấp loại node thực tế.
Giới hạn EBS của instance dùng chung cho các volume gắn vào node, gồm cả root disk.
[Thông số EC2](https://docs.aws.amazon.com/ec2/latest/instancetypes/mo.html).

## Nội dung psql.yaml

File độc lập, đã nhúng toàn bộ script vào ConfigMap; chỉ cần copy `psql.yaml` và tạo Secret.
`ebs.yaml` là bản riêng của cùng StorageClass để xem hoặc apply trước; không bắt buộc apply cả hai.
Không sửa file triển khai LPEX cũ.

- Namespace `postgres-benchmark`, một StatefulSet `postgres`, một replica.
- PostgreSQL 16: request/limit **24 CPU / 48 GiB**, cùng cấu hình LPEX: `shared_buffers=12GB`, `effective_cache_size=36GB`, `synchronous_commit=off`, `fsync=on` và `full_page_writes=on` mặc định PostgreSQL.
- Exporter sidecar trong cùng pod: 100m CPU / 256 MiB, metrics cổng 9187.
- Một PVC `data-postgres-0`, 100 GiB io2; PGDATA ở `/var/lib/postgresql/data/pgdata`.
- Hai CronJob `pgbench-off`, `pgbench-on`: tạo 2 triệu dòng và 20 index, chạy lần lượt 1 / 16 / 64 clients, mỗi mức 120 giây, rồi xóa bảng test.
- CronJob `fio-ebs`: cùng PVC, cùng node với PostgreSQL; ghi file tạm ngoài PGDATA. RWO cho phép nhiều pod cùng node mount volume.
- Service nội bộ; không Ingress, certificate hoặc NetworkPolicy. Không thêm PgBouncer vào bài đo trực tiếp này.

Các image chính được khóa digest. Image kubectl 1.35 phù hợp API server 1.34–1.36 theo chính sách lệch một minor.
Nếu EKS dùng minor khác, thay image **cả hai CronJob SQL** bằng kubectl cùng minor EKS.
[Version skew](https://kubernetes.io/releases/version-skew-policy/#kubectl).

## Apply

Chạy bằng context EKS của Đại ca. Kiểm tra node và CSI trước:

```bash
kubectl config current-context
kubectl get nodes -o wide
kubectl -n kube-system get deployment ebs-csi-controller
kubectl get csidriver ebs.csi.aws.com
kubectl label node <TEN_NODE_EC2_NITRO> remi=debug --overwrite
kubectl get nodes -l remi=debug
```

Chỉ gắn label cho node định dùng benchmark. Manifest chọn `remi=debug`, Linux, amd64; fio có affinity bắt buộc cùng hostname với PG.
StorageClass có `WaitForFirstConsumer`, vì vậy volume sẽ được tạo đúng AZ của node được chọn.
Nếu node có taint khác `remi=debug:NoSchedule`, bổ sung toleration tương ứng cho PG và fio.

Tạo namespace và password **một lần**; không dùng password database thật:

```bash
kubectl create namespace postgres-benchmark --dry-run=client -o yaml | kubectl apply -f -
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
100 GiB và 32.000 IOPS io2 đều tính phí; mức tiền phụ thuộc region và thời gian giữ volume.

## Chạy từng bài và lấy kết quả

Ba CronJob mặc định **suspend=true**. Chạy thủ công để xem kết quả từng bài, rồi mới chuyển bài tiếp theo:

```bash
run_test() {
  local job="${1}-$(date +%s)"
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

Đo SQL bằng `kubectl exec` vào container `postgres`, kết nối **127.0.0.1:5432**, không đi qua Service/PgBouncer.
Client pgbench và server dùng chung giới hạn 24 CPU / 48 GiB. So sánh CPU cần tính cả client.
Mode chỉ áp dụng cho session benchmark qua `PGOPTIONS`; default server vẫn `off` sau mỗi bài.
Với một primary và không standby, `on` và `local` đều chờ WAL flush trên primary.
`wal_level=minimal`, `max_wal_senders=0` giống cấu hình LPEX: bộ này dành cho test một node.

Các job dùng chung `flock` trên PVC, nên SQL off/on và fio không chạy đồng thời dù tạo job cùng lúc.
`concurrencyPolicy=Forbid` riêng lẻ không đủ để khóa giữa ba CronJob.
Job chờ khóa tối đa 30 phút, deadline tổng 60 phút, không tự retry bài ghi dữ liệu.
Nếu kết nối exec bị mất, tiến trình trong PG có thể tiếp tục; kiểm tra process và khóa trước khi chạy lại.
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

Kết quả lưu trên PVC trong `/var/lib/postgresql/data/benchmark-results/`:

```bash
kubectl -n postgres-benchmark cp -c postgres \
  postgres-0:/var/lib/postgresql/data/benchmark-results ./eks-results
kubectl -n postgres-benchmark top pod postgres-0 --containers
```

Report SQL gồm TPS/latency/WAL MB/s, xác nhận commit mode, số dòng/20 index, log init/clean và `database.jsonl`.
`container-resources.log` ghi CPU tích lũy, RAM và I/O cgroup mỗi giây; database/WAL/wait events lấy mỗi 5 giây.
`memory.current` gồm cache; `memory.stat` giúp phân biệt anon/file. Cgroup v1 có bộ đếm CPU/RAM/blkio tương ứng.
CPU cgroup ở đây đo toàn bộ container PG, bao gồm pgbench; WAL counters toàn instance.
Không coi I/O cgroup là số liệu riêng của EBS khi có nhiều thiết bị.
Exporter: `http://postgres-exporter.postgres-benchmark.svc.cluster.local:9187/metrics`.
DNS kết nối từ pod khác: `postgres.postgres-benchmark.svc.cluster.local:5432`, database/user `postgres`, password từ Secret `postgres-auth`.

## Bài fio

Chạy tuần tự: pre-write 40 GiB → randread 4k → randwrite 4k → randread 8k → randwrite 8k → fdatasync → mixed.
Pre-write ghi đủ mọi block để random read không đo các extent chưa ghi.
Bốn bài random dùng libaio/direct, 4 jobs × 10 GiB, iodepth 32, mỗi bài 60s.
Fsync dùng sync/write, 8k, 2 GiB, fdatasync mỗi block, 60s.
Mixed dùng 8k, 70% read / 30% write, 4 jobs, iodepth 32, 300s.
Các file riêng nằm trong `.fio-*`, tự xóa khi bài kết thúc; giữ JSON kết quả gồm IOPS, bandwidth và latency percentiles.
Cần tối thiểu 52 GiB trống trước khi chạy; nếu WAL/data làm đầy PVC, tăng dung lượng trước.
Không ghi block device và không đụng file PostgreSQL. Khi pod bị kill cứng, kiểm tra và dọn **đúng thư mục `.fio-*` của bài đã chết** trước khi chạy lại.
PG vẫn bật nhưng không chạy benchmark SQL cùng lúc; checkpoint/autovacuum hoặc workload ngoài bộ test vẫn có thể ảnh hưởng I/O.
Để so sánh, dùng node riêng và dừng các client khác.

Có thể đổi `FIO_SIZE`, `FIO_FSYNC_SIZE`, `FIO_RUNTIME`, `FIO_MIXED_RUNTIME`, `FIO_MIN_FREE_BYTES` trong env của fio khi smoke-test; mặc định giữ bài Đại ca yêu cầu.
Script nằm trong `scripts/`, bản thực thi đã nhúng vào YAML. Nếu sửa script nguồn, cần cập nhật ConfigMap tương ứng trong `psql.yaml`.

## Kiểm tra trước bàn giao

Đã kiểm tra schema Kubernetes 1.34 bằng kubeconform strict: toàn bộ 14 object trong `psql.yaml` hợp lệ.
Đã smoke-test PostgreSQL 16 trong Docker bằng UID 999, drop capabilities: off/on với 200 dòng, đủ 20 index, một client / một giây; default vẫn off và cleanup thành công.
Đã kiểm tra khóa giữa hai container cùng volume, cả bảy report fio (pre-write + sáu bài), monitor CPU/RAM/I/O và xóa scratch.
Smoke fio dùng file nhỏ, một giây và giả lập amd64 trên máy local; **không dùng các số đó làm kết quả hiệu năng EBS**.
Chưa apply lên EKS, nên việc provision volume, IAM thực tế, AZ, capacity của node và admission policy cần được xác nhận khi Đại ca apply.
