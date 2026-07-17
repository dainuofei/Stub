import hashlib
import struct
import zlib

from p1_driver import (
    P1_BYTES_PER_ROW,
    P1_CAPTURED_AUTH_PACKET,
    P1_CAPTURED_BLE_CHUNK_BYTES,
    P1_DEFAULT_POST_PRINT_FEED_LINES,
    P1_PRINT_PAYLOAD_BYTES,
    P1_ROWS_PER_PACKET,
    P1_STANDARD_CRC_KEY,
    build_initialization_writes,
    build_print_writes,
    dry_run_report,
    make_test_bar,
    pack_frame,
    parse_frames,
)


CAPTURED_SESSION_KEY = 0xDCD60DCF


def test_capture_derived_raster_shape_and_polarity():
    raster = make_test_bar()
    assert len(raster) == 1008 == P1_PRINT_PAYLOAD_BYTES
    assert raster == b"\xff" * P1_PRINT_PAYLOAD_BYTES


def test_frame_crc_and_parser_round_trip():
    raster = make_test_bar(3)
    frame = pack_frame(0x00, 7, raster, CAPTURED_SESSION_KEY)
    parsed, trailing = parse_frames(frame)
    assert trailing == b""
    assert parsed[0].payload == raster
    assert parsed[0].crc == zlib.crc32(raster, CAPTURED_SESSION_KEY) & 0xFFFFFFFF


def test_official_crc_registration_and_first_control_frame_match_capture():
    writes = build_initialization_writes(CAPTURED_SESSION_KEY)
    assert writes[0] == P1_CAPTURED_AUTH_PACKET
    assert writes[1].hex() == "0218010400ee98a0e9794eb55f03"
    assert writes[2].hex() == "020a0201000137d602ae03"
    registration = struct.pack("<I", CAPTURED_SESSION_KEY ^ P1_STANDARD_CRC_KEY)
    assert registration.hex() == "ee98a0e9"


def test_full_initialization_is_byte_for_byte_capture_match():
    expected = [
        "a50118000117011300011000335364584e3362593271546d6f6a7a7a10cbe4775a",
        "0218010400ee98a0e9794eb55f03",
        "020a0201000137d602ae03",
        "02300301000137d602ae03",
        "021c0401000137d602ae03",
        "02100501000137d602ae03",
        "021f0601000137d602ae03",
        "02040701000137d602ae03",
        "02190801005fc4aad12203",
    ]
    writes = build_initialization_writes(CAPTURED_SESSION_KEY)
    assert [item.hex() for item in writes] == expected
    assert hashlib.sha256(b"".join(writes)).hexdigest() == (
        "65f4360c4059488bcad7afdadb5d3d6b18df0d55df977016e79b71893b2c24bf"
    )


def test_captured_print_raster_recreates_all_official_ble_writes():
    raster_path = "../p1-capture/official-image-raster.bin"
    with open(raster_path, "rb") as stream:
        raster = stream.read()
    writes, image_frames, final_feed_sequence = build_print_writes(
        raster,
        CAPTURED_SESSION_KEY,
        density=95,
        feed_lines=280,
    )
    assert image_frames == 8
    assert final_feed_sequence == 22
    assert len(writes) == 80
    assert writes[0].hex() == "02190901005fc4aad12203"
    assert writes[1].hex() == "02190a01005fc4aad12203"
    assert all(len(item) == P1_CAPTURED_BLE_CHUNK_BYTES for item in writes[2:-1])
    assert len(writes[-1]) == 59
    assert sum(map(len, writes)) == 7781
    assert hashlib.sha256(b"".join(writes)).hexdigest() == (
        "447322c08e9c299c60a5f4db8401ab5ffc1438cd1c9b6bdbf236cab14244b9cb"
    )
    assert writes[2][:40].hex() == (
        "022c0b0200000015790a7303"
        "021a0c0200000015790a7303"
        "023915010004b82268de03"
        "02000df003"
    )
    assert writes[-1][-12:].hex() == "021a1602001801dad1168603"


def test_dry_run_reports_credit_transport():
    report = dry_run_report(4, 80)
    assert report.flow_control_required is True
    assert report.negotiated_ble_chunk_bytes == 100
    assert report.initialization_writes == 9
    assert report.raster_bytes == 1008
    assert report.image_protocol_frames == 1


def test_default_post_print_feed_matches_official_five_mm_margin():
    raster = make_test_bar()
    writes, _image_frames, final_feed_sequence = build_print_writes(
        raster, CAPTURED_SESSION_KEY
    )
    assert P1_DEFAULT_POST_PRINT_FEED_LINES == 280
    assert final_feed_sequence == 15
    frames, trailing = parse_frames(b"".join(writes[2:]))
    assert trailing == b""
    assert frames[-1].command == 0x1A
    assert frames[-1].index == final_feed_sequence
    assert frames[-1].payload == b"\x18\x01"


def test_incomplete_reply_frame_is_preserved():
    frame = pack_frame(0x19, 2, b"\x00", CAPTURED_SESSION_KEY)
    parsed, trailing = parse_frames(frame[:6])
    assert parsed == []
    assert trailing == frame[:6]
