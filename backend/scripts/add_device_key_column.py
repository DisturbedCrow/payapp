"""
Adds users.device_public_key_b64 (Feature B — Ed25519 device signing).

Standalone, guarded ALTER TABLE. Works against local SQLite and Postgres on
Render; re-running is a no-op. Named per the build spec; it is a thin wrapper
around scripts/add_columns.py, which applies every post-deploy column and is
what the app calls automatically at startup.

    cd backend && python -m scripts.add_device_key_column
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import text  # noqa: E402

from app.database import engine  # noqa: E402

COLUMN_SQL = "ALTER TABLE users ADD COLUMN device_public_key_b64 VARCHAR"


def add_device_key_column(verbose: bool = True) -> bool:
    """Returns True if the column was added, False if it already existed."""
    with engine.begin() as conn:
        try:
            conn.execute(text(COLUMN_SQL))
            if verbose:
                print("added users.device_public_key_b64")
            return True
        except Exception as exc:
            if verbose:
                print(f"users.device_public_key_b64 already present ({type(exc).__name__})")
            return False


if __name__ == "__main__":
    add_device_key_column()
