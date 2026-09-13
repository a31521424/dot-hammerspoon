#!/usr/bin/env python3
"""Stream microphone WAV segments to Doubao SAUC and print JSON lines."""

from __future__ import annotations

import argparse
import asyncio
import gzip
import json
import os
import struct
import sys
import time
import uuid
from pathlib import Path

import websockets

DEFAULT_URL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
DEFAULT_RESOURCE = "volc.seedasr.sauc.duration"
PACKET_BYTES = 16000 * 2 * 1 * 200 // 1000  # 200 ms PCM


def emit(event: dict) -> None:
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(message: str) -> None:
    sys.stderr.write(message + "\n")
    sys.stderr.flush()


def header(message_type: int, flags: int = 0, serial: int = 1, compression: int = 1) -> bytes:
    return bytes(
        [
            0x11,
            ((message_type & 0x0F) << 4) | (flags & 0x0F),
            ((serial & 0x0F) << 4) | (compression & 0x0F),
            0x00,
        ]
    )


def full_client_request() -> bytes:
    payload = {
        "user": {"uid": "hammerspoon-voice-input"},
        "audio": {
            "format": "pcm",
            "codec": "raw",
            "rate": 16000,
            "bits": 16,
            "channel": 1,
        },
        "request": {
            "model_name": "bigmodel",
            "enable_itn": True,
            "enable_punc": True,
            "enable_ddc": True,
            "enable_nonstream": True,
            "show_utterances": True,
            "result_type": "full",
            "end_window_size": 800,
            "corpus": {
                "context": json.dumps(
                    {
                        "hotwords": [
                            {"word": "流式"},
                            {"word": "流式输入"},
                            {"word": "转录"},
                            {"word": "准确率"},
                            {"word": "Hammerspoon"},
                        ]
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
            },
        },
    }
    compressed = gzip.compress(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    return header(1, 0, 1, 1) + struct.pack(">I", len(compressed)) + compressed


def audio_request(pcm: bytes, last: bool = False) -> bytes:
    compressed = gzip.compress(pcm or b"")
    flags = 0x02 if last else 0x00
    return header(2, flags, 0, 1) + struct.pack(">I", len(compressed)) + compressed


def wav_pcm(path: Path) -> bytes:
    data = path.read_bytes()
    pos = data.find(b"data")
    if pos < 0 or pos + 8 > len(data):
        return b""
    return data[pos + 8 :]


def extract_text(raw: dict) -> str:
    result = raw.get("result")
    if not isinstance(result, dict):
        return ""
    text = result.get("text")
    if not isinstance(text, str):
        text = ""
    definite = []
    interim = []
    utterances = result.get("utterances")
    if isinstance(utterances, list):
        for item in utterances:
            if not isinstance(item, dict) or not item.get("text"):
                continue
            chunk = str(item["text"])
            if item.get("definite"):
                definite.append(chunk)
            else:
                interim.append(chunk)
    uttered = "".join(definite + interim)
    if len(uttered) > len(text):
        return uttered
    return text


def merge_text(prev: str, incoming: str) -> str:
    if not incoming:
        return prev
    if not prev:
        return incoming
    if incoming.startswith(prev) or prev.startswith(incoming):
        return incoming if len(incoming) >= len(prev) else prev
    overlap = min(len(prev), len(incoming), 24)
    for count in range(overlap, 0, -1):
        if prev.endswith(incoming[:count]):
            return prev + incoming[count:]
    return incoming if len(incoming) >= len(prev) else prev + incoming


def parse_frame(data: bytes) -> dict:
    if not isinstance(data, (bytes, bytearray)) or len(data) < 4:
        return {"kind": "invalid"}
    header_size = (data[0] & 0x0F) * 4 or 4
    message_type = (data[1] >> 4) & 0x0F
    flags = data[1] & 0x0F
    compression = data[2] & 0x0F
    offset = header_size
    if message_type == 0x0F:
        if offset + 8 > len(data):
            return {"kind": "error", "message": "invalid error frame"}
        code = struct.unpack(">I", data[offset : offset + 4])[0]
        size = struct.unpack(">I", data[offset + 4 : offset + 8])[0]
        msg = data[offset + 8 : offset + 8 + size]
        if compression == 1:
            try:
                msg = gzip.decompress(msg)
            except Exception:
                pass
        return {"kind": "error", "code": code, "message": msg.decode("utf-8", "replace")}
    # 0b0001 / 0b0011: a 4-byte sequence follows the header.
    if flags & 0x01:
        offset += 4
    if offset + 4 > len(data):
        return {"kind": "invalid"}
    size = struct.unpack(">I", data[offset : offset + 4])[0]
    payload = bytes(data[offset + 4 : offset + 4 + size])
    if compression == 1 and payload:
        try:
            payload = gzip.decompress(payload)
        except Exception:
            pass
    raw = {}
    if payload:
        try:
            parsed = json.loads(payload.decode("utf-8"))
            if isinstance(parsed, dict):
                raw = parsed
        except Exception:
            raw = {}
    # Last packet is 0b0010 or 0b0011. Do not treat 0b0001 (seq only)
    # as final — that dropped the rest of the utterance.
    return {
        "kind": "response",
        "text": extract_text(raw),
        "is_last": (flags & 0x02) == 0x02,
        "flags": flags,
    }


def list_wavs(folder: Path) -> list[Path]:
    files = [path for path in folder.glob("out*.wav") if path.is_file()]
    files.sort(key=lambda path: path.name)
    return files


async def pump_audio(ws, folder: Path, stop_file: Path) -> None:
    seen: set[str] = set()
    pending = bytearray()
    idle_since = time.time()
    while True:
        stopping = stop_file.exists()
        files = list_wavs(folder)
        last_index = len(files)
        for index, path in enumerate(files, start=1):
            key = str(path)
            if key in seen:
                continue
            if not stopping and index >= last_index:
                continue
            pcm = wav_pcm(path)
            seen.add(key)
            if len(pcm) < 64:
                continue
            pending.extend(pcm)
            idle_since = time.time()
        while len(pending) >= PACKET_BYTES:
            chunk = bytes(pending[:PACKET_BYTES])
            del pending[:PACKET_BYTES]
            await ws.send(audio_request(chunk, last=False))
        if stopping:
            settle_until = time.time() + 0.28
            while time.time() < settle_until:
                more = list_wavs(folder)
                for path in more:
                    key = str(path)
                    if key in seen:
                        continue
                    pcm = wav_pcm(path)
                    seen.add(key)
                    if len(pcm) >= 64:
                        pending.extend(pcm)
                await asyncio.sleep(0.04)
            while len(pending) >= PACKET_BYTES:
                chunk = bytes(pending[:PACKET_BYTES])
                del pending[:PACKET_BYTES]
                await ws.send(audio_request(chunk, last=False))
            await ws.send(audio_request(bytes(pending), last=True))
            pending.clear()
            return
        if time.time() - idle_since > 130:
            await ws.send(audio_request(b"", last=True))
            return
        await asyncio.sleep(0.04)


async def run(folder: Path, url: str, resource: str, api_key: str) -> int:
    request_id = str(uuid.uuid4())
    headers = {
        "X-Api-Key": api_key,
        "X-Api-Resource-Id": resource,
        "X-Api-Request-Id": request_id,
        "X-Api-Sequence": "-1",
    }
    latest = ""
    try:
        async with websockets.connect(
            url,
            additional_headers=headers,
            open_timeout=8,
            close_timeout=3,
            max_size=2**22,
        ) as ws:
            await ws.send(full_client_request())
            first = await asyncio.wait_for(ws.recv(), timeout=6)
            parsed = parse_frame(first if isinstance(first, (bytes, bytearray)) else first.encode())
            if parsed.get("kind") == "error":
                emit({"event": "error", "message": parsed.get("message") or "stream error"})
                return 2
            emit({"event": "ready"})
            if parsed.get("text"):
                latest = parsed["text"]
                emit({"event": "partial", "text": latest})

            async def reader() -> None:
                nonlocal latest
                async for message in ws:
                    frame = parse_frame(message if isinstance(message, (bytes, bytearray)) else message.encode())
                    if frame.get("kind") == "error":
                        emit({"event": "error", "message": frame.get("message") or "stream error"})
                        return
                    text = frame.get("text") or ""
                    if text:
                        latest = merge_text(latest, text)
                        emit({"event": "final" if frame.get("is_last") else "partial", "text": latest})
                    if frame.get("is_last"):
                        return

            reader_task = asyncio.create_task(reader())
            await pump_audio(ws, folder, folder / "STOP")
            try:
                await asyncio.wait_for(reader_task, timeout=8)
            except asyncio.TimeoutError:
                log("stream wait_final timeout")
            if latest:
                emit({"event": "final", "text": latest})
            emit({"event": "done"})
            return 0
    except Exception as exc:
        text = str(exc)
        if "403" in text:
            emit({"event": "error", "message": "403 Forbidden. Streaming ASR is not open for this key"})
        elif "401" in text:
            emit({"event": "error", "message": "401 Unauthorized. Check HAMMERSPOON_VOICE_DOUBAO_API_KEY"})
        else:
            emit({"event": "error", "message": text[:240]})
        return 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", required=True)
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--resource", default=DEFAULT_RESOURCE)
    parser.add_argument("--key-file")
    args = parser.parse_args()
    api_key = os.environ.get("HAMMERSPOON_VOICE_DOUBAO_API_KEY", "")
    if args.key_file and os.path.isfile(args.key_file):
        api_key = Path(args.key_file).read_text(encoding="utf-8").strip() or api_key
    if len(api_key) < 8:
        emit({"event": "error", "message": "missing API key"})
        return 2
    folder = Path(args.dir)
    folder.mkdir(parents=True, exist_ok=True)
    return asyncio.run(run(folder, args.url, args.resource, api_key))


if __name__ == "__main__":
    raise SystemExit(main())
