# Deploy `paytrack-be` lên Kubernetes

Service Go (`mgmtngd`), nghe port `6789`. Hệ chỉ có **một môi trường**: merge `main`
sang nhánh `prod`, CI build và đẩy image lên GHCR, rồi deploy vào namespace
`paytrack`.

```
Merge main -> prod, push  -> Actions build + push ghcr.io/zerocompany-org/paytrack-be/be
                             tag: latest + sha-<short>
                          -> ./deploy.sh sha-<commit>
                          -> cụm pull image, Recreate pod
```

> Nhánh `main` **không** build image — chỉ để phát triển/merge.

Kiến trúc request (**TLS terminate NGOÀI cụm**):

```
Client --HTTPS--> Traefik VPS (repo traefik-fpt) --HTTP--> NodePort 30080 --> Traefik cụm
      --> IngressRoute --> Service:6789 --> Pod:6789
```

**Repo `traefik-fpt` KHÔNG cần sửa gì**: router catch-all `k8s-default`
(`dynamics/k8s-route.toml`: `HostRegexp(^.+$)` → 6 node NodePort 30080) đã hứng mọi
Host, và `zerornd.com` + `*.zerornd.com` đã nằm sẵn trong `tls.domains` của router
đó nên cert có sẵn. Việc định tuyến theo `Host()` do IngressRoute trong cụm lo.

Phụ thuộc ngoài: **Postgres** (DSN khai trong `secret.yaml`). Không dùng Redis,
không dùng message queue.

## Khác biệt quan trọng so với các service khác trong hệ

**`mgmtngd` KHÔNG đọc biến môi trường.** `cmd/mgmtngd/config.go` chỉ `os.ReadFile`
rồi `yaml.Unmarshal` — không có bước expand `${VAR}`. File `config.production.yaml`
ở gốc repo viết `${DB_HOST:-localhost}` nhưng chuỗi đó được nạp **nguyên văn** vào
cấu hình chứ không được thay thế; dùng file đó trong container là sai.

Hệ quả cho k8s: **không có ConfigMap, không có `envFrom`**. Toàn bộ cấu hình là một
file `config.yaml` duy nhất, nằm trong Secret `paytrack-be-secret`, mount vào
`/app/private/config.yaml` — đúng đường dẫn Dockerfile truyền cho binary
(`--config=./private/config.yaml`, WORKDIR `/app`). File có mật khẩu DB + 2 khoá bí
mật + mật khẩu mail nên để nguyên trong Secret là đúng chỗ.

## Postgres (dùng chung cụm, HA)

Không dựng Postgres riêng cho paytrack. Cụm đã có **Postgres HA**: Patroni 3 node
trên VM (`pg-01 10.222.234.21`, `pg-02 10.222.234.22`, `pg-03 10.123.123.179` —
node 3 khác DC), đứng trước là HAProxy chạy trong cụm (namespace `zcorp-db`):

| Endpoint | Dùng để |
|---|---|
| `postgres-ha.zcorp-db.svc.cluster.local:5432` | leader, đọc-ghi — **paytrack dùng cái này** |
| `postgres-ha.zcorp-db.svc.cluster.local:5433` | replica, chỉ đọc (paytrack không dùng) |

HAProxy health-check Patroni `/primary`, chỉ node leader trả 200 → failover tự
chuyển, DSN trong `secret.yaml` không phải sửa.

**Nối thẳng, không qua pgbouncer.** `pgbouncer.zcorp-db` vẫn chạy nhưng zpayment
và zauto đều đã chuyển sang nối thẳng `postgres-ha` (ghi chú trong repo payment:
"đi thẳng HA, bỏ pgbouncer, từ 06/10/2026"), nên paytrack đi theo. Hệ quả: không
cần khai thêm dòng nào trong `[databases]` của `pgbouncer-config`.

### Phải tạo database + user trước khi deploy

App **không** tự tạo database (khác ums/zauto — mấy service đó nối vào db
`postgres` lúc boot để tự tạo DB_NAME). `storage.NewStorage()` chỉ `gorm.Open`
rồi `autoMigrate()`; DB không tồn tại là pod chết ngay với lỗi kết nối.

Chạy trên node leader Patroni bằng tài khoản superuser (`psql -U postgres`):

```sql
CREATE ROLE paytrack_app LOGIN PASSWORD '<mat-khau-manh>';
CREATE DATABASE paytrack OWNER paytrack_app;
```

