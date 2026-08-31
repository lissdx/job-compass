"""Smoke test: the package imports and reports a version.

Its real job is to give CI something to run from day one, so the gate exists
before the code does rather than being added once it is already inconvenient.
"""

import job_compass


def test_package_exposes_a_version() -> None:
    assert isinstance(job_compass.__version__, str)
    assert job_compass.__version__
