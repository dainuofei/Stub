#!/usr/bin/env python3
"""Paperang P1 BLE driver derived from a known-good official iOS capture.

这份 Python 实现是 Swift 驱动的可读参考版本，便于在 GitHub 上复核协议。
它不是通过官方 SDK 调用打印，而是复现官方 App 已验证的 BLE 字节流。

P1 传输由三层组成，不能混为一谈：

* 协议帧：02 command sequence length payload crc32 03
* FF02 字节流：按打印机声明的 100 字节写入块分组
* FF03 credit 通知：授权后续写入

忽略 FF03 credit 可能导致控制/走纸命令正常，但大部分图像字节被静默丢弃，
最终表现为纸张移动而打印头空白。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import secrets
import struct
import sys
import zlib
from dataclasses import asdict, dataclass
from typing import Iterable

from bleak import BleakClient, BleakScanner


P1_NAME = "Paperang"
P1_WIDTH_DOTS = 384
P1_BYTES_PER_ROW = P1_WIDTH_DOTS // 8
P1_ROWS_PER_PACKET = 21
P1_PRINT_PAYLOAD_BYTES = P1_BYTES_PER_ROW * P1_ROWS_PER_PACKET
# FF03 抓包显示的 0x02 协商结果为 100；每个 FF02 写入不能超过这个大小。
P1_CAPTURED_BLE_CHUNK_BYTES = 100
# P1 走纸命令约使用 56 units/mm；官方 App 抓到的最终走纸是 280 units（约 5 mm），
# 用于在裁切位置前留下安全余量。
P1_FEED_UNITS_PER_MM = 56
P1_DEFAULT_POST_PRINT_FEED_MM = 5.0
P1_DEFAULT_POST_PRINT_FEED_LINES = int(P1_DEFAULT_POST_PRINT_FEED_MM * P1_FEED_UNITS_PER_MM)

P1_FF01_NOTIFY = "0000ff01-0000-1000-8000-00805f9b34fb"
P1_FF02_WRITE = "0000ff02-0000-1000-8000-00805f9b34fb"
P1_FF03_FLOW_NOTIFY = "0000ff03-0000-1000-8000-00805f9b34fb"
P1_1E4D_NOTIFY = "49535343-1e4d-4bd9-ba61-23c647249616"

P1_STANDARD_CRC_KEY = 0x35769521

# 这段 33 字节前导包由官方 App 在 P1 帧初始化前发送。
# 它是从日志捕获的协议常量，不是账号凭据；CLI 允许替换它以验证未来的抓包结果。
P1_CAPTURED_AUTH_PACKET = bytes.fromhex(
    "a50118000117011300011000335364584e3362593271546d6f6a7a7a10cbe4775a"
)

PRT_PRINT_DATA = 0x00
PRT_SET_CRC_KEY = 0x18
PRT_SET_HEAT_DENSITY = 0x19
PRT_FEED_LINE = 0x1A
PRT_SET_PAPER_TYPE = 0x2C
PRT_SET_PRINT_MODE = 0x39

INITIALIZATION_COMMANDS = (
    (0x0A, b"\x01"),
    (0x30, b"\x01"),
    (0x1C, b"\x01"),
    (0x10, b"\x01"),
    (0x1F, b"\x01"),
    (0x04, b"\x01"),
)

REPLY_COMMAND = {
    0x0A: 0x0B,
    0x30: 0x31,
    0x1C: 0x1D,
    0x10: 0x11,
    0x1F: 0x20,
    0x04: 0x05,
}

FRAME_OVERHEAD = 10


@dataclass(frozen=True)
class P1Frame:
    command: int
    index: int
    payload: bytes
    crc: int


@dataclass(frozen=True)
class DryRunReport:
    profile: str
    write_characteristic: str
    reply_characteristic: str
    flow_characteristic: str
    width_dots: int
    bytes_per_row: int
    black_rows: int
    blank_rows: int
    raster_bytes: int
    image_protocol_frames: int
    negotiated_ble_chunk_bytes: int
    initialization_writes: int
    print_writes: int
    feed_lines: int
    flow_control_required: bool


def crc32(payload: bytes, seed: int) -> int:
    """计算带 session seed 的 P1 CRC32，而不是无 seed 的普通 CRC32。"""
    return zlib.crc32(payload, seed) & 0xFFFFFFFF


def pack_frame(command: int, index: int, payload: bytes, seed: int) -> bytes:
    # P1 帧：02 起始、命令、序号、little-endian payload 长度、payload、
    # little-endian CRC32、03 结束。CRC 只覆盖 payload。
    if not 0 <= command <= 0xFF:
        raise ValueError("command must fit in one byte")
    if not 0 <= index <= 0xFF:
        raise ValueError("index must fit in one byte")
    if len(payload) > 0xFFFF:
        raise ValueError("payload is too large")
    return (
        b"\x02"
        + struct.pack("<BBH", command, index, len(payload))
        + payload
        + struct.pack("<I", crc32(payload, seed))
        + b"\x03"
    )


def parse_frames(data: bytes) -> tuple[list[P1Frame], bytes]:
    # BLE 通知可能拆帧或粘包，所以返回“已解析帧 + 未完成尾部”，
    # 调用方必须把 trailing 留到下一次通知继续解析。
    frames: list[P1Frame] = []
    offset = 0
    while offset < len(data):
        start = data.find(b"\x02", offset)
        if start < 0:
            return frames, b""
        if len(data) - start < FRAME_OVERHEAD:
            return frames, data[start:]
        command, index, payload_length = struct.unpack("<BBH", data[start + 1 : start + 5])
        frame_length = payload_length + FRAME_OVERHEAD
        if len(data) - start < frame_length:
            return frames, data[start:]
        raw = data[start : start + frame_length]
        if raw[-1] != 0x03:
            offset = start + 1
            continue
        payload = raw[5 : 5 + payload_length]
        checksum = struct.unpack("<I", raw[5 + payload_length : 9 + payload_length])[0]
        frames.append(P1Frame(command, index, payload, checksum))
        offset = start + frame_length
    return frames, b""


def fragment_for_ble(data: bytes, fragment_size: int = P1_CAPTURED_BLE_CHUNK_BYTES) -> list[bytes]:
    if fragment_size <= 0:
        raise ValueError("fragment_size must be positive")
    return [data[offset : offset + fragment_size] for offset in range(0, len(data), fragment_size)]


def make_test_bar(black_rows: int = P1_ROWS_PER_PACKET) -> bytes:
    if not 1 <= black_rows <= P1_ROWS_PER_PACKET:
        raise ValueError(f"black_rows must be between 1 and {P1_ROWS_PER_PACKET}")
    # 官方抓包证明 P1 使用 1=黑、按行排列、每字节 MSB first 的位图极性。
    return (
        b"\xFF" * (black_rows * P1_BYTES_PER_ROW)
        + b"\x00" * ((P1_ROWS_PER_PACKET - black_rows) * P1_BYTES_PER_ROW)
    )


def build_initialization_writes(
    session_key: int,
    *,
    auth_packet: bytes = P1_CAPTURED_AUTH_PACKET,
    density: int = 95,
) -> list[bytes]:
    # 初始化顺序来自官方 App 抓包：认证前导 → 注册 CRC key →
    # 读取状态/能力 → 设置热敏浓度。每条控制帧都应等待对应响应。
    session_key &= 0xFFFFFFFF
    sequence = 1
    writes = [auth_packet]
    registration = struct.pack("<I", session_key ^ P1_STANDARD_CRC_KEY)
    writes.append(pack_frame(PRT_SET_CRC_KEY, sequence, registration, P1_STANDARD_CRC_KEY))
    sequence += 1
    for command, payload in INITIALIZATION_COMMANDS:
        writes.append(pack_frame(command, sequence, payload, session_key))
        sequence += 1
    writes.append(pack_frame(PRT_SET_HEAT_DENSITY, sequence, bytes([density]), session_key))
    return writes


def build_print_writes(
    raster: bytes,
    session_key: int,
    *,
    density: int = 95,
    feed_lines: int = P1_DEFAULT_POST_PRINT_FEED_LINES,
    chunk_size: int = P1_CAPTURED_BLE_CHUNK_BYTES,
    first_sequence: int = 9,
) -> tuple[list[bytes], int, int]:
    # 图像先被切成每帧最多 1008 字节（48 bytes/行 × 21 行），
    # 再把控制帧和图像帧拼成连续协议流，最后按 FF03 credit 的 100 字节切块。
    if not raster or len(raster) % P1_BYTES_PER_ROW:
        raise ValueError("raster must contain complete 384-dot rows")
    if not 0 <= density <= 100:
        raise ValueError("density must be between 0 and 100")
    if not 0 <= feed_lines <= 0xFFFF:
        raise ValueError("feed_lines must fit in uint16")

    session_key &= 0xFFFFFFFF
    seq = first_sequence
    density_frame_1 = pack_frame(PRT_SET_HEAT_DENSITY, seq, bytes([density]), session_key)
    seq += 1
    density_frame_2 = pack_frame(PRT_SET_HEAT_DENSITY, seq, bytes([density]), session_key)
    seq += 1
    paper_frame = pack_frame(PRT_SET_PAPER_TYPE, seq, b"\x00\x00", session_key)
    seq += 1
    prefeed_frame = pack_frame(PRT_FEED_LINE, seq, b"\x00\x00", session_key)
    seq += 1

    image_frames = []
    for offset in range(0, len(raster), P1_PRINT_PAYLOAD_BYTES):
        payload = raster[offset : offset + P1_PRINT_PAYLOAD_BYTES]
        image_frames.append(pack_frame(PRT_PRINT_DATA, seq, payload, session_key))
        seq += 1

    # 官方 App 的序号会先为图像帧预留，打印模式帧在图像流之前发送；
    # 不要按“实际发送顺序”重新编号，否则旧款 P1 可能不出图。
    mode_sequence = seq
    mode_frame = pack_frame(PRT_SET_PRINT_MODE, mode_sequence, b"\x04", session_key)
    seq += 1
    final_feed_sequence = seq
    final_feed = pack_frame(PRT_FEED_LINE, final_feed_sequence, struct.pack("<H", feed_lines), session_key)

    bulk_stream = paper_frame + prefeed_frame + mode_frame + b"".join(image_frames) + final_feed
    return (
        [density_frame_1, density_frame_2] + fragment_for_ble(bulk_stream, chunk_size),
        len(image_frames),
        final_feed_sequence,
    )


def dry_run_report(black_rows: int, feed_lines: int) -> DryRunReport:
    session_key = 0xDCD60DCF
    raster = make_test_bar(black_rows)
    init_writes = build_initialization_writes(session_key)
    print_writes, image_frames, _ = build_print_writes(
        raster, session_key, feed_lines=feed_lines
    )
    return DryRunReport(
        profile="Paperang P1 official iOS capture / FF03-credit transport",
        write_characteristic=P1_FF02_WRITE,
        reply_characteristic=P1_FF01_NOTIFY,
        flow_characteristic=P1_FF03_FLOW_NOTIFY,
        width_dots=P1_WIDTH_DOTS,
        bytes_per_row=P1_BYTES_PER_ROW,
        black_rows=black_rows,
        blank_rows=P1_ROWS_PER_PACKET - black_rows,
        raster_bytes=len(raster),
        image_protocol_frames=image_frames,
        negotiated_ble_chunk_bytes=P1_CAPTURED_BLE_CHUNK_BYTES,
        initialization_writes=len(init_writes),
        print_writes=len(print_writes),
        feed_lines=feed_lines,
        flow_control_required=True,
    )


class FlowCredits:
    def __init__(self) -> None:
        self.credits = asyncio.Semaphore(0)
        self.chunk_size: int | None = None
        self.ready = asyncio.Event()

    def notify(self, data: bytes) -> None:
        # FF03 流控：0x01 + 数量表示新增 credit，0x02 + UInt16LE 表示块大小。
        # 忽略 credit 会出现能走纸但图像空白的现象。
        offset = 0
        while offset < len(data):
            kind = data[offset]
            if kind == 0x01 and offset + 1 < len(data):
                count = data[offset + 1]
                for _ in range(count):
                    self.credits.release()
                offset += 2
            elif kind == 0x02 and offset + 2 < len(data):
                self.chunk_size = int.from_bytes(data[offset + 1 : offset + 3], "little")
                self.ready.set()
                offset += 3
            else:
                logging.warning("Unknown FF03 flow notification: %s", data[offset:].hex())
                break

    async def acquire(self, timeout: float) -> None:
        await asyncio.wait_for(self.credits.acquire(), timeout=timeout)


class PaperangP1:
    def __init__(
        self,
        address: str | None = None,
        *,
        session_key: int | None = None,
        auth_packet: bytes = P1_CAPTURED_AUTH_PACKET,
        response_timeout: float = 4.0,
        flow_timeout: float = 4.0,
    ) -> None:
        self.address = address
        self.session_key = (session_key if session_key is not None else secrets.randbits(32)) & 0xFFFFFFFF
        self.auth_packet = auth_packet
        self.response_timeout = response_timeout
        self.flow_timeout = flow_timeout
        self.client: BleakClient | None = None
        self.flow = FlowCredits()
        self._reply_buffer = bytearray()
        self._reply_frames: list[P1Frame] = []
        self._reply_event = asyncio.Event()

    async def discover(self, timeout: float = 6.0) -> str:
        devices = await BleakScanner.discover(timeout=timeout)
        for device in devices:
            if (device.name or "").lower().startswith(P1_NAME.lower()):
                self.address = device.address
                return device.address
        raise RuntimeError("No Paperang BLE device found")

    async def connect(self) -> None:
        # P1 不需要系统蓝牙配对；扫描到 Paperang 后在 App 内直接连接，
        # 然后订阅 FF01 响应、FF03 流控和辅助通知。
        if self.address is None:
            await self.discover()
        assert self.address is not None
        self.client = BleakClient(self.address, timeout=20.0)
        await self.client.connect()
        await self.client.start_notify(P1_FF01_NOTIFY, self._on_reply)
        await self.client.start_notify(P1_FF03_FLOW_NOTIFY, self._on_flow)
        await self.client.start_notify(P1_1E4D_NOTIFY, self._on_aux)
        await asyncio.wait_for(self.flow.ready.wait(), timeout=self.flow_timeout)
        if self.flow.chunk_size != P1_CAPTURED_BLE_CHUNK_BYTES:
            raise RuntimeError(
                f"Unexpected P1 FF03 chunk size {self.flow.chunk_size}; expected 100 from capture"
            )
        await self._initialize()

    async def disconnect(self) -> None:
        if self.client is not None and self.client.is_connected:
            for characteristic in (P1_1E4D_NOTIFY, P1_FF03_FLOW_NOTIFY, P1_FF01_NOTIFY):
                try:
                    await self.client.stop_notify(characteristic)
                except Exception:
                    pass
            await self.client.disconnect()
        self.client = None

    def _on_reply(self, _sender, data: bytearray) -> None:
        self._reply_buffer.extend(data)
        frames, trailing = parse_frames(bytes(self._reply_buffer))
        self._reply_buffer[:] = trailing
        if frames:
            self._reply_frames.extend(frames)
            self._reply_event.set()
        logging.debug("FF01: %s", bytes(data).hex())

    def _on_flow(self, _sender, data: bytearray) -> None:
        logging.debug("FF03: %s", bytes(data).hex())
        self.flow.notify(bytes(data))

    def _on_aux(self, _sender, data: bytearray) -> None:
        logging.debug("1E4D: %s", bytes(data).hex())

    async def _write_credit_packet(self, packet: bytes) -> None:
        # FF02 使用 without-response 写入，但仍必须消耗 FF03 发放的 credit。
        if self.client is None or not self.client.is_connected:
            raise RuntimeError("Printer is not connected")
        if self.flow.chunk_size is None or len(packet) > self.flow.chunk_size:
            raise ValueError(f"BLE write is {len(packet)} bytes; negotiated limit is {self.flow.chunk_size}")
        await self.flow.acquire(self.flow_timeout)
        await self.client.write_gatt_char(P1_FF02_WRITE, packet, response=False)

    async def _wait_for_reply(self, command: int, sequence: int) -> P1Frame:
        expected_command = REPLY_COMMAND.get(command, command)
        deadline = asyncio.get_running_loop().time() + self.response_timeout
        while True:
            for index, frame in enumerate(self._reply_frames):
                if frame.command == expected_command and frame.index == sequence:
                    return self._reply_frames.pop(index)
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise TimeoutError(
                    f"No FF01 reply command=0x{expected_command:02x}, sequence={sequence}"
                )
            self._reply_event.clear()
            await asyncio.wait_for(self._reply_event.wait(), timeout=remaining)

    async def _initialize(self, density: int = 95) -> None:
        writes = build_initialization_writes(
            self.session_key, auth_packet=self.auth_packet, density=density
        )
        await self._write_credit_packet(writes[0])
        commands = [(PRT_SET_CRC_KEY, 1)] + [
            (command, sequence)
            for sequence, (command, _payload) in enumerate(INITIALIZATION_COMMANDS, start=2)
        ] + [(PRT_SET_HEAT_DENSITY, 8)]
        for packet, (command, sequence) in zip(writes[1:], commands):
            await self._write_credit_packet(packet)
            await self._wait_for_reply(command, sequence)

    async def print_raster(
        self,
        raster: bytes,
        *,
        density: int = 95,
        feed_lines: int = P1_DEFAULT_POST_PRINT_FEED_LINES,
    ) -> None:
        if self.flow.chunk_size != P1_CAPTURED_BLE_CHUNK_BYTES:
            raise RuntimeError("FF03 100-byte transport was not negotiated")
        writes, _image_frames, final_feed_sequence = build_print_writes(
            raster,
            self.session_key,
            density=density,
            feed_lines=feed_lines,
            chunk_size=self.flow.chunk_size,
        )
        for packet in writes:
            await self._write_credit_packet(packet)
        await self._wait_for_reply(PRT_FEED_LINE, final_feed_sequence)

    async def print_test_bar(
        self,
        *,
        black_rows: int = P1_ROWS_PER_PACKET,
        density: int = 95,
        feed_lines: int = P1_DEFAULT_POST_PRINT_FEED_LINES,
    ) -> None:
        await self.print_raster(
            make_test_bar(black_rows), density=density, feed_lines=feed_lines
        )


async def run_live(args: argparse.Namespace) -> dict[str, object]:
    auth_packet = bytes.fromhex(args.auth_hex)
    printer = PaperangP1(args.address, session_key=args.session_key, auth_packet=auth_packet)
    try:
        await printer.connect()
        await printer.print_test_bar(
            black_rows=args.black_rows,
            density=args.density,
            feed_lines=args.feed_lines,
        )
        return {
            "status": "sent_and_final_feed_acknowledged",
            "address": printer.address,
            "black_rows": args.black_rows,
            "feed_lines": args.feed_lines,
            "write_characteristic": P1_FF02_WRITE,
            "reply_characteristic": P1_FF01_NOTIFY,
            "flow_characteristic": P1_FF03_FLOW_NOTIFY,
            "negotiated_chunk_size": printer.flow.chunk_size,
        }
    finally:
        await printer.disconnect()


async def run_probe(args: argparse.Namespace) -> dict[str, object]:
    printer = PaperangP1(
        args.address,
        session_key=args.session_key,
        auth_packet=bytes.fromhex(args.auth_hex),
    )
    try:
        await printer.connect()
        return {
            "status": "initialized_without_printing",
            "address": printer.address,
            "negotiated_chunk_size": printer.flow.chunk_size,
            "initialization_replies": "all_acknowledged",
        }
    finally:
        await printer.disconnect()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Paperang P1 captured FF03-credit BLE driver")
    parser.add_argument("--address", help="CoreBluetooth UUID; scans by name when omitted")
    parser.add_argument("--auth-hex", default=P1_CAPTURED_AUTH_PACKET.hex())
    parser.add_argument("--session-key", type=lambda value: int(value, 0))
    parser.add_argument("--black-rows", type=int, default=P1_ROWS_PER_PACKET)
    parser.add_argument("--density", type=int, default=95)
    parser.add_argument(
        "--feed-lines",
        type=int,
        default=P1_DEFAULT_POST_PRINT_FEED_LINES,
        help="Post-print feed units (56 units/mm; default 280 = 5 mm)",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--probe", action="store_true", help="initialize and verify replies without printing")
    parser.add_argument("--allow-paper-use", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    if args.dry_run:
        print(json.dumps(asdict(dry_run_report(args.black_rows, args.feed_lines)), indent=2))
        return 0
    if args.probe:
        try:
            result = asyncio.run(run_probe(args))
        except Exception as exc:
            logging.exception("P1 probe failed: %s", exc)
            return 1
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    if not args.allow_paper_use:
        print("Refusing live print without --allow-paper-use", file=sys.stderr)
        return 2
    try:
        result = asyncio.run(run_live(args))
    except Exception as exc:
        logging.exception("P1 print failed: %s", exc)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
