import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

from splatplost.generate_route import generate_route_file, get_label, load_images, manhattan_distance
from splatplost.version import __version__


class GenerateRouteTests(unittest.TestCase):
    def test_manhattan_distance(self):
        self.assertEqual(manhattan_distance((2, 4), (8, 1)), 9)

    def test_labels_only_four_connected_pixels(self):
        image = np.array([[1, 0, 1], [1, 1, 0], [0, 0, 1]], dtype=np.uint8)
        labels, count = get_label(image)
        self.assertEqual(count, 3)
        self.assertEqual(labels[0, 0], labels[1, 1])
        self.assertNotEqual(labels[0, 2], labels[2, 2])

    def test_load_images_converts_dark_pixels_to_foreground(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "input.png")
            pixels = np.full((120, 320), 255, dtype=np.uint8)
            pixels[4, 7] = 0
            Image.fromarray(pixels).save(path)
            image = load_images(str(path))
        self.assertEqual(image[4, 7], 1)
        self.assertEqual(image[0, 0], 0)

    def test_route_file_contains_gui_block_data(self):
        with tempfile.TemporaryDirectory() as directory:
            image_path = Path(directory, "input.png")
            route_path = Path(directory, "route.json")
            pixels = np.full((120, 320), 255, dtype=np.uint8)
            pixels[1, 1:4] = 0
            Image.fromarray(pixels).save(image_path)
            generate_route_file(str(image_path), str(route_path))
            route = json.loads(route_path.read_text(encoding="utf-8"))
        self.assertEqual(route["splatplost_version"], __version__)
        self.assertEqual(route["blocks"]["0"]["visit_route"], ["1,1", "1,2", "1,3"])


if __name__ == "__main__":
    unittest.main()
