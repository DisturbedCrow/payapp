"""
Stable IDs for the demo-day cast.

The Flutter app ships an offline contact map for voice payments
(AppConstants.demoContacts) and needs to know Ramesh's user id without a
network round-trip, so the seed script derives the demo accounts' ids from
their e-mail with uuid5 instead of random uuid4. Any database seeded with
seed.py — laptop SQLite or Postgres on Render — yields the same ids.
"""

import uuid

_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://setupay.demo/users")


def demo_user_id(email: str) -> str:
    return str(uuid.uuid5(_NAMESPACE, email.strip().lower()))


if __name__ == "__main__":
    for email in ("vivek@demo.com", "ramesh@demo.com", "attacker@demo.com"):
        print(f"{email:<20} {demo_user_id(email)}")
