"""移植 remote_mic/ATVVProtocol.swift，GPL-3.0-only。"""
import struct

SERVICE = "ab5e0001-5a21-4f05-bc7d-af01f617b664"
TX = "ab5e0002-5a21-4f05-bc7d-af01f617b664"
AUDIO = "ab5e0003-5a21-4f05-bc7d-af01f617b664"
CONTROL = "ab5e0004-5a21-4f05-bc7d-af01f617b664"
CAPABILITIES = bytes([0x0A, 1, 0, 0, 3, 3])
STEPS = (
    7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,
    73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,
    449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,
    2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,
    7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,
    24623,27086,29794,32767,
)
INDEX = (-1, -1, -1, -1, 2, 4, 6, 8)


def capabilities(data):
    if len(data) < 7 or data[0] != 0x0B:
        raise ValueError("无效遥控器能力包")
    version = int.from_bytes(data[1:3], "big")
    if version >= 0x100:
        codecs = data[3]
        if codecs == 0 and len(data) >= 9 and data[4] & 3:
            codecs = data[4]
    else:
        if len(data) < 9:
            raise ValueError("旧版能力包长度不足")
        codecs = data[4]
    frame_size = int.from_bytes(data[5:7], "big") or 120
    if not codecs & 2 or not 1 <= frame_size <= 4096:
        raise ValueError("仅支持 16 kHz 小米遥控器语音格式")
    return version, frame_size


class Decoder:
    def __init__(self, low_first=False):
        self.low_first = low_first
        self.reset()

    def reset(self, predictor=0, index=0):
        self.predictor = min(32767, max(-32768, predictor))
        self.index = min(88, max(0, index))

    def decode(self, data):
        samples = []
        for byte in data:
            nibbles = (byte & 15, byte >> 4) if self.low_first else (byte >> 4, byte & 15)
            for nibble in nibbles:
                step = STEPS[self.index]
                diff = (step >> 3) + ((step >> 2) if nibble & 1 else 0)
                diff += (step >> 1) if nibble & 2 else 0
                diff += step if nibble & 4 else 0
                self.predictor = min(32767, max(-32768, self.predictor + (-diff if nibble & 8 else diff)))
                self.index = min(88, max(0, self.index + INDEX[nibble & 7]))
                samples.append(self.predictor)
        return struct.pack(f"<{len(samples)}h", *samples)
