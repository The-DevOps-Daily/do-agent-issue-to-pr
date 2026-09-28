import unittest

from durations import parse_duration


class ParseDurationTest(unittest.TestCase):
    def test_seconds(self):
        self.assertEqual(parse_duration("90s"), 90)

    def test_minutes(self):
        self.assertEqual(parse_duration("15m"), 900)

    def test_hours(self):
        self.assertEqual(parse_duration("2h"), 7200)

    def test_combined_hours_minutes(self):
        self.assertEqual(parse_duration("1h30m"), 5400)

    def test_combined_hours_minutes_seconds(self):
        self.assertEqual(parse_duration("2h15m30s"), 8130)

    def test_empty(self):
        with self.assertRaises(ValueError):
            parse_duration("  ")


if __name__ == "__main__":
    unittest.main()
