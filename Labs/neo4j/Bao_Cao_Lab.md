# BÁO CÁO THỰC HÀNH LAB: GRAPH DATABASE (NEO4J - CAMPUSGRAPH)
## TRẢ LỜI 6 CÂU HỎI BÁO CÁO

### Câu 1: Viết các bảng SQL cho bộ dữ liệu này và truy vấn SQL cho Task 2 (dùng `WITH RECURSIVE`). So sánh độ dài và độ dễ đọc với truy vấn Cypher.

- **Lược đồ các bảng SQL tương đương (5 bảng):**
  ```sql
  CREATE TABLE students (
      id   VARCHAR(10) PRIMARY KEY,
      name VARCHAR(100) NOT NULL,
      year INT NOT NULL
  );

  CREATE TABLE courses (
      code    VARCHAR(20) PRIMARY KEY,
      title   VARCHAR(200) NOT NULL,
      credits INT NOT NULL
  );

  CREATE TABLE requires (
      course_code       VARCHAR(20) REFERENCES courses(code),
      prerequisite_code VARCHAR(20) REFERENCES courses(code),
      PRIMARY KEY (course_code, prerequisite_code)
  );

  CREATE TABLE passed (
      student_id  VARCHAR(10) REFERENCES students(id),
      course_code VARCHAR(20) REFERENCES courses(code),
      grade       NUMERIC(3,1) NOT NULL,
      PRIMARY KEY (student_id, course_code)
  );

  CREATE TABLE friends (
      student_a VARCHAR(10) REFERENCES students(id),
      student_b VARCHAR(10) REFERENCES students(id),
      PRIMARY KEY (student_a, student_b),
      CHECK (student_a < student_b)
  );
  ```

- **Truy vấn SQL cho Task 2 (`prerequisite_chain`) dùng `WITH RECURSIVE`:**
  ```sql
  WITH RECURSIVE prereq_paths AS (
      -- Bước cơ sở (depth = 1): tiên quyết trực tiếp
      SELECT r.prerequisite_code AS code, 1 AS depth
      FROM requires r
      WHERE r.course_code = 'CAP401'

      UNION ALL

      -- Bước đệ quy (depth + 1): tiên quyết của tiên quyết
      SELECT r.prerequisite_code AS code, p.depth + 1 AS depth
      FROM prereq_paths p
      JOIN requires r ON r.course_code = p.code
  )
  SELECT code, MIN(depth) AS depth
  FROM prereq_paths
  GROUP BY code
  ORDER BY depth ASC, code ASC;
  ```

- **So sánh với Cypher:**
  - **Độ dài:** SQL cần **18 dòng** (gồm khối `WITH RECURSIVE`, phần base case, `UNION ALL`, phép `JOIN` đệ quy, và truy vấn ngoài `GROUP BY`), trong khi Cypher chỉ cần **3 dòng**:
    ```cypher
    MATCH path = (:Course {code: $code})-[:REQUIRES*1..]->(p:Course)
    RETURN p.code AS code, min(length(path)) AS depth
    ORDER BY depth ASC, code ASC
    ```
  - **Độ dễ đọc:** Mẫu ASCII `-[:REQUIRES*1..]->` trong Cypher thể hiện trực tiếp ý nghĩa đồ thị ("đi theo chuỗi cạnh `REQUIRES` từ 1 bước trở lên"), không cần tự viết bảng tạm đệ quy hay nối bảng trung gian như SQL.

---

### Câu 2: Ở Task 2, vì sao truy vấn chỉ trả về mỗi môn tiên quyết một lần sau khi tổng hợp? Có bao nhiêu đường đi từ `CAP401` tới `CS101`?

- **Vì sao mỗi môn tiên quyết chỉ xuất hiện đúng 1 lần:**
  Trong Cypher, khi mệnh đề `RETURN` có hàm tổng hợp (`min(length(path))`), Neo4j **tự động nhóm (`GROUP BY` ngầm định)** theo tất cả các biểu thức không tổng hợp còn lại trong `RETURN` — ở đây chính là `p.code AS code`. Nhờ đó, dù có nhiều đường đi khác nhau dẫn tới cùng một môn `p`, tất cả các đường đi đó được gom vào một nhóm duy nhất ứng với `p.code` và lấy độ dài đường đi nhỏ nhất `min(length(path))`.
