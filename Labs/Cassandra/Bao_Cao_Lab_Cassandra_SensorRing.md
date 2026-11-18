# BÁO CÁO THỰC HÀNH LAB: COLUMN-FAMILY DATABASE (APACHE CASSANDRA - SENSORRING)

### Câu 1: Ở Bước 1, vì sao token của `hn-01` trên máy bạn giống ví dụ, còn IP của node sở hữu nó thì khác?

- **Vì sao `token('hn-01')` giống hệt ví dụ (`-6927399588689370405`):**
  Cassandra sử dụng hàm băm **Murmur3Partitioner** (64-bit) tất định (deterministic). Với cùng một chuỗi đầu vào `'hn-01'`, hàm băm Murmur3 luôn tính ra chính xác cùng một số nguyên 64-bit là `-6927399588689370405` trên mọi máy tính, mọi phiên bản và mọi cluster.
- **Vì sao địa chỉ IP của node sở hữu nó lại khác (`172.18.0.4` thay vì `172.23.0.4`):**
  1. **Mạng Docker cấp IP động:** Mỗi lần tạo Docker network (`sensorring_default`), Docker Engine cấp subnet khác nhau (trên máy thực nghiệm là `172.18.0.0/16` thay vì `172.23.0.0/16`).
  2. **Vnode tokens được sinh ngẫu nhiên khi khởi tạo cluster:** Khi mỗi node lần đầu gia nhập vòng, Cassandra sinh ngẫu nhiên 16 token (`num_tokens: 16`) cho các vnode của node đó. Do vị trí các vnode trên vòng token của mỗi lần dựng cluster là khác nhau, nên vnode đầu tiên theo chiều kim đồng hồ có token $\ge -6927399588689370405$ có thể thuộc về một node/IP khác. Tuy nhiên, quy tắc định tuyến *"node có token đầu tiên $\ge \text{token}(\text{key})$ theo chiều kim đồng hồ"* thì **luôn luôn đúng**.

---

### Câu 2: Nếu thêm node `cass4` vào cluster có keyspace `ring1`, điều gì xảy ra với các partition hiện có? Có phải di chuyển toàn bộ dữ liệu không?

- **Điều gì xảy ra:**
  Khi `cass4` gia nhập vòng (joining), nó sẽ được cấp 16 token (vnode) rải đều xen kẽ vào giữa các khoảng token hiện có của `cass1`, `cass2`, `cass3`. Mỗi vnode của `cass4` sẽ chia nhỏ một khoảng token trước đó đang thuộc về một trong 3 node cũ, biến `cass4` thành "node kế tiếp theo chiều kim đồng hồ" cho một phần không gian token.
- **Có phải di chuyển toàn bộ dữ liệu không?**
  **Không.** Nhờ cơ chế **Consistent Hashing (Băm nhất quán)** kết hợp với **vnodes**, chỉ có khoảng **$1/N$ lượng dữ liệu** (với $N = 4$, tức khoảng **$25\%$** số partition hiện có) cần được stream từ `cass1`, `cass2`, `cass3` sang `cass4` (mỗi node cũ chỉ chuyển khoảng $1/4$ lượng dữ liệu của mình cho `cass4`, giữ nguyên $3/4$ còn lại). Khoảng **$75\%$ dữ liệu còn lại hoàn toàn đứng yên**, giúp cluster mở rộng tuyến tính mà không gây gián đoạn.

---

### Câu 3: Ở Bước 2, truy vấn `ALLOW FILTERING` đọc bao nhiêu hàng để trả về bao nhiêu hàng? Hãy thiết kế một bảng trả lời “các số đo trên 31.5°C trong một ngày” mà không cần `ALLOW FILTERING`.

- **Số hàng đọc so với số hàng trả về trong thực nghiệm Bước 2:**
  - Truy vấn `SELECT count(*) FROM iot.readings_by_sensor WHERE temperature > 31.5 ALLOW FILTERING;` đã phải quét tuần tự qua toàn bộ **49 token ranges** và đọc tổng cộng **$2903 + 97 = 3000$ hàng (`live rows`)** (tức 100% bảng) chỉ để trả về **105 hàng** thỏa mãn điều kiện ($\approx 3.5\%$ dữ liệu).
