"""Small TCP DNS responder for the synthetic loopback upstreams."""

from struct import pack, unpack


def test_name(label):
    label = label.encode("ascii")
    return bytes([len(label)]) + label + b"\x04test\x00"


def reply_tcp_dns(stream, write, names):
    """Only answer the supplied wire names, without dialing a resolver."""
    for _ in range(8):
        size = stream.read(2)
        if len(size) != 2:
            return
        length, = unpack("!H", size)
        if not 16 <= length <= 4096:
            return
        query = stream.read(length)
        name = next((name for name in names if query[12:].startswith(name)), None)
        if len(query) != length or name is None or query[4:10] != pack("!HHH", 1, 0, 0):
            return
        question = query[12:16 + len(name)]
        qtype = question[len(name):]
        if qtype == b"\x00\x01\x00\x01":
            answer = pack("!HHHIHBBBB", 0xc00c, 1, 1, 0, 4, 203, 0, 113, names[name])
        elif qtype == b"\x00\x1c\x00\x01":
            answer = b""
        else:
            return
        response = query[:2] + pack("!HHHHH", 0x8180, 1, bool(answer), 0, 0) + question + answer
        write(pack("!H", len(response)) + response)
