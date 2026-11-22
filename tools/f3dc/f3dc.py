#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cli

if __name__ == "__main__":
    sys.exit(cli.main(sys.argv[1:]))
