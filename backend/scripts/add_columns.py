"""
Lightweight forward-only column migration.

SQLAlchemy's create_all() creates missing TABLES but never adds COLUMNS to a
table that already exists, so every column added after the first deploy is
listed here and applied with a guarded ALTER TABLE. Works on both local SQLite
and Postgres on Render; re-running is a no-op.

    python -m scripts.add_columns        # from backend/

It is also called automatically on app startup (app/main.py).

# PROD-TODO: replace with Alembic migrations.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import text  # noqa: E402

from app.database import engine  # noqa: E402

# (table, column, SQL type)
COLUMNS = [
    ("transactions", "synced_by", "VARCHAR"),
    ("transactions", "confirmed_by", "VARCHAR"),
    ("users", "device_public_key_b64", "VARCHAR"),
]


def ensure_columns(verbose: bool = True) -> None:
    with engine.begin() as conn:
        for table, column, sqltype in COLUMNS:
            try:
                conn.execute(text(f"ALTER TABLE {table} ADD COLUMN {column} {sqltype}"))
                if verbose:
                    print(f"added {table}.{column}")
            except Exception as exc:  # column already exists (SQLite + Postgres)
                if verbose:
                    print(f"{table}.{column}: already present ({type(exc).__name__})")


if __name__ == "__main__":
    ensure_columns()
