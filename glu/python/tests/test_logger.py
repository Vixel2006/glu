"""Integration tests for the node file logger. Require libglu.so."""

from __future__ import annotations

import re
import uuid
from pathlib import Path

import glupy
import pytest

pytestmark = pytest.mark.integration

LOGS_DIR = Path("/tmp/glu/logs")
LINE_RE = re.compile(
    r"^\[(?P<node>.+)\] "
    r"\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] "
    r"\[(?P<level>Error|Fatal|Info|Warning)\] "
    r"(?P<msg>.*)$"
)


@pytest.fixture
def log_node() -> str:
    """Unique node name; its log file is removed after the test."""
    name = f"py_test_{uuid.uuid4().hex[:8]}"
    try:
        yield name
    finally:
        (LOGS_DIR / f"{name}.log").unlink(missing_ok=True)


def test_logger_writes_formatted_lines(log_node):
    with glupy.Logger(log_node) as log:
        log.info("starting up")
        log.warning("be careful")
        log.error("something broke")
        log.log(glupy.LogLevel.FATAL, "dead")

    lines = (LOGS_DIR / f"{log_node}.log").read_text().splitlines()
    assert len(lines) == 4

    matches = [LINE_RE.match(line) for line in lines]
    assert all(m is not None for m in matches)
    assert [m.group("node") for m in matches] == [log_node] * 4
    assert [m.group("level") for m in matches] == ["Info", "Warning", "Error", "Fatal"]
    assert [m.group("msg") for m in matches] == [
        "starting up",
        "be careful",
        "something broke",
        "dead",
    ]


def test_logger_appends_across_instances(log_node):
    path = LOGS_DIR / f"{log_node}.log"
    with glupy.Logger(log_node) as log:
        log.info("first")
    with glupy.Logger(log_node) as log:
        log.info("second")

    lines = path.read_text().splitlines()
    assert len(lines) == 2
    assert lines[0].endswith("[Info] first")
    assert lines[1].endswith("[Info] second")


def test_logger_closed_handle_raises(log_node):
    log = glupy.Logger(log_node)
    log.close()
    with pytest.raises(glupy.GluClosedError):
        log.info("nope")


def test_logger_node_property(log_node):
    with glupy.Logger(log_node) as log:
        assert log.node == log_node