Đặt tên theo lối zpayment (`db zpayment` / `user zpayment_app`). DB trên VPS cũ
tên `mgmtng` — nếu restore dump từ đó thì `pg_restore -d paytrack`, tên DB không
cần giữ, chỉ cần khớp `dbname=` trong DSN.

`OWNER` là đủ cho `autoMigrate()` (cần `CREATE`/`ALTER TABLE` trên schema
`public`). Postgres 15+ không còn cho mọi role ghi vào `public`, nên nếu vì lý do
nào đó không đặt được owner thì phải cấp tay:

```sql
GRANT ALL ON SCHEMA public TO paytrack_app;
```

Điền user/password/dbname vào `db.dns` trong `secret.yaml` (xem
`secret.example.yaml` — đã có sẵn host đúng).

> **Về số kết nối:** code không gọi `SetMaxOpenConns`, tức `database/sql` để
> **không giới hạn**. `max_connections` của Patroni là 100 và dùng chung với
> zauto/zpayment/zeromon. Với `replicas: 1` và tải hiện tại thì không sao, nhưng
> trước khi tăng replica hoặc nếu thấy `too many clients already` thì phải thêm
> `SetMaxOpenConns` trong `storage.NewStorage()` (hoặc quay lại đi qua pgbouncer).

### Đổ dữ liệu từ VPS cũ sang (chạy một lần)

Đã đối chiếu `backup.sql` của hệ cũ (23 users / 73 payments / 14 projects /
10 user_timer / 5 approver_settings) với model hiện tại, bằng cách restore thật
vào Postgres 17 rồi chạy đúng `autoMigrate()` của repo lên đó.

**Lược đồ tương thích.** 5 bảng trong dump khớp tên 5 model (`user_timer` số ít
vì có `TableName()` override). Không cột nào bị xoá hay đổi tên, nên
`autoMigrate()` chỉ **thêm**, không phá: `users.show_approved`, `users.auth_type`,
`payments.payment_type`, `payments.payment_code`, `payments.user_payment_method_id`,
`projects.approvers`, `projects.description`, `projects.creator_name`, cùng bảng mới
`user_payment_methods`. Dòng cũ để NULL ở các cột đó; GORM đọc NULL vào field
`int`/`bool`/`string` thành zero value, không lỗi — đã thử đọc lại cả 5 bảng bằng
model mới, 125/125 dòng OK.

`payment_settings` (jsonb) trong dump **đã** ở dạng chuỗi (`{"type": "btc"}`), tức
hệ cũ đã chạy phần jsonb của `cmd/migrate-method-int-to-string` → **không cần**
chạy lại binary đó.

**Hai thứ phải sửa tay** (đã gói vào 2 file SQL cạnh README này):

| Vấn đề | Hậu quả nếu bỏ qua |
|---|---|
| `payments.payment_method` còn là `bigint` (0/1/3) nhưng `utils.Method` giờ là `string` | autoMigrate tự `ALTER ... TYPE text` **không** kèm `USING`, số bị cast theo nghĩa chữ thành `'0'`/`'1'`/`'3'`. Pod vẫn chạy, log không có lỗi, nhưng 73 payment mất phương thức thanh toán — **lỗi âm thầm** |
| Sequence tạo bằng `START WITH 1`, chưa hề được gọi | `nextval()` trả về 1 → user/payment/project mới tạo chết ngay với `duplicate key ... users_pkey`. Dựng lại được lỗi này y hệt khi kiểm thử |

#### Cách nối tới DB để đổ dữ liệu

Postgres nằm trên VM `10.222.234.x`, máy cá nhân không route tới được, và cũng
không có `psql` sẵn. Hai đường, chọn một:

**Cách A — port-forward + psql trong Docker (khuyến nghị).** File dump nằm yên trên
máy, không phải copy đi đâu. Đã thử: quyền `create pods/portforward -n zcorp-db` =
yes, và `psql` trong container nối tới được tận Postgres thật qua đường này.

Cửa sổ 1, giữ chạy suốt quá trình:

```bash
kubectl -n zcorp-db port-forward svc/postgres-ha 15432:5432
```

Cửa sổ 2 (`PT=` là thư mục chứa `backup.sql` + 2 file SQL; `host.docker.internal`
là cách container gọi về máy thật):

