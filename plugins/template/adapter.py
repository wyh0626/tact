#!/usr/bin/env python3
"""Starting point only: implement the operations before declaring capabilities."""
import sys


def main(argv):
    operation = argv[1] if len(argv) > 1 else ""
    print(f"Operation {operation!r} is not implemented; see docs/ADAPTER.md", file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
