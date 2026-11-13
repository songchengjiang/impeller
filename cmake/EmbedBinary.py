import sys
from pathlib import Path

binary, header, source = map(Path, sys.argv[1:4])
symbol = sys.argv[4]
data = binary.read_bytes()
header.write_text(
    "#pragma once\n#include <cstddef>\n\n"
    f"extern const unsigned char {symbol}_data[];\n"
    f"extern const std::size_t {symbol}_length;\n"
)
lines = [
    ", ".join(f"0x{value:02x}" for value in data[offset:offset + 16])
    for offset in range(0, len(data), 16)
]
source.write_text(
    f'#include "{header.name}"\n\n'
    f"alignas(16) const unsigned char {symbol}_data[] = {{\n  "
    + ",\n  ".join(lines)
    + f"\n}};\nconst std::size_t {symbol}_length = sizeof({symbol}_data);\n"
)
