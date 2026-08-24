#pragma once

#if __has_include(<glu/glu.h>)
#include <glu/glu.h>
#elif __has_include("glu.h")
#include "glu.h"
#else
#include "../c/glu.h"
#endif

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

namespace glu {

/**
 * Exception type thrown on GLU C API errors.
 */
class Error : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};

/**
 * Type of Service for shared memory & multicast channels.
 */
enum class Tos : int {
  Reliable = GLU_TOS_RELIABLE, /// Writers block when the ring buffer is full
  BestEffort =
      GLU_TOS_BEST_EFFORT /// Readers skip messages if they cannot keep up
};

/**
 * Returns the most recent error message on the calling thread ("OK" if none).
 */
inline const char *last_error() noexcept { return glu_last_error(); }

/**
 * Unlink a stale shared-memory topic segment from /dev/shm.
 */
inline void shm_unlink(std::string_view name) {
  glu_shm_unlink(std::string(name).c_str());
}

/* ===========================================================================
 * Shared-memory Publisher / Subscriber
 * ===========================================================================
 */

/**
 * RAII wrapper around GluPublisher.
 */
class Publisher {
public:
  Publisher(std::string_view topic, uint32_t msg_size, uint32_t capacity,
            Tos tos = Tos::Reliable) {
    handle_ = glu_publisher_new(std::string(topic).c_str(), msg_size, capacity,
                                static_cast<GluTos>(tos));
    if (!handle_) {
      throw Error(glu_last_error());
    }
  }

  template <typename T>
  static Publisher create(std::string_view topic, uint32_t capacity,
                          Tos tos = Tos::Reliable) {
    return Publisher(topic, sizeof(T), capacity, tos);
  }

  ~Publisher() {
    if (handle_) {
      glu_publisher_free(handle_);
      handle_ = nullptr;
    }
  }

  Publisher(const Publisher &) = delete;
  Publisher &operator=(const Publisher &) = delete;

  Publisher(Publisher &&other) noexcept
      : handle_(std::exchange(other.handle_, nullptr)) {}

  Publisher &operator=(Publisher &&other) noexcept {
    if (this != &other) {
      if (handle_) {
        glu_publisher_free(handle_);
      }
      handle_ = std::exchange(other.handle_, nullptr);
    }
    return *this;
  }

  /**
   * Reserve a slot for writing. Returns nullptr if no slot is free yet.
   */
  template <typename T = void> T *reserve() {
    return static_cast<T *>(glu_publisher_reserve(handle_));
  }

  /**
   * Publish the previously reserved slot, waking subscribers.
   */
  void commit() { glu_publisher_commit(handle_); }

  /**
   * Convenience: copy `msg` into a fresh slot and commit it. Blocks while full.
   */
  void publish(const void *msg) {
    if (glu_publisher_publish(handle_, msg) != 0) {
      throw Error(glu_last_error());
    }
  }

  template <typename T> void publish(const T &msg) {
    publish(static_cast<const void *>(&msg));
  }

  GluPublisher *raw_handle() const noexcept { return handle_; }

private:
  GluPublisher *handle_{nullptr};
};

/**
 * RAII wrapper around GluSubscriber.
 */
class Subscriber {
public:
  Subscriber(std::string_view topic, uint32_t msg_size, uint32_t capacity) {
    handle_ =
        glu_subscriber_new(std::string(topic).c_str(), msg_size, capacity);
    if (!handle_) {
      throw Error(glu_last_error());
    }
  }

  template <typename T>
  static Subscriber create(std::string_view topic, uint32_t capacity) {
    return Subscriber(topic, sizeof(T), capacity);
  }

  ~Subscriber() {
    if (handle_) {
      glu_subscriber_free(handle_);
      handle_ = nullptr;
    }
  }

  Subscriber(const Subscriber &) = delete;
  Subscriber &operator=(const Subscriber &) = delete;

  Subscriber(Subscriber &&other) noexcept
      : handle_(std::exchange(other.handle_, nullptr)) {}

  Subscriber &operator=(Subscriber &&other) noexcept {
    if (this != &other) {
      if (handle_) {
        glu_subscriber_free(handle_);
      }
      handle_ = std::exchange(other.handle_, nullptr);
    }
    return *this;
  }

  /**
   * Peek at the newest unread message. Returns nullptr when nothing is
   * available.
   */
  template <typename T = const void> T *peek() const {
    return static_cast<T *>(glu_subscriber_peek(handle_));
  }

  /**
   * Release the message returned by the last peek().
   */
  void ack() { glu_subscriber_ack(handle_); }

  GluSubscriber *raw_handle() const noexcept { return handle_; }

private:
  GluSubscriber *handle_{nullptr};
};

/* ===========================================================================
 * Peer — Multicast network session
 * ===========================================================================
 */

