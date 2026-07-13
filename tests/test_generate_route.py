import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

from splatplost.generate_route import (
    generate_block_visit,
    generate_order_file,
    get_label,
    load_images,
    manhattan_distance,
)


class GenerateRouteTests(unittest.TestCase):
    def test_manhattan_distance(self):
        self.assertEqual(manhattan_distance((2, 4), (8, 1)), 9)

    def test_labels_only_four_connected_pixels(self):
        image = np.array(
            [
                [1, 0, 1],
                [1, 1, 0],
                [0, 0, 1],
            ],
            dtype=np.uint8,
        )
        labels, count = get_label(image)
        self.assertEqual(count, 3)
        self.assertEqual(labels[0, 0], labels[1, 1])
        self.assertNotEqual(labels[0, 2], labels[2, 2])

    def test_load_images_converts_dark_pixels_to_foreground(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "input.png")
            pixels = np.full((120, 320), 255, dtype=np.uint8)
            pixels[4, 7] = 0
            Image.fromarray(pixels, mode="L").save(path)
            image = load_images(str(path))
        self.assertEqual(image.shape, (120, 320))
        self.assertEqual(image[4, 7], 1)
        self.assertEqual(image[0, 0], 0)

    def test_block_visit_covers_each_foreground_pixel(self):
        image = np.zeros((40, 40), dtype=np.uint8)
        image[1, 1:4] = 1
        image[8:10, 6] = 1
        route = generate_block_visit(image, np.array((40, 80)))
        self.assertEqual(
            {tuple(point) for point in route},
            {(41, 81), (41, 82), (41, 83), (48, 86), (49, 86)},
        )

    def test_order_files_use_platform_independent_newlines(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "order.txt")
            generate_order_file([np.array((0, 1)), np.array((1, 1))], path)
            self.assertEqual(path.read_bytes(), b"right\na\ndown\na")


if __name__ == "__main__":
    unittest.main()