```bash
PT="C:/Users/nguye/OneDrive/Desktop"          # sửa cho đúng chỗ đặt file
PSQL="docker run --rm -i -v $PT:/dump:ro -e PGPASSWORD=<pass> postgres:17
      psql -h host.docker.internal -p 15432 -U paytrack_app -d paytrack -v ON_ERROR_STOP=1"

$PSQL -f /dump/backup.sql                 # 1. dữ liệu cũ
$PSQL -f /dump/legacy-01-before-boot.sql   # 2. sửa payment_method + sequence
# 3. kubectl apply -k .   (pod boot, autoMigrate thêm cột mới)
$PSQL -f /dump/legacy-02-after-boot.sql    # 4. dựng lại ví, CHỈ MỘT LẦN
```

(Viết `PSQL` trên 2 dòng cho dễ đọc; khi chạy thật thì để một dòng.)

Nếu chạy trong Git Bash trên Windows, thêm `MSYS_NO_PATHCONV=1` trước `docker`,
không thì nó bẻ `/dump` thành đường dẫn Windows và báo `invalid mount path`.
Dùng PowerShell thì không gặp.

Nếu có mật khẩu superuser Postgres thì bước tạo DB/user (mục trên) cũng làm được
qua đúng port-forward này, khỏi phải SSH vào VM Patroni:

```bash
SU="docker run --rm -e PGPASSWORD=<pass-superuser> postgres:17 psql -h host.docker.internal -p 15432 -U postgres -d postgres"
$SU -c "CREATE ROLE paytrack_app LOGIN PASSWORD '<mat-khau-manh>';"
$SU -c "CREATE DATABASE paytrack OWNER paytrack_app;"
```

**Cách B — pod tạm trong cụm.** Dùng khi không có Docker trên máy, hoặc dump to
và muốn tránh port-forward đứt giữa đường:

```bash
# 1. Dựng pod tạm có psql, cùng cụm nên gọi được postgres-ha
kubectl -n paytrack run pgload --image=postgres:17 --restart=Never --command -- sleep 3600

# 2. Copy dump + 2 file SQL vào pod
kubectl -n paytrack cp ./backup.sql                pgload:/tmp/backup.sql
kubectl -n paytrack cp ./legacy-01-before-boot.sql pgload:/tmp/01.sql
kubectl -n paytrack cp ./legacy-02-after-boot.sql  pgload:/tmp/02.sql

# 3. Restore + sửa, TRƯỚC khi start pod app
PG="psql -h postgres-ha.zcorp-db.svc.cluster.local -U paytrack_app -d paytrack -v ON_ERROR_STOP=1"
kubectl -n paytrack exec -it pgload -- env PGPASSWORD='<pass>' $PG -f /tmp/backup.sql
kubectl -n paytrack exec -it pgload -- env PGPASSWORD='<pass>' $PG -f /tmp/01.sql

# 4. Giờ mới deploy app — autoMigrate thêm cột mới + tạo user_payment_methods
kubectl apply -k .
kubectl -n paytrack rollout status deployment/paytrack-be

# 5. Dựng lại ví người dùng sang bảng mới (CHỈ MỘT LẦN, chạy lại là nhân đôi)
kubectl -n paytrack exec -it pgload -- env PGPASSWORD='<pass>' $PG -f /tmp/02.sql

# 6. Dọn pod tạm
kubectl -n paytrack delete pod pgload
```

Cách B cần namespace `paytrack` tồn tại trước (bước 1 của "Thiết lập 1 lần").

Cả hai cách đều KHÔNG đi qua pgbouncer: `paytrack` chưa khai trong `[databases]`
của `pgbouncer-config`, và cũng không cần khai.

Thứ tự bắt buộc, dù chọn cách nào: **restore → 01.sql → deploy app → 02.sql**.
Lý do: `01.sql` phải chạy trước khi autoMigrate chạm vào `payment_method`, còn
`02.sql` phải chờ autoMigrate tạo xong bảng `user_payment_methods`.

Restore chạy được bằng chính `paytrack_app` (không cần superuser) vì user là owner
của database. Dòng `CREATE SCHEMA IF NOT EXISTS "public"` đầu file chỉ ra NOTICE
"already exists, skipping", vô hại. Mốc thời gian trong dump ghi kiểu `11:26:28 PM`
— Postgres đọc được, không cần đổi `DateStyle`.