- **Thiết kế bảng trả lời *"các số đo trên 31.5°C trong một ngày"* mà KHÔNG cần `ALLOW FILTERING`:**
  Để không cần `ALLOW FILTERING`, mệnh đề `WHERE` phải:
  1. Cung cấp đủ **Partition Key** bằng phép so sánh bằng (`=`) $\rightarrow$ Chọn `day` (kiểu `date`) làm **Partition Key** để gom các số đo của cùng một ngày vào một partition.
  2. Thực hiện phép so sánh khoảng (`temperature > 31.5`) trên cột **Clustering Column đầu tiên** $\rightarrow$ Đặt `temperature` làm clustering column đầu tiên, theo sau là `ts` và `sensor_id` để đảm bảo tính duy nhất (uniqueness) cho mỗi số đo.

  ```cql
  CREATE TABLE iot.readings_by_day_temp (
      day         date,
      temperature double,
      ts          timestamp,
      sensor_id   text,
      humidity    double,
      PRIMARY KEY ((day), temperature, ts, sensor_id)
  ) WITH CLUSTERING ORDER BY (temperature DESC, ts DESC, sensor_id ASC);
  ```
  **Truy vấn hợp lệ (chỉ đọc đúng 1 partition của ngày đó và dừng ngay khi gặp `temperature <= 31.5`):**
  ```cql
  SELECT * FROM iot.readings_by_day_temp
  WHERE day = '2026-10-22' AND temperature > 31.5;
  ```

---

### Câu 4: Lập bảng kết quả Bước 3 (số node sống × mức consistency). Với RF = 5, QUORUM cần bao nhiêu bản sao, và chịu được mất bao nhiêu node?

- **Bảng kết quả thực nghiệm Bước 3 (với $\text{RF} = 3$):**

  | Mức Consistency | Số replica cần trả lời ($\text{RF}=3$) | 3 node sống (`3 UN`) | 2 node sống (`2 UN, 1 DN`) | 1 node sống (`1 UN, 2 DN`) |
  | :--- | :---: | :--- | :--- | :--- |
  | **`ONE`** | $1$ | **OK** (`rows: 1`) | **OK** (`rows: 4`) | **OK** (`rows: 6`) |
  | **`QUORUM`** | $\lfloor 3/2 \rfloor + 1 = 2$ | **OK** (`rows: 2`) | **OK** (`rows: 5`) | **FAIL** (`Unavailable: need 2, 1 alive`) |
  | **`ALL`** | $3$ | **OK** (`rows: 3`) | **FAIL** (`Unavailable: need 3, 2 alive`) | **FAIL** (`Unavailable: need 3, 1 alive`) |

- **Với $\text{RF} = 5$:**
  - Số bản sao cần thiết cho `QUORUM` là:
    $$\text{QUORUM} = \left\lfloor \frac{\text{RF}}{2} \right\rfloor + 1 = \left\lfloor \frac{5}{2} \right\rfloor + 1 = 2 + 1 = \mathbf{3\text{ bản sao}}$$
  - Số node tối đa có thể bị mất mà `QUORUM` vẫn hoạt động bình thường là:
    $$5 - 3 = \mathbf{2\text{ node}}$$

---

### Câu 5: Ở Bước 4, nếu cả lần ghi và lần đọc đều dùng `QUORUM` thì có đọc phải dữ liệu cũ không? Giải thích bằng điều kiện $R + W > \text{RF}$.

- **Trả lời:** **Không**, sẽ **không bao giờ** đọc phải dữ liệu cũ (Đạt được **Strong Consistency**).
- **Giải thích bằng nguyên lý chồng lấp (Pigeonhole Principle) và điều kiện $R + W > \text{RF}$:**
  - Với $\text{RF} = 3$:
    - Ghi ở mức `QUORUM`: $W = 2$ (bản ghi mới được xác nhận lưu thành công trên ít nhất 2 trong 3 bản sao, ví dụ `{cass1, cass2}`).
    - Đọc ở mức `QUORUM`: $R = 2$ (coordinator phải chờ phản hồi từ ít nhất 2 trong 3 bản sao trước khi trả kết quả).
  - Ta có:
    $$R + W = 2 + 2 = 4 > \text{RF} \; (3)$$
  - Vì tổng số bản sao tham gia đọc và ghi ($4$) lớn hơn tổng số bản sao của partition ($3$), theo nguyên lý Dirichlet, tập $R$ node được đọc và tập $W$ node đã ghi **bắt buộc phải giao nhau tại ít nhất 1 node** (ví dụ nếu đọc từ `{cass2, cass3}` thì `cass2` chính là điểm giao chứa bản ghi mới nhất).
  - Khi nhận được phản hồi từ 2 node (một node cũ là `cass3` và một node mới là `cass2`), Coordinator sẽ so sánh **write timestamp** của các cell, chọn giá trị có **timestamp mới nhất** (Last-Write-Wins) để trả về cho client, đồng thời kích hoạt **Read Repair** để cập nhật cho node bị cũ.

---

### Câu 6: Hệ thống IoT chấp nhận mất vài số đo nhưng không được ngừng nhận dữ liệu. Bạn chọn mức consistency nào cho ghi, và vì sao?

