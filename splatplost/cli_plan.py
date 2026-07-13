import argparse
from typing import Optional, Union

import numpy as np
import tqdm

from . import __version__
from .generate_route import (
    ResetPosition,
    divide_image,
    find_nearest_reset_position,
    generate_block_visit,
    generate_order_file,
    load_images,
    summarize_difficulties,
)


def create_plan(input_file: str, output_file: str) -> None:
    image = load_images(input_file)
    divided_image = divide_image(image)
    visit_list: list[Union[ResetPosition, np.ndarray]] = []
    for image_offset, image_block in tqdm.tqdm(divided_image, desc="Blocks to be visited"):
        visit_list += generate_block_visit(image_block, np.array(image_offset))
        if not visit_list or isinstance(visit_list[-1], ResetPosition):
            continue
        visit_list.append(find_nearest_reset_position(visit_list[-1]))
    generate_order_file(visit_list, output_file)
    summarize_difficulties(image, output_file)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Generate instructions for plotting.")
    parser.add_argument("-o", "--output", required=True, help="Output instruction filename.")
    parser.add_argument("-i", "--input", required=True, help="Input image (320 x 120 pixels).")
    parser.add_argument("-V", "--version", action="version", version=f"%(prog)s {__version__}")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    create_plan(args.input, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