`legacy-02-after-boot.sql` thay cho `cmd/migrate-payment-settings` (Go): đã chạy
cả hai đường rồi so từng dòng, kết quả giống hệt (13/13 ví), nên không phải build
binary thêm. Hai binary còn lại (`migrate-payments-enhanced`,
`migrate-payments-table`) **không cần**: chúng nhồi thêm field `coin`/`network` vào
`payment_settings`, mà `storage.PaymentSetting` hiện tại chỉ có `type` + `address`
nên lần lưu kế tiếp sẽ xoá sạch mấy field đó.

## Thiết lập 1 lần

### 1. Namespace

Lần đầu dùng `create`, KHÔNG dùng `apply`:

```bash
kubectl create -f namespace.yaml
```

`kubectl apply` đọc bản hiện tại trước khi ghi (GET), và trên cụm Rancher này tài
khoản chỉ được GET những namespace đã thuộc Project của mình — namespace chưa tồn tại
nên GET bị chặn, `apply` fail với `Forbidden` dù `create` được phép. Từ lần sau
`apply` chạy bình thường.

`namespace.yaml` đã gắn sẵn annotation gán namespace vào Rancher Project
**ZeroR&D-Common** (`local:p-tbjsn`) — chính nhờ đó mà tài khoản có quyền
tạo Deployment/Secret bên trong. Tạo namespace "trần" (không có annotation) thì mọi
`kubectl apply -k .` sau đó sẽ `Forbidden`.

Namespace `paytrack` **dùng chung** với FE (`paytrack-fe`) và cố ý không nằm trong
`kustomization.yaml` — nếu để kustomize sở hữu thì `kubectl delete -k .` của một
service sẽ xoá luôn namespace và kéo theo service kia.

### 2. Secret để pull image từ GHCR

Package GHCR mặc định private, thiếu secret này pod kẹt `ImagePullBackOff`.

**Cách nhanh: copy lại secret của zeromon.** Mọi service trong cụm đều pull từ
cùng org `ghcr.io/zerocompany-org/...`, nên PAT trong `ghcr-cred` của namespace
`zeromon` dùng được luôn cho paytrack — khỏi tạo PAT mới. Đã kiểm: PAT còn sống,
scope đúng `read:packages`, không có ngày hết hạn, và lấy được pull token cho
package của `zerocompany-org`.

```bash
kubectl -n zeromon get secret ghcr-cred -o json | python -c "
import sys,json
d=json.load(sys.stdin)
print(json.dumps({'apiVersion':'v1','kind':'Secret','type':d['type'],
                  'metadata':{'name':'ghcr-cred'},'data':d['data']}))
" | kubectl -n paytrack create -f -
```

Câu python ở giữa để lột bỏ `namespace`/`uid`/`resourceVersion` của secret gốc
(giữ lại là `create` bị từ chối), và để token không hiện ra màn hình hay rơi
xuống file tạm. Không dùng `jq` vì máy không có sẵn.

**Cách thường: tạo PAT mới.** Dùng khi không đọc được secret của `zeromon`, hoặc
muốn PAT riêng cho paytrack để thu hồi độc lập. PAT classic, scope
`read:packages`, tài khoản phải đọc được repo `zerocompany-org/paytrack-be`:

```bash
kubectl -n paytrack create secret docker-registry ghcr-cred \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<PAT co read:packages>
```

(Đổi package sang public thì bỏ khối `imagePullSecrets` trong `deployment.yaml`.)

### 3. Cấu hình

Tạo database + user trước (mục **Postgres** phía trên), rồi:

```bash
cp secret.example.yaml secret.yaml
# điền password DSN Postgres, hmacSecretKey, aesSecretKey, clientAddr, mail
```

`secret.yaml` bị `.gitignore` — **không commit**. Sinh khoá:

```bash
openssl rand -hex 32   # hmacSecretKey — độ dài tuỳ ý
openssl rand -hex 16   # aesSecretKey  — ra 32 ký tự, KHOA KHAC, đừng dán trùng
```

> `aesSecretKey` phải dài **đúng 16, 24 hoặc 32 ký tự** — `utils/crypt.go` đếm
> `len()` của chuỗi chứ không decode hex, nên `rand -hex 32` (64 ký tự) làm pod
> thoát ngay. Dùng `rand -hex 16`.
>
> Khoá này mã hoá dữ liệu nhạy cảm đã lưu trong DB. **Mất khoá = mất khả năng
> giải mã.** Cất bản sao cùng chỗ với backup DB.

