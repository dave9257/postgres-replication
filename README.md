# PostgresQL Replication

## Mục lục

- [PostgresQL Replication](#postgresql-replication)
  - [Mục lục](#mục-lục)
  - [Mô hỉnh triển khai](#mô-hỉnh-triển-khai)
  - [Streaming Replication](#streaming-replication)
  - [Triển khai và thử nghiệm](#triển-khai-và-thử-nghiệm)
    - [Triển khai](#triển-khai)
      - [Primary (master)](#primary-master)
      - [Standby (slave)](#standby-slave)
    - [Thử nghiệm](#thử-nghiệm)
  - [Xử lý tình huống](#xử-lý-tình-huống)
    - [Master chết, lập slave thành master](#master-chết-lập-slave-thành-master)
    - [Dựng lại master cũ, đồng bộ dữ liệu từ master mới](#dựng-lại-master-cũ-đồng-bộ-dữ-liệu-từ-master-mới)
    - [Bất đồng bộ giữa master cũ và master mới](#bất-đồng-bộ-giữa-master-cũ-và-master-mới)
    - [Khôi phục vai trò master và slave ban đầu](#khôi-phục-vai-trò-master-và-slave-ban-đầu)

## Mô hỉnh triển khai

Thông tin master:
- Địa chỉ IP: 10.0.0.24
- Port: 25432

Thông tin slave:
- Địa chỉ IP: 10.0.0.30
- Port: 25432

## Streaming Replication

Streaming physical replication trong PostgresQL là cơ chế mà trong đó dữ liệu được đồng bộ từ một server (primary) sang một server khác (standby). Primary cho phép mọi hoạt động như đọc, ghi diễn ra bình thường trong khi standby hoạt động ở chế độ read-only và chỉ cập nhật thay đổi từ primary.

PostgresQL sử dụng WAL (Write-ahead log) để lưu thay đổi trên database. Trong streaming replication, các thay đổi này được gửi liên tục (streaming) từ primary đến các standby. Mỗi standby khi kết nối đến primary có thể sử dụng một replication slot. Các replication slot giúp primary theo dõi trạng thái đồng bộ của standby, qua đó lưu WAL đủ lâu để stanby có thể đồng bộ, tránh mất mát dữ liệu.

## Triển khai và thử nghiệm

### Triển khai

#### Primary (master)

`docker-compose.yaml`
```yaml
version: '3'
services:
  node_1:
    image: postgres
    ports:
      - 25432:5432
    environment:
      POSTGRES_USER: postgres
      POSTGRES_DB: postgres
      POSTGRES_PASSWORD: password
      POSTGRES_HOST_AUTH_METHOD: "scram-sha-256\nhost replication all 0.0.0.0/0 scram-sha-256"
      POSTGRES_INITDB_ARGS: "--auth-host=scram-sha-256"
    command: |
      postgres 
      -c wal_level=replica 
      -c wal_log_hints=on
      -c hot_standby=on 
      -c max_wal_senders=10 
      -c max_replication_slots=10 
      -c hot_standby_feedback=on
    volumes:
      - ./sql:/docker-entrypoint-initdb.d
      - ./primary-data:/var/lib/postgresql/data
```

`sql/replication.yaml`
```yaml
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_password';
SELECT pg_create_physical_replication_slot('replication_2');
```

Mỗi slave nên có một slot riêng và nên được đặt tên sao cho tránh gây nhầm lẫn.

#### Standby (slave)

`.env`
```env
MASTER_HOST=10.0.0.24
MASTER_PORT=25432
PGUSER=replicator
PGPASSWORD=replicator_password
REPLICATION_SLOT=replication_2
```

`docker-compose.yaml`
```yaml
version: '3'
services:
  node_2:
    image: postgres
    ports:
      - 25432:5432
    env_file: .env
    environment:
      PGUSER: ${PGUSER}
      PGPASSWORD: ${PGPASSWORD} 
    command: |
      bash -c '
      if [ ! -d /var/lib/postgresql/data ] || [ -z "$(ls -A /var/lib/postgresql/data)" ]; then
        until pg_basebackup --pgdata=/var/lib/postgresql/data -R --slot=${REPLICATION_SLOT} --host=${MASTER_HOST} --port=${MASTER_PORT}
        do
          echo "Waiting for primary to connect..."
          sleep 1s
        done
        chown -R 999 /var/lib/postgresql/data
        chmod 700 /var/lib/postgresql/data
        echo "Backup done, starting replica..."
      fi
      su postgres -c postgres
      '
    volumes:
      - ./replica-data:/var/lib/postgresql/data
```

### Thử nghiệm

Tạo dữ liệu trên master:

```bash
psql -h 10.0.0.24 -p 25432 -U postgres
```
```
postgres=# CREATE DATABASE testing;
CREATE DATABASE
postgres=# \c testing;
You are now connected to database "testing" as user "postgres".
testing=# CREATE TABLE table_1 (id INT);
CREATE TABLE
testing=# INSERT INTO table_1 VALUES ( 1 );
INSERT 0 1
postgres=# SELECT * FROM table_1;
 id 
----
  1
(1 row)

```

Kiểm tra dữ liệu đã được đồng bộ trên slave:

```bash
psql -h 10.0.0.30 -p 25432 -U postgres
```
```
postgres=# \l
                                                      List of databases
   Name    |  Owner   | Encoding | Locale Provider |  Collate   |   Ctype    | ICU Locale | ICU Rules |   Access privileges   
-----------+----------+----------+-----------------+------------+------------+------------+-----------+-----------------------
 postgres  | postgres | UTF8     | libc            | en_US.utf8 | en_US.utf8 |            |           | 
 template0 | postgres | UTF8     | libc            | en_US.utf8 | en_US.utf8 |            |           | =c/postgres          +
           |          |          |                 |            |            |            |           | postgres=CTc/postgres
 template1 | postgres | UTF8     | libc            | en_US.utf8 | en_US.utf8 |            |           | =c/postgres          +
           |          |          |                 |            |            |            |           | postgres=CTc/postgres
 testing   | postgres | UTF8     | libc            | en_US.utf8 | en_US.utf8 |            |           | 
(4 rows)

postgres=# \c testing;
You are now connected to database "testing" as user "postgres".
testing=# SELECT * FROM table_1;
 id 
----
  1
(1 row)

```

Thử tạo dữ liệu trên slave:

```
testing=# CREATE DATABASE testing_2;
ERROR:  cannot execute CREATE DATABASE in a read-only transaction
testing=# CREATE TABLE table_2 (id INT);
ERROR:  cannot execute CREATE TABLE in a read-only transaction
```

Dữ liệu được tạo trên master sẽ được đồng bộ sang slave. Ngoài các thay đổi từ master, slave sẽ không chấp nhận các yêu cầu ghi dữ liệu từ bên ngoài.

## Xử lý tình huống

### Master chết, lập slave thành master 

Gỉả sử trường hợp master chết hoặc mất kết nối vì một nguyên nhân nào đó. Lúc này slave sẽ thông báo lỗi:

```
FATAL:  could not connect to the primary server: connection to server at "10.0.0.24", port 25432 failed: Connection refused
    Is the server running on that host and accepting TCP/IP connections?
LOG:  waiting for WAL to become available at 0/1F003870
```

Các yêu cầu đọc dữ liệu trên slave vẫn sẽ hoạt động bình thường. Nhưng slave sẽ không thể đồng bộ dữ liệu từ master (vì master đã down).

Để đẩy một slave lên làm master mới, kết nối với slave và chạy query:
```
testing=# SELECT pg_promote();
 pg_promote 
------------
 t
(1 row)

```
hoặc
```bash
psql -h 10.0.0.30 -p 25432 -U postgres -c "SELECT pg_promote()"
```

Slave sẽ thông báo đã promote thành công.

```
LOG:  received promote request
LOG:  redo done at 0/1F0037E0 system usage: CPU: user: 0.05 s, system: 0.09 s, elapsed: 11885.67 s
LOG:  selected new timeline ID: 2
LOG:  archive recovery complete
LOG:  checkpoint starting: force
LOG:  database system is ready to accept connections
LOG:  checkpoint complete: wrote 3 buffers (0.0%); 0 WAL file(s) added, 0 removed, 0 recycled; write=0.108 s, sync=0.006 s, total=0.123 s; sync files=3, longest=0.003 s, average=0.002 s; distance=0 kB, estimate=13282 kB; lsn=0/1F003930, redo lsn=0/1F0038C0
```

Thử tạo dữ liệu trên slave (master mới):

```
postgres=# \c testing 
You are now connected to database "testing" as user "postgres".
testing=# INSERT INTO table_1 VALUES ( 2 );
INSERT 0 1
testing=# SELECT * FROM table_1;
 id 
----
  1
  2
(2 rows)

```

Slave đã chuyển sang hoạt động như một server độc lập và có thể nhận yêu cầu đọc/ghi dữ liệu.

Nếu có các slave khác trong cluster thì chúng cần được cấu hình để kết nối vào master mới. Xem cách thay đổi cấu hình địa chỉ master ở mục [sau](#dựng-lại-master-cũ-đồng-bộ-dữ-liệu-từ-master-mới).

### Dựng lại master cũ, đồng bộ dữ liệu từ master mới

Khi đã khắc phục được sự cố và có thể đưa master cũ trở lại, master cũ cần được khởi động ở chế độ standby, tránh 2 master hoạt động độc lập gây ra bất đồng bộ.

Tạo file standby.signal trong thư mục data của master cũ:
```bash
sudo touch primary-data/standby.signal
sudo chown 999:999 primary-data/standby.signal
sudo chmod 700 primary-data/standby.signal
```

Cấu hình địa chỉ master mới để master cũ đồng bộ lại dữ liệu:
```bash
echo "primary_conninfo = 'user=replicator password=replicator_password channel_binding=prefer host=10.0.0.30 port=25432 sslmode=prefer sslcompression=0 sslcertmode=allow sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres gssdelegation=0 target_session_attrs=any load_balance_hosts=disable'" | sudo tee -a primary-data/postgresql.auto.conf
echo "primary_slot_name = 'replication_1'" | sudo tee -a primary-data/postgresql.auto.conf
```

Các replication slot sẽ không được đồng bộ giữa các server nên cần được tạo lại trên master mới:
```bash
psql -h 10.0.0.30 -p 25432 -U postgres -c "SELECT pg_create_physical_replication_slot('replication_1');"
```

Sau khi khởi động lại, master cũ sẽ chuyển sang chế độ standby.
```
LOG:  entering standby mode
LOG:  consistent recovery state reached at 0/1F003858
LOG:  invalid record length at 0/1F003858: expected at least 24, got 0
LOG:  database system is ready to accept read-only connections
LOG:  fetching timeline history file for timeline 2 from primary server
LOG:  started streaming WAL from primary at 0/1F000000 on timeline 1
LOG:  replication terminated by primary server
DETAIL:  End of WAL reached on timeline 1 at 0/1F003858.
FATAL:  terminating walreceiver process due to administrator command
LOG:  new target timeline is 2
LOG:  started streaming WAL from primary at 0/1F000000 on timeline 2
LOG:  redo starts at 0/1F003858
```

Kiểm tra lại trên master cũ:

```
postgres=# \c testing 
You are now connected to database "testing" as user "postgres".
testing=# SELECT * FROM table_1;
 id 
----
  1
  2
(2 rows)

testing=# INSERT INTO table_1 VALUES ( 3 );
ERROR:  cannot execute INSERT in a read-only transaction
```

Dữ liệu đã được đồng bộ và master cũ sẽ hoạt động như một slave mới. Sau khi đã đồng bộ dữ liệu, master cũ có thể được khôi phục vai trò master hoặc tiếp tục hoạt động với vai trò slave.

### Bất đồng bộ giữa master cũ và master mới

Trong một số trường hợp sau khi failover, có thể xảy ra bất đồng bộ giữa master cũ và master mới. Khi khởi động master cũ ở chế độ standby sẽ nhận được lỗi như sau:

```
LOG:  replication terminated by primary server
DETAIL:  End of WAL reached on timeline 1 at 0/30000D8.
FATAL:  terminating walreceiver process due to administrator command
LOG:  new timeline 2 forked off current database system timeline 1 before current recovery
LOG:  waiting for WAL to become available at 0/3002000
```

Để khắc phục, có thể sử dụng [`pg_rewind`](https://www.postgresql.org/docs/current/app-pgrewind.html);

```bash
pg_rewind --target-pgdata=primary-data --source-server="host=10.0.0.30 port=25432 user=postgres password=password"
```

**LƯU Ý:** pg_rewind sẽ xóa đi các transaction tồn tại trên master cũ nhưng không có trên master mới. Nếu có dữ liệu trên master cũ chưa được đồng bộ sang master mới, chúng sẽ phải được đồng bộ bằng tay.


### Khôi phục vai trò master và slave ban đầu

Để khôi phục vai trò master và slave ban đầu, thực hiện tương tự như khi lập master mới.

Tạm dừng master hiện tại:
```bash
docker compose down
```

Lập master cũ lên vai trò master:
```bash
psql -h 10.0.0.24 -p 25432 -U postgres -c "SELECT pg_promote()"
```

Để đưa master trở lại thành slave, chỉ cần tạo file standby.signal trong thư mục data.
```bash
sudo touch replica-data/standby.signal
sudo chown 999:999 replica-data/standby.signal
sudo chmod 700 replica-data/standby.signal
```

Các slave khác trong cluster (nếu có) cũng cần được cấu hình lại địa chỉ master.
