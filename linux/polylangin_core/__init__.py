"""Framework-agnostic core of Polylangin (Linux port).

The macOS version keeps this logic inside the Squirrel IMK frontend; for Linux it
lives here in Python so it can be shared by an IBus or Fcitx5 frontend.
"""

from .data import WordData
from .classification import Conversion, Classifier
from .composer import Composer

__all__ = ["WordData", "Conversion", "Classifier", "Composer"]