### 4. Domain

`ingressroute.yaml` đang để `api-paytrack.zerornd.com` (FE ở
`paytrack.zerornd.com`). Cert đã có sẵn nhờ SAN `*.zerornd.com`, chỉ còn **bản ghi
DNS**: tạo trên Cloudflare trỏ về Traefik VPS, giống cách `apistg-payment.zerornd.com`
đang chạy (bản ghi đó proxy qua Cloudflare). Tính tới lúc viết, cả
`api-paytrack.zerornd.com` lẫn `paytrack.zerornd.com` đều **chưa phân giải**, và
zerornd.com **không có wildcard DNS** nên phải khai từng bản ghi.

Domain API còn phải khớp **chính xác** giá trị `BASE_URL` mà FE đã build vào bundle —
FE bake URL lúc build, không đọc lúc chạy. Lưu ý `paytrack-fe/.env.production` vẫn ghi
`https://api.paytrack.pro/api` (đường build cũ ngoài Docker), không phải giá trị dùng
cho k8s.

### 5. Apply lần đầu

> Nếu có đổ dữ liệu từ VPS cũ: restore dump + chạy `legacy-01-before-boot.sql`
> **trước** bước này (mục "Đổ dữ liệu từ VPS cũ sang"), vì autoMigrate lúc boot
> sẽ chạm vào `payments.payment_method`.

```bash
kubectl apply -k .
kubectl -n paytrack rollout status deployment/paytrack-be
```

Lần apply đầu dùng tag `:latest`. Từ lần sau deploy bằng tag cố định:

```bash
./deploy.sh sha-1a2b3c4
```

## Deploy thường ngày

```bash
# 1. merge main -> prod, push: Actions tự build
git checkout prod && git merge main && git push origin prod

# 2. đợi workflow xong, rồi:
cd deploys/k8s && ./deploy.sh sha-<short-commit>
```

Rollback = deploy lại tag cũ (`./deploy.sh sha-<tag truoc>`) hoặc
`kubectl -n paytrack rollout undo deployment/paytrack-be`. Lưu ý job `cleanup` chỉ
giữ **3 version** trên GHCR, nên chỉ lùi được 2 bước.

Đổi cấu hình (không đổi code):

```bash
vim secret.yaml && kubectl apply -k .
kubectl -n paytrack rollout restart deployment/paytrack-be
```

Bắt buộc restart: app đọc `config.yaml` đúng một lần lúc khởi động.

## Vì sao `replicas: 1` và `strategy: Recreate`

Ba thứ trong code hiện tại không chịu được 2 pod chạy song song:

1. `storage.NewStorage()` gọi `autoMigrate()` **mỗi lần boot** — 2 pod cùng migrate
   trên một schema.
2. `service.RunTimeTask()` và `NotifyCryptoPriceChanged()` là cron singleton — 2 pod
   = thông báo/mail gửi trùng.
3. socket.io (`go-socket.io`) giữ state phiên **trong RAM pod**, không có adapter
   Redis — client bị cân tải sang pod khác là mất room.

`Recreate` để không có cửa sổ 2 pod chồng nhau lúc rollout. Đánh đổi: mỗi lần deploy
có ~10–20s downtime. Muốn chạy nhiều replica thì phải tách migration thành Job, cron
thành CronJob, và gắn Redis adapter cho socket.io trước.

## Thêm môi trường staging sau này

1. `cp -r deploys/k8s deploys/k8s/stg` rồi `git mv` các file hiện tại vào
   `deploys/k8s/prod/`.
2. Trong `stg/`: đổi namespace sang `stg-paytrack`, domain sang domain staging, image
   sang package riêng `be-stg`.
3. Trong `.github/workflows/build-be.yml`: thêm `staging` vào `branches` và tách tên
   image theo `github.ref_name` (package riêng để job `cleanup` của môi trường này
   không xoá nhầm version của môi trường kia).

## Hạn chế đã biết (của app, không phải của manifest)

