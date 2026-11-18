import json
import random
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import redis

r = redis.Redis(host="localhost", port=6379, decode_responses=True)


def race(fn, n=50):
    """Run fn(i) from n threads at once and return the list of results."""
    with ThreadPoolExecutor(max_workers=n) as pool:
        return list(pool.map(fn, range(n)))



def hold_naive(event, seat, user):
    key = f"hold:{event}:{seat}"
    if r.get(key) is None:
        time.sleep(0.01)  # widen the window so the bug is easy to see
        r.set(key, user, ex=300)
        return True
    return False


def hold_nx(event, seat, user, ttl=300):
    return bool(r.set(f"hold:{event}:{seat}", user, nx=True, ex=ttl))


HOLD = r.register_script("""
if redis.call('SISMEMBER', KEYS[2], ARGV[2]) == 1 then return 0 end
if redis.call('SET', KEYS[1], ARGV[1], 'NX', 'EX', ARGV[3]) then return 1 end
return 0
""")

CONFIRM = r.register_script("""
if redis.call('GET', KEYS[1]) == ARGV[1] then
  redis.call('SADD', KEYS[2], ARGV[2])
  redis.call('DEL', KEYS[1])
  return 1
end
return 0
""")

RELEASE = r.register_script("""
if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
end
return 0
""")


def hold(event, seat, user, ttl=300):
    return bool(HOLD(keys=[f"hold:{event}:{seat}", f"sold:{event}"], args=[user, seat, ttl]))


def confirm(event, seat, user):
    return bool(CONFIRM(keys=[f"hold:{event}:{seat}", f"sold:{event}"], args=[user, seat]))


def release(event, seat, user):
    return bool(RELEASE(keys=[f"hold:{event}:{seat}"], args=[user]))


def seat_map(event, seats):
    sold = r.smembers(f"sold:{event}")
    return {
        s: "sold" if s in sold else "held" if r.exists(f"hold:{event}:{s}") else "free"
        for s in seats
    }

def buy_general(event, user):
    left = r.decr(f"stock:{event}")
    if left < 0:
        r.incr(f"stock:{event}")  # undo: nothing was left
        return False
    r.sadd(f"buyers:{event}", user)
    return True


def buy_general_naive(event, user):
    val = r.get(f"stock:{event}")
    if val is not None and int(val) > 0:
        time.sleep(0.01)
        r.decr(f"stock:{event}")
        r.sadd(f"buyers:{event}", user)
        return True
    return False


def allow_fixed(user, limit=5, window=10):
    key = f"rl:fixed:{user}:{int(time.time() // window)}"
    pipe = r.pipeline()
    pipe.incr(key)
    pipe.expire(key, window, nx=True)
    count, _ = pipe.execute()
    return count <= limit


SLIDING = r.register_script("""
local now, window, limit = tonumber(ARGV[1]), tonumber(ARGV[2]), tonumber(ARGV[3])
redis.call('ZREMRANGEBYSCORE', KEYS[1], 0, now - window)
if redis.call('ZCARD', KEYS[1]) < limit then
  redis.call('ZADD', KEYS[1], now, ARGV[4])
  redis.call('PEXPIRE', KEYS[1], window)
  return 1
end
return 0
""")


def allow_sliding(user, limit=5, window_ms=10_000):
    now = int(time.time() * 1000)
    return bool(SLIDING(keys=[f"rl:sliding:{user}"], args=[now, window_ms, limit, uuid.uuid4().hex]))


def try_hold(event, seat, user):
    if not allow_sliding(user):
        return "rate_limited"
    return "ok" if hold(event, seat, user) else "taken"


def join_queue(event, user):
    r.zadd(f"queue:{event}", {user: time.time()}, nx=True)
    return r.zrank(f"queue:{event}", user) + 1


def admit(event, n):
    return [user for user, _ in r.zpopmin(f"queue:{event}", n)]


def run_stress_test():
    r.flushdb()
    seats = [f"S{i}" for i in range(1, 21)]

    def buyer(i):
        user = f"user{i}"
        for seat in seats:
            if hold("c1", seat, user):
                time.sleep(random.random() * 0.05)  # paying
                if confirm("c1", seat, user):
                    return seat
        return None

    got = [s for s in race(buyer, n=100) if s]
    return len(got), len(set(got)), r.scard("sold:c1")


# ==============================================================================
# Exercises (1, 2, 3)
# ==============================================================================
def exercise_1_leaderboard():
    r.flushdb()
    r.zadd("board", {"linh": 1200, "nam": 950, "mai": 1430, "an": 1100, "binh": 1350})
    top3 = r.zrevrange("board", 0, 2, withscores=True)
    return [(idx + 1, player, int(score)) for idx, (player, score) in enumerate(top3)]


def exercise_2_profiles_by_city():
    r.flushdb()
    users = [
        ("u1", {"name": "Linh", "city": "Hanoi", "age": 21}),
        ("u2", {"name": "Nam", "city": "HCMC", "age": 22}),
        ("u3", {"name": "Mai", "city": "Hanoi", "age": 20}),
        ("u4", {"name": "Binh", "city": "Da Nang", "age": 23}),
    ]
    for uid, profile in users:
        r.hset(f"user:{uid}", mapping=profile)
        r.sadd(f"city:{profile['city']}", uid)
    hanoi_ids = sorted(r.smembers("city:Hanoi"))
    return {uid: r.hgetall(f"user:{uid}") for uid in hanoi_ids}


