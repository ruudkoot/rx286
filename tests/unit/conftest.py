# rx286 - tests/unit/conftest.py: lets the tests import x86.py.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