| Vấn đề | Ảnh hưởng | Nếu muốn sửa |
|---|---|---|
| Không có endpoint `/healthz` / `/readyz`. Probe dùng `/` — handler này **không chạm DB**. | Mất kết nối Postgres thì pod vẫn `Ready`, request mới trả lỗi. | Thêm handler `/readyz` ping DB, rồi đổi `readinessProbe.path`. |
| `HEALTHCHECK` trong `Dockerfile` gọi `/health` — route không tồn tại. | Vô hại trên k8s (K8s bỏ qua HEALTHCHECK của image), nhưng `docker ps` luôn báo `unhealthy`. | Sửa HEALTHCHECK sang `/` hoặc thêm route `/health`. |
| `utils/helper.go`: `imagePath = getBinPath() + "\\upload\\images"` — đường dẫn kiểu Windows. Trên Linux `\` không phải separator nên ảnh upload rơi thẳng vào `/` với tên chứa `\`. | Tính năng upload file **không dùng được** trên k8s (hệ đang chạy chỉ lưu text nên chấp nhận). Không mountPath nào hứng được đường dẫn đó. | Đổi sang `filepath.Join(getBinPath(), "upload", "images")` + `filepath.Join(imagePath, fileName)` (trên Windows kết quả y hệt hiện tại), rồi thêm PVC mount vào `/app/upload/images`. |
| App không xử lý SIGTERM, `ListenAndServe` không có graceful shutdown. | Request đang chạy bị cắt lúc xoá pod. `preStop: sleep 5` giảm bớt nhưng không triệt để. | Dùng `server.Shutdown(ctx)` khi nhận SIGTERM. |

## Gỡ rối

| Triệu chứng | Nguyên nhân thường gặp |
|---|---|
| `Forbidden` khi apply | Namespace chưa tồn tại (lần đầu phải `kubectl create -f namespace.yaml`), hoặc namespace được tạo không kèm annotation `field.cattle.io/projectId` nên không thuộc Project nào |
| `ImagePullBackOff` | Thiếu secret `ghcr-cred`, hoặc deploy tag `sha-*` mà workflow chưa build xong |
| Pod `CrashLoopBackOff`, log `please set up hmacSecretKey` | `hmacSecretKey` trong `secret.yaml` còn rỗng |
| Pod thoát ngay, log `eas key length must be 16, 24 or 32` | `aesSecretKey` sai độ dài — phải đúng 16/24/32 ký tự, dùng `openssl rand -hex 16` |
| Log `failed to init logRotator` | `logDir` trong `config.yaml` khác `/app/logs` (rootfs read-only, chỉ `/app/logs` và `/tmp` ghi được) |
| Pod chết ngay, log `database "paytrack" does not exist` | Chưa tạo database — app không tự tạo, xem mục Postgres |
| `duplicate key value violates unique constraint "users_pkey"` khi tạo user/payment/project mới | Dữ liệu cũ đã restore nhưng chưa chạy `legacy-01-before-boot.sql` → sequence vẫn ở 1 |
| Payment cũ hiện ra không có phương thức thanh toán | Pod đã boot trước khi sửa, autoMigrate cast `payment_method` thành `'0'/'1'/'3'`. Chữa bằng câu `UPDATE` ở cuối `legacy-01-before-boot.sql` |
| Pod chết ngay, log lỗi SQL/migration | DSN sai, hoặc user DB không phải owner / không có quyền `CREATE/ALTER TABLE` trên schema `public` (autoMigrate chạy lúc boot) |
| Log `too many clients already` | Hết `max_connections` (100) của Postgres HA, dùng chung với zauto/zpayment — xem ghi chú số kết nối ở mục Postgres |
| `startupProbe` timeout sau 120s | autoMigrate chạy quá lâu trên DB lớn — nới `failureThreshold` trong `deployment.yaml` |
| Traefik trả 404 | `Host()` trong `ingressroute.yaml` không khớp DNS, hoặc tên entrypoint của cụm không phải `web` |
| Domain không phân giải / không vào được | Chưa tạo bản ghi DNS `api-paytrack` và `paytrack` dưới `zerornd.com` (không có wildcard) |
| FE gọi API lỗi CORS | Không gắn thêm middleware cors của Traefik — app đã tự set header CORS trong `route.go`, gắn thêm sẽ thành header trùng và trình duyệt chặn |

Lệnh hay dùng:

```bash
kubectl -n paytrack get pod -l app=paytrack-be
kubectl -n paytrack logs -l app=paytrack-be --tail=100 -f
kubectl -n paytrack describe pod -l app=paytrack-be
kubectl -n paytrack exec -it deploy/paytrack-be -- cat /app/private/config.yaml
```
