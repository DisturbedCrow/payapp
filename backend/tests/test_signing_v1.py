"""
Cross-language contract for the v1 Ed25519 canonical payload (Feature B).

The Dart side asserts the identical expected string in
mobile/test/canonical_payload_test.dart. If these two files ever disagree,
every signature a real phone produces is rejected as tampered — so the vector
is duplicated on purpose, in both languages, rather than shared through a
fixture one side could silently stop reading.
"""

import base64
from datetime import datetime, timezone

from nacl.signing import SigningKey

from app.services.signing import (
    TEST_VECTOR_V1_BLOB,
    TEST_VECTOR_V1_CANONICAL,
    canonical_payload_v1,
    truncate_to_seconds,
)

EXPECTED = "v1|sender-abc|receiver-xyz|250.00|2026-09-13T10:00:00Z|nonce-0001"


def test_matches_the_shared_cross_language_vector():
    assert canonical_payload_v1(TEST_VECTOR_V1_BLOB) == EXPECTED
    assert TEST_VECTOR_V1_CANONICAL == EXPECTED


def test_blob_id_is_not_covered():
    with_id = dict(TEST_VECTOR_V1_BLOB, id="anything-at-all")
    assert canonical_payload_v1(with_id) == EXPECTED


def test_sub_second_precision_is_truncated():
    # Dart emits milliseconds, sometimes microseconds.
    for ts in (
        "2026-09-13T10:00:00Z",
        "2026-09-13T10:00:00.000Z",
        "2026-09-13T10:00:00.999Z",
        "2026-09-13T10:00:00.999999Z",
    ):
        assert canonical_payload_v1(dict(TEST_VECTOR_V1_BLOB, timestamp=ts)) == EXPECTED


def test_offset_timestamps_are_converted_to_utc():
    ist = dict(TEST_VECTOR_V1_BLOB, timestamp="2026-09-13T15:30:00.000+05:30")
    assert canonical_payload_v1(ist) == EXPECTED


def test_naive_timestamps_are_treated_as_utc():
    naive = dict(TEST_VECTOR_V1_BLOB, timestamp="2026-09-13T10:00:00")
    assert canonical_payload_v1(naive) == EXPECTED
    assert truncate_to_seconds(datetime(2026, 9, 13, 10, 0, tzinfo=timezone.utc)) == (
        "2026-09-13T10:00:00Z"
    )


def test_amount_always_two_decimals():
    for amount, want in ((200, "200.00"), (200.5, "200.50"), (0.1, "0.10")):
        got = canonical_payload_v1(dict(TEST_VECTOR_V1_BLOB, amount=amount))
        assert f"|{want}|" in got, got


def test_unparseable_timestamp_does_not_raise():
    weird = dict(TEST_VECTOR_V1_BLOB, timestamp="not-a-timestamp")
    assert "not-a-timestamp" in canonical_payload_v1(weird)


def test_a_signature_over_the_vector_round_trips():
    """The whole point: sign the canonical string, verify it back."""
    sk = SigningKey.generate()
    canonical = canonical_payload_v1(TEST_VECTOR_V1_BLOB)
    sig = sk.sign(canonical.encode()).signature
    sk.verify_key.verify(canonical.encode(), sig)

    # …and a one-rupee change must break it.
    tampered = canonical_payload_v1(dict(TEST_VECTOR_V1_BLOB, amount=251.0))
    assert tampered != canonical
    try:
        sk.verify_key.verify(tampered.encode(), sig)
        raise AssertionError("tampered payload verified — signature is not binding")
    except Exception as exc:
        assert "Signature was forged" in str(exc) or "BadSignature" in type(exc).__name__


def test_key_is_32_bytes_base64():
    sk = SigningKey.generate()
    assert len(base64.b64decode(base64.b64encode(bytes(sk.verify_key)))) == 32