def exercise_3_cache_aside():
    r.flushdb()

    def slow_query(product_id: int) -> dict:
        time.sleep(0.05)  # simulated DB latency (50ms)
        return {"id": product_id, "title": "Python Basics", "price": 12.5}

    def get_product(product_id: int, use_cache: bool = True) -> dict:
        if not use_cache:
            return slow_query(product_id)
        key = f"product:{product_id}"
        cached = r.get(key)
        if cached is not None:
            return json.loads(cached)
        product = slow_query(product_id)
        r.set(key, json.dumps(product), ex=300)
        return product

    t0 = time.perf_counter()
    for _ in range(100):
        get_product(7, use_cache=False)
    no_cache_s = time.perf_counter() - t0

    t0 = time.perf_counter()
    for _ in range(100):
        get_product(7, use_cache=True)
    with_cache_s = time.perf_counter() - t0

    return no_cache_s, with_cache_s, no_cache_s / with_cache_s


def main():
    print("=== Step 1: Seat holds & race condition ===")
    r.flushdb()
    wins_naive = race(lambda i: hold_naive("c1", "A1", f"user{i}"))
    print("hold_naive winners (50 threads):", sum(wins_naive))

    r.flushdb()
    wins_nx = race(lambda i: hold_nx("c1", "A1", f"user{i}"))
    print("hold_nx winners (50 threads)   :", sum(wins_nx))
    print("TTL hold:c1:A1                 :", r.ttl("hold:c1:A1"))

    print("\n=== Step 2: Atomic hold, confirm, release (Lua) ===")
    r.flushdb()
    print("hold(c1, A1, linh)   :", hold("c1", "A1", "linh"))
    print("hold(c1, A1, nam)    :", hold("c1", "A1", "nam"))
    print("confirm(c1, A1, nam) :", confirm("c1", "A1", "nam"))
    print("confirm(c1, A1, linh):", confirm("c1", "A1", "linh"))
    print("hold(c1, A1, nam)    :", hold("c1", "A1", "nam"))
    print("seat_map             :", seat_map("c1", ["A1", "A2"]))
    print("SMEMBERS sold:c1     :", sorted(r.smembers("sold:c1")))

    print("\n=== Step 3: Flash sale on general admission ===")
    r.flushdb()
    r.set("stock:g1", 100)
    ok_naive = race(lambda i: buy_general_naive("g1", f"user{i}"), n=500)
    print("buy_general_naive (sold, stock, buyers):", sum(ok_naive), r.get("stock:g1"), r.scard("buyers:g1"))

    r.flushdb()
    r.set("stock:g1", 100)
    ok = race(lambda i: buy_general("g1", f"user{i}"), n=500)
    print("buy_general DECR  (sold, stock, buyers):", sum(ok), r.get("stock:g1"), r.scard("buyers:g1"))

    print("\n=== Step 4: Rate limiting ===")
    r.flushdb()
    print("allow_fixed x8:", [allow_fixed("linh") for _ in range(8)])
    sleep_s = max(0.0, 10 - time.time() % 10 - 0.2)
    time.sleep(sleep_s)
    first_f = [allow_fixed("bot_fixed") for _ in range(5)]
    time.sleep(0.4)
    second_f = [allow_fixed("bot_fixed") for _ in range(5)]
    print("fixed boundary (5 before + 5 after)  :", first_f + second_f)

    sleep_s = max(0.0, 10 - time.time() % 10 - 0.2)
    time.sleep(sleep_s)
    first_s = [allow_sliding("bot_sliding") for _ in range(5)]
    time.sleep(0.4)
    second_s = [allow_sliding("bot_sliding") for _ in range(5)]
    print("sliding boundary (5 before + 5 after):", first_s + second_s)

    print("\n=== Step 5: Virtual waiting room ===")
    r.flushdb()
    for name in ["u1", "u2", "u3"]:
        print(f"join {name} -> pos", join_queue("c1", name))
    print("re-join u1 -> pos", join_queue("c1", "u1"))
    print("admit 2          ->", admit("c1", 2))
    print("u3 new pos       ->", join_queue("c1", "u3"))

    print("\n=== Step 6: Final stress test (10 runs) ===")
    for run_idx in range(1, 11):
        res = run_stress_test()
        print(f"Run {run_idx:2d}: sold={res[0]}, distinct={res[1]}, set_card={res[2]}")
        assert res == (20, 20, 20), f"Unexpected result: {res}"

    print("\n=== Exercises 1, 2, 3 ===")
    print("Ex 1 Leaderboard:", exercise_1_leaderboard())
    print("Ex 2 Hanoi users:", exercise_2_profiles_by_city())
    no_c, with_c, speedup = exercise_3_cache_aside()
    print(f"Ex 3 Cache-aside (100 reqs): no_cache={no_c:.3f}s, with_cache={with_c:.4f}s, speedup={speedup:.1f}x")


if __name__ == "__main__":
    main()

