#!/usr/bin/env python3
"""Render and print a small Chinese Todo example on a Paperang P1."""

from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from p1_driver import P1_DEFAULT_POST_PRINT_FEED_LINES, P1_WIDTH_DOTS, PaperangP1


FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"


def font(size: int):
    return ImageFont.truetype(FONT, size=size, index=0)


def render_todo_raster() -> bytes:
    width = P1_WIDTH_DOTS
    height = 430
    image = Image.new("L", (width, height), 255)
    draw = ImageDraw.Draw(image)
    margin = 24

    title_font = font(30)
    small_font = font(16)
    body_font = font(21)

    draw.text((margin, 18), "今日慢慢来", font=title_font, fill=0)
    draw.text((margin, 58), "2026.07.17  ·  星期五", font=small_font, fill=0)
    draw.line((margin, 89, width - margin, 89), fill=0, width=2)

    tasks = [
        "喝一杯温水",
        "完成 Todo 打印测试",
        "给自己留十分钟发呆",
        "整理桌面的一小角",
        "早点休息",
    ]
    y = 112
    for task in tasks:
        draw.rectangle((margin, y + 3, margin + 22, y + 25), outline=0, width=2)
        draw.text((margin + 38, y), task, font=body_font, fill=0)
        y += 52

    draw.line((margin, height - 36, width - margin, height - 36), fill=0, width=1)
    draw.text((margin, height - 29), "完成一件，就给自己一个小小的勾。", font=small_font, fill=0)

    # P1 raster polarity: 1=black, packed MSB-first, 384 dots per row.
    thresholded = image.point(lambda value: 0 if value < 180 else 255, mode="1")
    pixels = thresholded.load()
    raster = bytearray()
    for row in range(height):
        for byte_offset in range(0, width, 8):
            value = 0
            for bit in range(8):
                if pixels[byte_offset + bit, row] == 0:
                    value |= 1 << (7 - bit)
            raster.append(value)
    return bytes(raster)


async def print_example(address: str, feed_lines: int) -> None:
    printer = PaperangP1(address)
    try:
        await printer.connect()
        await printer.print_raster(render_todo_raster(), feed_lines=feed_lines)
    finally:
        await printer.disconnect()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--address", required=True)
    parser.add_argument("--feed-lines", type=int, default=P1_DEFAULT_POST_PRINT_FEED_LINES)
    parser.add_argument("--save-raster", type=Path)
    args = parser.parse_args()
    raster = render_todo_raster()
    if args.save_raster:
        args.save_raster.write_bytes(raster)
    asyncio.run(print_example(args.address, args.feed_lines))
    print(f"printed todo example: {len(raster)} raster bytes, feed={args.feed_lines}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
