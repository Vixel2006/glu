"""Shared fixtures for glupy tests."""

import socket
import uuid

import glupy
import pytest


def _reserve_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _reserve_udp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@pytest.fixture
def free_tcp_port() -> int:
    """Reserve an ephemeral TCP port from the OS."""
    return _reserve_tcp_port()


@pytest.fixture
def free_udp_port() -> int:
    """Reserve an ephemeral UDP port from the OS."""
    return _reserve_udp_port()


@pytest.fixture
def tcp_port_factory():
    """Callable returning a fresh ephemeral TCP port on every call."""
    return _reserve_tcp_port


@pytest.fixture
def udp_port_factory():
    """Callable returning a fresh ephemeral UDP port on every call."""
    return _reserve_udp_port


@pytest.fixture
def topic() -> str:
    """Unique shared-memory topic name, unlinked again after the test."""
    name = f"/glupy_test_{uuid.uuid4().hex[:12]}"
    try:
        yield name
    finally:
        glupy.shm_unlink(name)