- **Số đường đi từ `CAP401` tới `CS101`:**
  Khi chạy truy vấn không tổng hợp:
  ```cypher
  MATCH path = (:Course {code: "CAP401"})-[:REQUIRES*1..]->(:Course {code: "CS101"})
  RETURN [n IN nodes(path) | n.code] AS route, length(path) AS hops;
  ```
  Kết quả trả về **2 đường đi**:
  1. `["CAP401", "ML201", "CS102", "CS101"]` — độ sâu `3` bước (`hops = 3`).
  2. `["CAP401", "DB301", "DB201", "CS102", "CS101"]` — độ sâu `4` bước (`hops = 4`).
  Sau khi tổng hợp bằng `min(length(path))`, `CS101` được trả về 1 lần với `depth = min(3, 4) = 3`.

---

### Câu 3: Ở Bước 8, operator đầu tiên khi có và không có constraint là gì, và bao nhiêu `db hits`? Điều gì sẽ xảy ra với 100.000 sinh viên?

- **So sánh thực nghiệm ở Bước 8 (trên 10 sinh viên):**

  | Tiêu chí | Có constraint `student_id` | Không có constraint `student_id` |
  | :--- | :--- | :--- |
  | **Operator tìm `:Student {id: 'S01'}`** | `NodeUniqueIndexSeek` | `NodeByLabelScan` $\rightarrow$ `Filter` |
  | **`dbHits` tại bước tìm `:Student`** | **$2$** (`rows = 1`) | **$11 + 10 = 21$** (`rows = 10` $\rightarrow$ `1`) |
  | **Tổng `dbHits` toàn truy vấn** | **$237$** | **$256$** |

- **Điều gì xảy ra khi có $100.000$ sinh viên:**
  - **Không có constraint:** `NodeByLabelScan` phải quét qua toàn bộ $100.000$ node `:Student` ($\approx 100.001\text{ dbHits}$) rồi `Filter` đọc thuộc tính `id` của từng node ($\approx 100.000\text{ dbHits}$), tức tốn hơn **$200.000\text{ dbHits}$** chỉ để tìm 1 sinh viên — độ phức tạp tăng tuyến tính **$O(N)$**.
  - **Có constraint (`IS UNIQUE`):** Neo4j tự động duy trì Range/B-tree Index trên `(:Student).id`. Operator `NodeUniqueIndexSeek` nhảy thẳng tới node `'S01'` với độ phức tạp **$O(\log N)$** (chỉ tốn khoảng $3\text{–}4\text{ dbHits}$), còn phần kiểm tra 13 môn học phía sau nhờ **index-free adjacency** giữ nguyên chi phí không đổi.

---

### Câu 4: Vì sao `FRIEND` chỉ được lưu theo một chiều? Điều gì sẽ sai ở Task 4 và Task 5 nếu bạn lưu cả hai chiều mà giữ nguyên truy vấn?

- **Vì sao `FRIEND` chỉ lưu 1 chiều:**
  Trong Neo4j, mỗi relationship vật lý đều lưu con trỏ hai chiều ở tầng lưu trữ, nên việc duyệt không có mũi tên `(a)-[:FRIEND]-(b)` nhanh ngang ngửa với duyệt có mũi tên `(a)-[:FRIEND]->(b)`. Lưu 1 chiều giúp tiết kiệm một nửa dung lượng cạnh, tránh phải ghi/xoá kép và loại bỏ nguy cơ dữ liệu bất nhất (có `A -> B` nhưng quên `B -> A`).
- **Nếu lưu `FRIEND` cả hai chiều (`(a)-[:FRIEND]->(b)` VÀ `(b)-[:FRIEND]->(a)`) mà giữ nguyên truy vấn:**
  1. **Ở Task 4 (`suggest_friends`) và Task 5 (`connection`) hiện tại:**
     - Task 4 dùng `WHERE NOT (s)-[:FRIEND]-(other)` và đếm trên `:PASSED`: bản thân điều kiện phủ định `NOT (s)-[:FRIEND]-(other)` vẫn đúng, **nhưng** nếu truy vấn đếm số bạn chung `(s)-[:FRIEND]-(mf)-[:FRIEND]-(other)` mà không `DISTINCT` hoặc không định hướng thì mỗi người bạn chung sẽ bị **đếm gấp 4 lần** ($2 \times 2$ cạnh).
     - Ở Task 5 (`connection`), `shortestPath((a)-[:FRIEND*]-(b))` tìm 1 đường ngắn nhất nên độ dài không đổi, nhưng nếu dùng `MATCH (a)-[:FRIEND*1..k]-(b)` hoặc `allShortestPaths`, số lượng đường đi giữa hai sinh viên cách nhau $L$ bước sẽ **bùng nổ gấp $2^L$ lần** (vì mỗi bước nhảy có 2 cạnh song song ngược chiều nhau).

