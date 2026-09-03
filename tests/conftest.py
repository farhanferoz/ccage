"""Shared helpers for the Python side of the ccage suite.

`bin/ccage-auto` is an executable with no `.py` extension, so it cannot be
imported normally. Three test modules need it, and each had grown its own
identical copy of the SourceFileLoader dance. This is the one copy.
"""

import importlib.machinery
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_ccage_auto(module_name):
    """Import bin/ccage-auto under `module_name`.

    Callers pass DISTINCT names on purpose: each test module gets its own
    module object in sys.modules, so one file rebinding a module-level constant
    or patching a function cannot bleed into another's expectations.

    Import is side-effect-safe: main() is guarded by `__main__`, and _load_ccb()
    only resolves lib/.
    """
    path = str(ROOT / "bin" / "ccage-auto")
    loader = importlib.machinery.SourceFileLoader(module_name, path)
    spec = importlib.util.spec_from_loader(module_name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod
