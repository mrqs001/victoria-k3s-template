import os
import random
import time

import requests


TARGET_URL = os.getenv("LOADGEN_TARGET_URL", "http://checkout-api:8000/api/checkout")
INTERVAL = float(os.getenv("LOADGEN_INTERVAL_SECONDS", "0.5"))


def pick_mode() -> str:
    value = random.random()
    if value < 0.7:
        return "ok"
    if value < 0.9:
        return "slow"
    return "fail_inventory"


def main() -> None:
    while True:
        mode = pick_mode()
        payload = {
            "user_id": f"demo-user-{random.randint(1, 20)}",
            "sku": random.choice(["sku-1", "sku-2", "sku-3"]),
            "quantity": 1,
            "mode": mode,
        }
        try:
            response = requests.post(TARGET_URL, json=payload, timeout=10)
            print(f"mode={mode} status={response.status_code} body={response.text}")
        except Exception as exc:
            print(f"loadgen_error={exc}")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
