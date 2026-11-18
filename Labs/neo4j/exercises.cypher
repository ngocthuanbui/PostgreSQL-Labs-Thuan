// ============================================================================
// BÀI TẬP THỰC HÀNH & MỞ RỘNG CYPHER - GRAPH DATABASE (NEO4J)
// ============================================================================

// ----------------------------------------------------------------------------
// PHẦN A: BƯỚC 8 - PROFILE QUERY PLAN (TASK 3 VỚI "S01")
// ----------------------------------------------------------------------------

// 1. Khi CÓ Unique Constraint student_id (NodeUniqueIndexSeek, total dbHits = 237):
PROFILE
MATCH (s:Student {id: "S01"}), (c:Course)
WHERE NOT (s)-[:PASSED]->(c)
  AND NOT EXISTS {
    MATCH (c)-[:REQUIRES]->(pre:Course)
    WHERE NOT (s)-[:PASSED]->(pre)
  }
RETURN c.code AS code
ORDER BY code ASC;

// 2. Xoá constraint để kiểm chứng NodeByLabelScan + Filter (total dbHits = 256):
DROP CONSTRAINT student_id IF EXISTS;

PROFILE
MATCH (s:Student {id: "S01"}), (c:Course)
WHERE NOT (s)-[:PASSED]->(c)
  AND NOT EXISTS {
    MATCH (c)-[:REQUIRES]->(pre:Course)
    WHERE NOT (s)-[:PASSED]->(pre)
  }
RETURN c.code AS code
ORDER BY code ASC;

// 3. Tạo lại constraint:
CREATE CONSTRAINT student_id IF NOT EXISTS FOR (s:Student) REQUIRE s.id IS UNIQUE;


// ----------------------------------------------------------------------------
// PHẦN B: KIỂM CHỨNG CÂU HỎI BÁO CÁO SỐ 2 (ĐƯỜNG ĐI TỪ CAP401 TỚI CS101)
// ----------------------------------------------------------------------------
// Liệt kê mọi đường đi không tổng hợp từ CAP401 tới CS101 (kết quả: 2 đường đi):
MATCH path = (:Course {code: "CAP401"})-[:REQUIRES*1..]->(:Course {code: "CS101"})
RETURN [n IN nodes(path) | n.code] AS route, length(path) AS hops
ORDER BY hops ASC;


// ----------------------------------------------------------------------------
// PHẦN C: 4 BÀI TẬP MỞ RỘNG (EXTENSIONS - CAMPUSGRAPH)
// ----------------------------------------------------------------------------

// Mở rộng 1: credits_to_reach(student_id, code)
// Tính tổng số tín chỉ của mọi môn tiên quyết (trực tiếp & gián tiếp) mà sinh viên còn phải học:
MATCH (:Course {code: $code})-[:REQUIRES*1..]->(pre:Course)
WITH DISTINCT pre
MATCH (s:Student {id: $sid})
WHERE NOT (s)-[:PASSED]->(pre)
RETURN coalesce(sum(pre.credits), 0) AS remaining_credits;

// Mở rộng 2: Phát hiện chu trình môn tiên quyết (Cycle Detection)
// Thêm thử cạnh tạo chu trình:
MATCH (a:Course {code: "MATH101"}), (b:Course {code: "ML201"})
MERGE (a)-[:REQUIRES]->(b);

// Tìm các môn học tự phụ thuộc vào chính nó (nằm trong chu trình):
MATCH path = (c:Course)-[:REQUIRES*1..]->(c)
RETURN DISTINCT c.code AS cycle_course, [n IN nodes(path) | n.code] AS cycle_path;

// Xoá cạnh sai sau khi kiểm tra:
MATCH (:Course {code: "MATH101"})-[r:REQUIRES]->(:Course {code: "ML201"})
DELETE r;

// Mở rộng 3: Gợi ý kết bạn có trọng số (shared_courses + 2 * mutual_friends)
MATCH (s:Student {id: $sid}), (other:Student)
WHERE other <> s AND NOT (s)-[:FRIEND]-(other)
OPTIONAL MATCH (s)-[:PASSED]->(c:Course)<-[:PASSED]-(other)
WITH s, other, count(DISTINCT c) AS shared_courses
OPTIONAL MATCH (s)-[:FRIEND]-(mf:Student)-[:FRIEND]-(other)
WITH other, shared_courses, count(DISTINCT mf) AS mutual_friends
WITH other.name AS name,
     shared_courses,
     mutual_friends,
     (shared_courses + 2 * mutual_friends) AS score
WHERE score > 0
RETURN name, shared_courses, mutual_friends, score
ORDER BY score DESC, name ASC
LIMIT $k;


// ----------------------------------------------------------------------------
// PHẦN D: 5 BÀI TẬP CUỐI BÀI HỌC (BOOKSTORE, METRO, WORK HISTORY, PROFILE)
// ----------------------------------------------------------------------------

// Bài tập 1: Thêm 5 người và quan hệ bạn bè vào đồ thị cửa hàng,
// rồi tìm bạn của bạn (2 bước) của Linh đang sống ở Hà Nội.
UNWIND [
  {name: "Linh", city: "Hanoi", age: 21},
  {name: "Mai",  city: "Hanoi", age: 22},
  {name: "Nam",  city: "Danang", age: 23},
  {name: "Oanh", city: "Hanoi", age: 20},
  {name: "Phuc", city: "HCMC",  age: 24},
  {name: "Quang", city: "Hanoi", age: 22},
  {name: "Trang", city: "Hanoi", age: 21}
] AS row
MERGE (p:Person {name: row.name})
SET p.city = row.city, p.age = row.age;

