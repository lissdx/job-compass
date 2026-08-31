"""job-compass: a conversational record of a job search."""

from importlib.metadata import PackageNotFoundError, version

try:  # the package is installed (editable or otherwise)
    __version__ = version("job-compass")
except PackageNotFoundError:  # running from a source tree without an install
    __version__ = "0.0.0+unknown"

__all__ = ["__version__"]