- **Mức Consistency lựa chọn cho thao tác ghi (Write):** Chọn **`ONE`** (hoặc **`LOCAL_ONE`** nếu triển khai đa trung tâm dữ liệu / thậm chí **`ANY`** nếu muốn ghi vào hint ngay cả khi mọi replica của khóa đó tạm thời đều down). Trong thực tế phổ biến nhất là **`ONE`** (hoặc `LOCAL_ONE`).
- **Giải thích lý do:**
  1. **Ưu tiên tính Sẵn sàng cao nhất (Availability - chữ A trong định lý CAP):** Với `CONSISTENCY ONE` trên $\text{RF} = 3$, hệ thống vẫn tiếp tục nhận và ghi dữ liệu bình thường ngay cả khi **2 trên 3 node holding replica bị sập** (chỉ cần 1 bản sao còn sống là ghi thành công).
  2. **Độ trễ thấp & thông lượng ghi cực đại:** Coordinator chỉ cần chờ xác nhận từ 1 replica gần nhất thay vì phải chờ đa số (`QUORUM`) hay toàn bộ (`ALL`), giúp chịu tải hàng triệu bản ghi cảm biến mỗi giây.
  3. **Tự động đồng bộ nền:** Các bản sao còn lại vẫn nhận được yêu cầu ghi bất đồng bộ (hoặc qua cơ chế **Hinted Handoff** khi node sập sống lại), nên dữ liệu vẫn hội tụ về trạng thái nhất quán cuối cùng (**Eventual Consistency**), hoàn toàn phù hợp với đặc thù dữ liệu chuỗi thời gian IoT.

---

## LỜI GIẢI CÁC BÀI TẬP CUỐI BÀI (EXERCISES)

Toàn bộ mã nguồn CQL đã được lưu tại file `D:\.A-Courses\Y3\A-DB\Lab\exercises.cql` và kiểm thử trực tiếp trên cluster:

### Bài tập 1: Tạo bảng trả lời “10 đơn mới nhất của một khách hàng” và bảng thứ hai cho “đơn theo ngày”

```cql
-- 1. Bảng truy vấn 10 đơn mới nhất của một khách hàng
CREATE TABLE shop.orders_by_customer (
    customer_id text,
    order_ts    timestamp,
    order_id    uuid,
    total_price decimal,
    status      text,
    PRIMARY KEY ((customer_id), order_ts, order_id)
) WITH CLUSTERING ORDER BY (order_ts DESC, order_id ASC);

-- Truy vấn:
SELECT * FROM shop.orders_by_customer WHERE customer_id = 'cust-01' LIMIT 10;

-- 2. Bảng truy vấn đơn hàng theo ngày
CREATE TABLE shop.orders_by_day (
    order_day   date,
    order_ts    timestamp,
    order_id    uuid,
    customer_id text,
    total_price decimal,
    status      text,
    PRIMARY KEY ((order_day), order_ts, order_id)
) WITH CLUSTERING ORDER BY (order_ts DESC, order_id ASC);

-- Truy vấn:
SELECT * FROM shop.orders_by_day WHERE order_day = '2026-11-04';
```

### Bài tập 2: Thêm số đo cho 3 cảm biến và thử một truy vấn bỏ qua partition key

- Khi chạy `SELECT * FROM shop.readings_by_sensor WHERE temperature > 27;`, Cassandra trả về thông báo lỗi:
  ```text
  InvalidRequest: Error from server: code=2200 [Invalid query] message="Cannot execute this query as it might involve data filtering and thus may have unpredictable performance. If you want to execute this query despite the performance unpredictability, use ALLOW FILTERING"
  ```
- **Giải thích:** Vì `temperature` không phải là Partition Key (`sensor_id`), Cassandra không thể băm để biết dữ liệu nằm ở node nào mà buộc phải quét toàn bộ các partition trên khắp vòng ring, gây hiệu năng không đoán trước được.

### Bài tập 3: Đổi schema sang partition theo bucket tháng và giải thích vì sao

```cql
CREATE TABLE shop.readings_by_sensor_monthly (
    sensor_id   text,
    month       text,       -- Bucket theo tháng, ví dụ: '2026-10', '2026-11'
    ts          timestamp,
    temperature double,
    humidity    double,
    PRIMARY KEY ((sensor_id, month), ts)
) WITH CLUSTERING ORDER BY (ts DESC);
```
- **Giải thích vì sao cần gom bucket tháng vào Partition Key `(sensor_id, month)`:**
  - Nếu chỉ dùng `PRIMARY KEY ((sensor_id), ts)`, toàn bộ số đo của một cảm biến trong suốt nhiều năm sẽ phình to vô hạn trong **cùng một partition duy nhất** (*Unbounded Partition* / *Wide Partition*), vượt ngưỡng khuyến nghị `< 100 MB` của Cassandra.
  - Partition quá lớn làm chậm quá trình đọc/compaction, gây áp lực bộ nhớ (GC pause) và tạo điểm nóng (hotspot) trên các node giữ cảm biến đó.
  - Khi thêm `month` vào composite partition key `(sensor_id, month)`, dữ liệu của mỗi cảm biến được cắt nhỏ thành **từng partition riêng cho mỗi tháng**, giới hạn kích thước mỗi partition luôn nhỏ gọn và phân tán đều tải trên khắp vòng ring.
