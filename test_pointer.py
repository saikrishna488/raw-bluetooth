"""Screen geometry checks; these do not post desktop input events."""
import unittest
from pointer import clamp_pointer


class PointerBoundsTests(unittest.TestCase):
    def test_edges_and_corners(self):
        screen = [(0, 0, 1920, 1080)]
        for point, expected in [((-500, 50), (0, 50)), ((2500, 50), (1919, 50)),
                                ((50, -500), (50, 0)), ((50, 1500), (50, 1079)),
                                ((2500, 1500), (1919, 1079))]:
            with self.subTest(point=point):
                self.assertEqual(clamp_pointer(*point, screen), expected)

    def test_repeated_outward_motion_does_not_delay_reversal(self):
        screen = [(0, 0, 1920, 1080)]
        x, y = 1910, 100
        for _ in range(100):
            x, y = clamp_pointer(x + 100, y, screen)
        self.assertEqual(clamp_pointer(x - 1, y, screen), (1918, 100))

    def test_multiple_displays_and_gaps(self):
        screens = [(0, 0, 1920, 1080), (-1280, 0, 1280, 1024), (1920, 200, 1280, 1024)]
        self.assertEqual(clamp_pointer(-10, 100, screens), (-10, 100))
        self.assertEqual(clamp_pointer(1925, 250, screens), (1925, 250))
        self.assertEqual(clamp_pointer(1930, 100, screens), (1919, 100))
        self.assertEqual(clamp_pointer(20, 30, []), (20, 30))


if __name__ == '__main__':
    unittest.main()