---

### Câu 5: Trường muốn lưu mọi lần học một môn (sinh viên có thể trượt và học lại, ở các học kỳ khác nhau). Hãy thiết kế lại mô hình: điểm vẫn nằm trên relationship, hay cần một node `:Enrollment`? Vẽ mô hình mới và viết lại truy vấn Task 1 cho nó.

- **Lựa chọn thiết kế:**
  Nếu một sinh viên học lại một môn ở nhiều học kỳ (kèm học kỳ `term`, năm học `year`, điểm `grade`, trạng thái `passed`, giảng viên...), thông tin lần học đã trở thành một thực thể có nhiều thuộc tính và có thể liên kết tới các node khác (như `:Semester` hoặc `:ClassSection`). Do đó, **nên tách thành node trung gian `:Enrollment`** (thay vì nhồi nhiều relationship cùng loại `PASSED`/`ATTEMPTED` giữa 2 node).

- **Sơ đồ mô hình mới:**
  ```mermaid
  flowchart LR
      S["(:Student {id, name, year})"] -->|":ENROLLED_IN"| E["(:Enrollment {term, grade, status})"]
      E -->|":FOR_COURSE"| C["(:Course {code, title, credits})"]
  ```

- **Truy vấn Task 1 viết lại trên mô hình `:Enrollment`** *(lấy điểm cao nhất của mỗi môn mà sinh viên đã qua)*:
  ```cypher
  MATCH (:Student {id: $sid})-[:ENROLLED_IN]->(e:Enrollment)-[:FOR_COURSE]->(c:Course)
  WHERE e.status = 'PASSED' OR e.grade >= 5.0
  RETURN c.code AS code, max(e.grade) AS grade
  ORDER BY grade DESC, code ASC
  ```

---

### Câu 6: Ở Task 7, điều gì sẽ sai nếu bước kiểm tra tiên quyết và bước ghi chạy trong hai lời gọi `execute_query` riêng, trong khi một chương trình khác đang xoá các relationship `PASSED` cùng lúc?

- **Hiện tượng lỗi (Race Condition / Time-Of-Check to Time-Of-Use - TOCTOU):**
  Mỗi lời gọi `driver.execute_query(...)` mở và đóng **một transaction độc lập**. Nếu tách thành 2 lần gọi:
  1. **Transaction A1 (Kiểm tra):** Kiểm tra thấy sinh viên `S01` đã có `(:Student {id:'S01'})-[:PASSED]->(:Course {code:'DB201'})` $\rightarrow$ hợp lệ để học `DB301`. Transaction A1 kết thúc.
  2. **Transaction B (Chạy đồng thời ở tiến trình khác):** Xoá relationship `PASSED` của `S01` với môn `DB201` (ví dụ do huỷ kết quả thi hoặc nhập nhầm) và commit.
  3. **Transaction A2 (Ghi):** Chạy `MERGE (s)-[:PASSED]->(:Course {code:'DB301'})` và commit thành công.
- **Hậu quả:** Cơ sở dữ liệu rơi vào trạng thái **vi phạm toàn vẹn nghiệp vụ (Write Skew / Inconsistent State)**: sinh viên `S01` được ghi nhận đã qua `DB301` trong khi môn tiên quyết bắt buộc `DB201` đã bị xoá! Khi gộp cả bước kiểm tra và bước ghi vào chung một hàm `_record_pass_tx` chạy qua `session.execute_write`, tất cả thực thi trong **cùng một ACID transaction** (và driver có thể tự động retry an toàn toàn bộ hàm nếu gặp xung đột khóa/deadlock).

---