/**
 * RAII wrapper around GluPeer.
 */
class Peer {
public:
  Peer(std::string_view topic, uint32_t msg_size, uint32_t capacity,
       Tos tos = Tos::Reliable) {
    handle_ = glu_peer_new(std::string(topic).c_str(), msg_size, capacity,
                           static_cast<GluTos>(tos));
    if (!handle_) {
      throw Error(glu_last_error());
    }
  }

  template <typename T>
  static Peer create(std::string_view topic, uint32_t capacity,
                     Tos tos = Tos::Reliable) {
    return Peer(topic, sizeof(T), capacity, tos);
  }

  ~Peer() {
    if (handle_) {
      glu_peer_free(handle_);
      handle_ = nullptr;
    }
  }

  Peer(const Peer &) = delete;
  Peer &operator=(const Peer &) = delete;

  Peer(Peer &&other) noexcept
      : handle_(std::exchange(other.handle_, nullptr)) {}

  Peer &operator=(Peer &&other) noexcept {
    if (this != &other) {
      if (handle_) {
        glu_peer_free(handle_);
      }
      handle_ = std::exchange(other.handle_, nullptr);
    }
    return *this;
  }

  /**
   * Send one datagram.
   */
  void send(const void *data, size_t len) {
    if (glu_peer_send(handle_, static_cast<const uint8_t *>(data), len) != 0) {
      throw Error(glu_last_error());
    }
  }

  void send(std::string_view data) { send(data.data(), data.size()); }

  template <typename T> void send(const T &msg) { send(&msg, sizeof(T)); }

  /**
   * Receive into `out` (capacity `cap`). Returns the number of bytes received.
   */
  size_t recv(void *out, size_t cap) {
    size_t out_len = 0;
    if (glu_peer_recv(handle_, static_cast<uint8_t *>(out), cap, &out_len) !=
        0) {
      throw Error(glu_last_error());
    }
    return out_len;
  }

  GluPeer *raw_handle() const noexcept { return handle_; }

private:
  GluPeer *handle_{nullptr};
};

/* ===========================================================================
 * TCP transport
 * ===========================================================================
 */

using TcpConfig = GluTcpConfig;

inline TcpConfig default_tcp_config() { return glu_tcp_config_default(); }

inline int apply_tcp_socket_opts(int fd, const TcpConfig *cfg = nullptr) {
  return glu_tcp_apply_socket_opts(fd, cfg);
}

/**
 * RAII wrapper around GluTcpStream.
 */
class TcpStream {
public:
  explicit TcpStream(GluTcpStream *handle) : handle_(handle) {
    if (!handle_) {
      throw Error(glu_last_error());
    }
  }

  static TcpStream connect(std::string_view host, uint16_t port) {
    GluTcpStream *s = glu_tcp_connect(std::string(host).c_str(), port);
    if (!s) {
      throw Error(glu_last_error());
    }
    return TcpStream(s);
  }

  ~TcpStream() { close(); }

  TcpStream(const TcpStream &) = delete;
  TcpStream &operator=(const TcpStream &) = delete;

  TcpStream(TcpStream &&other) noexcept
      : handle_(std::exchange(other.handle_, nullptr)) {}

  TcpStream &operator=(TcpStream &&other) noexcept {
    if (this != &other) {
      close();
      handle_ = std::exchange(other.handle_, nullptr);
    }
    return *this;
  }

  void close() noexcept {
    if (handle_) {
      glu_tcp_close_stream(handle_);
      handle_ = nullptr;
    }
  }

  /**
   * Send up to `len` bytes; returns bytes actually sent.
   */
  size_t send(const void *data, size_t len) {
    size_t sent = 0;
    if (glu_tcp_send(handle_, static_cast<const uint8_t *>(data), len, &sent) !=
        0) {
      throw Error(glu_last_error());
    }
    return sent;
  }

  size_t send(std::string_view data) { return send(data.data(), data.size()); }

  /**
   * Receive up to `cap` bytes; returns bytes actually read (0 on disconnect).
   */
  size_t receive(void *buf, size_t cap) {
    size_t got = 0;
    if (glu_tcp_receive(handle_, static_cast<uint8_t *>(buf), cap, &got) != 0) {
      throw Error(glu_last_error());
    }
    return got;
  }

  GluTcpStream *raw_handle() const noexcept { return handle_; }

private:
  GluTcpStream *handle_{nullptr};
};

/**
 * RAII wrapper around GluTcpServer.
 */
class TcpServer {
public:
  TcpServer(uint16_t port, std::string_view host = "0.0.0.0",
            const TcpConfig *cfg = nullptr) {
    handle_ = glu_tcp_listen(port, std::string(host).c_str(), cfg);
    if (!handle_) {
      throw Error(glu_last_error());
    }
  }