UNWIND [
  ["Linh", "Mai"], ["Linh", "Nam"],
  ["Mai", "Oanh"], ["Nam", "Quang"], ["Nam", "Phuc"], ["Oanh", "Trang"]
] AS pair
MATCH (a:Person {name: pair[0]}), (b:Person {name: pair[1]})
MERGE (a)-[:FRIEND]->(b);

// Tìm bạn của bạn của Linh đang sống ở Hà Nội (không phải Linh và chưa là bạn trực tiếp của Linh):
MATCH (linh:Person {name: "Linh"})-[:FRIEND]-(:Person)-[:FRIEND]-(fof:Person)
WHERE fof <> linh
  AND NOT (linh)-[:FRIEND]-(fof)
  AND fof.city = "Hanoi"
RETURN DISTINCT fof.name AS friend_of_friend, fof.city AS city
ORDER BY friend_of_friend;


// Bài tập 2: Truy vấn gợi ý sách cho Mai (sách bạn bè của Mai đã mua nhưng Mai chưa mua)
// và truy vấn liệt kê tổng số tiền mỗi người đã chi.
UNWIND [
  {title: "Designing Data-Intensive Applications", price: 45},
  {title: "Graph Databases", price: 35},
  {title: "Database Internals", price: 50}
] AS b
MERGE (bk:Book {title: b.title}) SET bk.price = b.price;

MATCH (linh:Person {name: "Linh"}), (oanh:Person {name: "Oanh"}), (mai:Person {name: "Mai"})
MATCH (b1:Book {title: "Designing Data-Intensive Applications"}),
      (b2:Book {title: "Graph Databases"}),
      (b3:Book {title: "Database Internals"})
MERGE (linh)-[:BOUGHT {pricePaid: 45}]->(b1)
MERGE (linh)-[:BOUGHT {pricePaid: 35}]->(b2)
MERGE (oanh)-[:BOUGHT {pricePaid: 35}]->(b2)
MERGE (oanh)-[:BOUGHT {pricePaid: 50}]->(b3)
MERGE (mai)-[:BOUGHT  {pricePaid: 45}]->(b1);

// 2a) Gợi ý sách cho Mai:
MATCH (mai:Person {name: "Mai"})-[:FRIEND]-(friend:Person)-[:BOUGHT]->(book:Book)
WHERE NOT (mai)-[:BOUGHT]->(book)
RETURN book.title AS recommended_book, count(DISTINCT friend) AS friend_buyers
ORDER BY friend_buyers DESC, recommended_book ASC;

// 2b) Tổng số tiền mỗi người đã chi:
MATCH (p:Person)
OPTIONAL MATCH (p)-[r:BOUGHT]->(b:Book)
RETURN p.name AS person, coalesce(sum(coalesce(r.pricePaid, b.price)), 0) AS total_spent
ORDER BY total_spent DESC, person ASC;


// Bài tập 3: Mô hình hoá mạng Metro với :Station và :NEXT {minutes: 3},
// tìm tuyến đi qua ít ga nhất giữa hai ga.
UNWIND ["Cat Linh", "La Thanh", "Thai Ha", "Lang", "Thuong Dinh", "Vanh Dai 3", "Ha Dong"] AS st
MERGE (:Station {name: st});

UNWIND [
  ["Cat Linh", "La Thanh", 3],
  ["La Thanh", "Thai Ha", 3],
  ["Thai Ha", "Lang", 3],
  ["Lang", "Thuong Dinh", 3],
  ["Thuong Dinh", "Vanh Dai 3", 3],
  ["Vanh Dai 3", "Ha Dong", 4]
] AS seg
MATCH (a:Station {name: seg[0]}), (b:Station {name: seg[1]})
MERGE (a)-[:NEXT {minutes: seg[2]}]->(b);

MATCH (start:Station {name: "Cat Linh"}), (dest:Station {name: "Ha Dong"}),
      path = shortestPath((start)-[:NEXT*]-(dest))
RETURN [s IN nodes(path) | s.name] AS stations,
       length(path) AS stops,
       reduce(total = 0, r IN relationships(path) | total + r.minutes) AS total_minutes;


// Bài tập 4: Mô hình hoá lịch sử làm việc theo 2 cách
// Cách 1: Property trên relationship (:Person)-[:WORKED_AT {role, startDate, endDate}]->(:Company)
MERGE (p:Person {name: "Linh"})
MERGE (c:Company {name: "FPT Software"})
MERGE (p)-[:WORKED_AT {role: "Data Engineer", startDate: date("2025-01-01"), endDate: date("2026-06-30")}]->(c);

// Cách 2: Node trung gian (:Person)-[:HELD]->(:Position {role, startDate, endDate})-[:AT]->(:Company)
MERGE (p:Person {name: "Linh"})
MERGE (c:Company {name: "FPT Software"})
MERGE (pos:Position {role: "Data Engineer", startDate: date("2025-01-01")})
SET pos.endDate = date("2026-06-30")
MERGE (p)-[:HELD]->(pos)
MERGE (pos)-[:AT]->(c);


// Bài tập 5: Chạy PROFILE cho MATCH (p:Person {name: "Linh"}) RETURN p trước và sau khi tạo Uniqueness Constraint
DROP CONSTRAINT person_name IF EXISTS;
PROFILE MATCH (p:Person {name: "Linh"}) RETURN p;

CREATE CONSTRAINT person_name IF NOT EXISTS FOR (p:Person) REQUIRE p.name IS UNIQUE;
PROFILE MATCH (p:Person {name: "Linh"}) RETURN p;
