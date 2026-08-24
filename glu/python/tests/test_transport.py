"""Integration tests for TCP/UDP transports. Require libglu.so."""

from __future__ import annotations

import threading

import glupy
import pytest

pytestmark = pytest.mark.integration


def _echo_server(port: int, ready: threading.Event, received: list) -> threading.Thread:
    def run() -> None:
        with glupy.TcpServer(port=port, host="127.0.0.1") as server:
            ready.set()
            with server.accept() as client:
                data = client.recv(1024)
                received.append(data)
                client.send(b"ECHO:" + data)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread


def test_tcp_echo(free_tcp_port):
    port = free_tcp_port
    received: list = []
    ready = threading.Event()
    server_thread = _echo_server(port, ready, received)

    assert ready.wait(timeout=3.0)

    with glupy.TcpStream.connect("127.0.0.1", port) as client:
        assert client.send(b"Ping TCP") == 8
        reply = client.recv(1024)
        assert reply == b"ECHO:Ping TCP"

    server_thread.join(timeout=3.0)
    assert received == [b"Ping TCP"]


def test_tcp_recv_into(free_tcp_port):
    port = free_tcp_port
    ready = threading.Event()

    def run() -> None:
        with glupy.TcpServer(port=port, host="127.0.0.1") as server:
            ready.set()
            with server.accept() as client:
                client.send(b"12345678")

    server_thread = threading.Thread(target=run, daemon=True)
    server_thread.start()
    assert ready.wait(timeout=3.0)

    with glupy.TcpStream.connect("127.0.0.1", port) as client:
        buf = bytearray(8)
        n = client.recv_into(buf)
        assert n == 8
        assert bytes(buf) == b"12345678"

    server_thread.join(timeout=3.0)


def test_tcp_closed_stream_raises(free_tcp_port):
    port = free_tcp_port
    ready = threading.Event()

    def run() -> None:
        with glupy.TcpServer(port=port, host="127.0.0.1") as server:
            ready.set()
            server.accept().close()

    server_thread = threading.Thread(target=run, daemon=True)
    server_thread.start()
    assert ready.wait(timeout=3.0)

    stream = glupy.TcpStream.connect("127.0.0.1", port)
    stream.close()

    with pytest.raises(glupy.GluClosedError):
        stream.send(b"x")

    server_thread.join(timeout=3.0)


def test_udp_pair(udp_port_factory):
    # Note: the C API does not expose getsockname(), so both sockets must
    # bind concrete ports rather than letting the OS assign them.
    port_a = udp_port_factory()
    port_b = udp_port_factory()
    with (
        glupy.UdpSocket(port=port_a, host="127.0.0.1") as sock_a,
        glupy.UdpSocket(port=port_b, host="127.0.0.1") as sock_b,
    ):
        sent = sock_a.send_to("127.0.0.1", port_b, b"Ping UDP")
        assert sent == 8

        data, sender = sock_b.recv_from()
        assert data == b"Ping UDP"
        assert sender.port == port_a
        assert sender.host == "127.0.0.1"

        # Connected-socket mode.
        sock_b.connect("127.0.0.1", port_a)
        assert sock_b.send(b"Pong UDP") == 8

        data_a, sender_a = sock_a.recv_from()
        assert data_a == b"Pong UDP"
        assert sender_a.port == port_b


def test_udp_closed_raises():
    sock = glupy.UdpSocket(port=0)
    sock.close()
    with pytest.raises(glupy.GluClosedError):
        sock.send(b"x")


def test_multicast_join():
    with glupy.UdpSocket(port=0, host="0.0.0.0") as sock:
        # Should not raise.
        sock.join_multicast("224.0.0.1", 18883, "127.0.0.1")