  ~TcpServer() { close(); }

  TcpServer(const TcpServer &) = delete;
  TcpServer &operator=(const TcpServer &) = delete;

  TcpServer(TcpServer &&other) noexcept
      : handle_(std::exchange(other.handle_, nullptr)) {}

  TcpServer &operator=(TcpServer &&other) noexcept {
    if (this != &other) {
      close();
      handle_ = std::exchange(other.handle_, nullptr);
    }
    return *this;
  }

  void close() noexcept {
    if (handle_) {
      glu_tcp_close_server(handle_);
      handle_ = nullptr;
    }
  }

  /**
   * Block until a client connects; returns the accepted stream.
   */
  TcpStream accept() {
    GluTcpStream *stream = nullptr;
    if (glu_tcp_accept(handle_, &stream) != 0 || !stream) {
      throw Error(glu_last_error());
    }
    return TcpStream(stream);
  }

  GluTcpServer *raw_handle() const noexcept { return handle_; }

private:
  GluTcpServer *handle_{nullptr};
};

/* ===========================================================================
 * UDP transport
 * ===========================================================================
 */

using UdpSocketConfig = GluUdpSocketConfig;
using Endpoint = GluEndpoint;

inline UdpSocketConfig default_udp_socket_config() {
  return glu_udp_socket_config_default();
}

/**
 * RAII wrapper around GluUdpSocket.
 */
class UdpSocket {
public:
  explicit UdpSocket(uint16_t port, std::string_view host = "0.0.0.0",
                     const UdpSocketConfig *cfg = nullptr) {
    handle_ = glu_udp_bind(port, std::string(host).c_str(), cfg);
    if (!handle_) {
      throw Error(glu_last_error());
    }
  }

  ~UdpSocket() { close(); }

  UdpSocket(const UdpSocket &) = delete;
  UdpSocket &operator=(const UdpSocket &) = delete;

  UdpSocket(UdpSocket &&other) noexcept
      : handle_(std::exchange(other.handle_, nullptr)) {}

  UdpSocket &operator=(UdpSocket &&other) noexcept {
    if (this != &other) {
      close();
      handle_ = std::exchange(other.handle_, nullptr);
    }
    return *this;
  }

  void close() noexcept {
    if (handle_) {
      glu_udp_close(handle_);
      handle_ = nullptr;
    }
  }

  /**
   * Send `len` bytes to `host:port`. Returns bytes actually sent.
   */
  size_t send_to(std::string_view host, uint16_t port, const void *data,
                 size_t len) {
    size_t sent = 0;
    if (glu_udp_send_to(handle_, std::string(host).c_str(), port,
                        static_cast<const uint8_t *>(data), len, &sent) != 0) {
      throw Error(glu_last_error());
    }
    return sent;
  }

  size_t send_to(std::string_view host, uint16_t port, std::string_view data) {
    return send_to(host, port, data.data(), data.size());
  }

  /**
   * Receive up to `cap` bytes; returns bytes actually read and writes sender
   * address to `addr` (if non-null).
   */
  size_t receive_from(void *buf, size_t cap, Endpoint *addr = nullptr) {
    size_t got = 0;
    if (glu_udp_receive_from(handle_, static_cast<uint8_t *>(buf), cap, &got,
                             addr) != 0) {
      throw Error(glu_last_error());
    }
    return got;
  }

  /**
   * Connect the socket to a specific remote peer.
   */
  void connect(std::string_view host, uint16_t port) {
    if (glu_udp_connect(handle_, std::string(host).c_str(), port) != 0) {
      throw Error(glu_last_error());
    }
  }

  /**
   * Connected-socket send. Returns bytes actually sent.
   */
  size_t send(const void *data, size_t len) {
    size_t sent = 0;
    if (glu_udp_send(handle_, static_cast<const uint8_t *>(data), len, &sent) !=
        0) {
      throw Error(glu_last_error());
    }
    return sent;
  }

  size_t send(std::string_view data) { return send(data.data(), data.size()); }

  /**
   * Connected-socket receive. Returns bytes actually read.
   */
  size_t receive(void *buf, size_t cap) {
    size_t got = 0;
    if (glu_udp_receive(handle_, static_cast<uint8_t *>(buf), cap, &got) != 0) {
      throw Error(glu_last_error());
    }
    return got;
  }

  /**
   * Join multicast group on interface.
   */
  void join_multicast(std::string_view group, uint16_t port,
                      std::string_view interface_ip) {
    glu_udp_join_multicast(handle_, std::string(group).c_str(), port,
                           std::string(interface_ip).c_str());
  }

  GluUdpSocket *raw_handle() const noexcept { return handle_; }

private:
  GluUdpSocket *handle_{nullptr};
};

} // namespace glu
