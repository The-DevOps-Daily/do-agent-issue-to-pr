"""Parse human-friendly durations such as "90s", "15m" or "1h30m" into seconds."""

import re

_UNITS = {"s": 1, "m": 60, "h": 3600}
_PART = re.compile(r"(\d+)([smh])")


def parse_duration(text: str) -> int:
    """Return the number of seconds in a duration string like "1h30m"."""
    text = text.strip().lower()
    if not text:
        raise ValueError("empty duration")
    parts = _PART.findall(text)
    if not parts:
        raise ValueError(f"not a duration: {text!r}")
    total = 0
    for value, unit in parts:
        total = int(value) * _UNITS[unit]
    return total
