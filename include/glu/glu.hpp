#ifndef GLU_GLU_HPP
#define GLU_GLU_HPP

#include "glu/glu.h"

#include <cstring>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace glu {

// ── Error ──────────────────────────────────────────────────────────────────

class Error final : public std::runtime_error {
public:
    explicit Error(int code) noexcept
        : std::runtime_error(message_for(code))
        , code_(code) {}

    int code() const noexcept { return code_; }

    static const char* message_for(int code) noexcept {
        switch (code) {
        case GLU_OK:              return "success";
        case GLU_ERR_OUT_OF_MEM:  return "out of memory";
        case GLU_ERR_SHM_OPEN:    return "shm_open failed";
        case GLU_ERR_MMAP:        return "mmap failed";
        case GLU_ERR_SOCKET:      return "socket creation failed";
        case GLU_ERR_BIND:        return "bind failed";
        case GLU_ERR_LISTEN:      return "listen failed";
        case GLU_ERR_ACCEPT:      return "accept failed";
        case GLU_ERR_CONNECT:     return "connect failed";
        case GLU_ERR_SEND:        return "send failed";
        case GLU_ERR_RECV:        return "receive failed";
        case GLU_ERR_ADDR_RESOLVE: return "address resolution failed";
        case GLU_ERR_WOULD_BLOCK:  return "operation would block";
        case GLU_ERR_CONN_RESET:   return "connection reset";
        case GLU_ERR_INTERRUPTED:  return "interrupted by signal";
        case GLU_ERR_SETSOCKOPT:   return "setsockopt failed";
        case GLU_ERR_NO_SPACE:     return "no space in ring buffer";
        default:                   return "unknown error";
        }
    }

private:
    int code_;
};

namespace detail {

inline int check(int rc) {
    if (rc != GLU_OK) throw Error(rc);
    return rc;
}

} // namespace detail

// ── Channel ────────────────────────────────────────────────────────────────

class Channel {
public:
    Channel(const char* name, uint32_t msg_size, uint32_t capacity) {
        detail::check(glu_channel_open(name, msg_size, capacity, &chan_));
    }

    ~Channel() { if (chan_) glu_channel_close(chan_); }

    Channel(const Channel&) = delete;
    Channel& operator=(const Channel&) = delete;

    Channel(Channel&& other) noexcept : chan_(std::exchange(other.chan_, nullptr)) {}
    Channel& operator=(Channel&& other) noexcept {
        if (this != &other) {
            if (chan_) glu_channel_close(chan_);
            chan_ = std::exchange(other.chan_, nullptr);
        }
        return *this;
    }

    void write(const void* msg, uint32_t msg_size) {
        glu_channel_write(chan_, msg, msg_size);
    }

    void* read(uint32_t sub_id) { return glu_channel_read(chan_, sub_id); }

    uint32_t msg_size() const noexcept { return glu_channel_msg_size(chan_); }
    uint32_t capacity() const noexcept { return glu_channel_capacity(chan_); }
    uint32_t write_cursor() const noexcept { return glu_channel_write_cursor(chan_); }

    glu_channel_t* handle() noexcept { return chan_; }
    const glu_channel_t* handle() const noexcept { return chan_; }

private:
    glu_channel_t* chan_ = nullptr;
};

// ── Publisher<T> ───────────────────────────────────────────────────────────

template <typename T>
class Publisher {
public:
    Publisher(const char* name, uint32_t capacity = 64) {
        detail::check(glu_publisher_init(name, sizeof(T), capacity, &pub_));
    }

    ~Publisher() { if (pub_) glu_publisher_deinit(pub_); }

    Publisher(const Publisher&) = delete;
    Publisher& operator=(const Publisher&) = delete;

    Publisher(Publisher&& other) noexcept : pub_(std::exchange(other.pub_, nullptr)) {}
    Publisher& operator=(Publisher&& other) noexcept {
        if (this != &other) {
            if (pub_) glu_publisher_deinit(pub_);
            pub_ = std::exchange(other.pub_, nullptr);
        }
        return *this;
    }

    void publish(const T& msg) {
        glu_publisher_publish(pub_, &msg, sizeof(T));
    }

    T* reserve() {
        auto* ptr = glu_publisher_reserve(pub_);
        if (!ptr) throw Error(GLU_ERR_NO_SPACE);
        return static_cast<T*>(ptr);
    }

    void commit() { glu_publisher_commit(pub_); }

    glu_publisher_t* handle() noexcept { return pub_; }

private:
    glu_publisher_t* pub_ = nullptr;
};

// ── Subscriber<T> ──────────────────────────────────────────────────────────

template <typename T>
class Subscriber {
public:
    Subscriber(const char* name, uint32_t capacity = 64) {
        detail::check(glu_subscriber_init(name, sizeof(T), capacity, &sub_));
    }

    ~Subscriber() { if (sub_) glu_subscriber_deinit(sub_); }

    Subscriber(const Subscriber&) = delete;
    Subscriber& operator=(const Subscriber&) = delete;

    Subscriber(Subscriber&& other) noexcept : sub_(std::exchange(other.sub_, nullptr)) {}
    Subscriber& operator=(Subscriber&& other) noexcept {
        if (this != &other) {
            if (sub_) glu_subscriber_deinit(sub_);
            sub_ = std::exchange(other.sub_, nullptr);
        }
        return *this;
    }

    const T* receive() {
        return static_cast<const T*>(glu_subscriber_receive(sub_));
    }

    glu_subscriber_t* handle() noexcept { return sub_; }

private:
    glu_subscriber_t* sub_ = nullptr;
};

// ── TCP ────────────────────────────────────────────────────────────────────

class TcpConnection {
public:
    TcpConnection() = default;

    ~TcpConnection() { if (conn_) glu_tcp_connection_deinit(conn_); }

    TcpConnection(const TcpConnection&) = delete;
    TcpConnection& operator=(const TcpConnection&) = delete;

    TcpConnection(TcpConnection&& other) noexcept : conn_(std::exchange(other.conn_, nullptr)) {}
    TcpConnection& operator=(TcpConnection&& other) noexcept {
        if (this != &other) {
            if (conn_) glu_tcp_connection_deinit(conn_);
            conn_ = std::exchange(other.conn_, nullptr);
        }
        return *this;
    }

    int send(const void* data, uint32_t len) {
        int rc = glu_tcp_send(conn_, data, len);
        if (rc < 0) throw Error(rc);
        return rc;
    }

    int receive(void* buffer, uint32_t len) {
        int rc = glu_tcp_receive(conn_, buffer, len);
        if (rc < 0) throw Error(rc);
        return rc;
    }

    static TcpConnection connect(const char* host, uint16_t port) {
        glu_tcp_connection_t* conn;
        detail::check(glu_tcp_connect(host, port, &conn));
        return TcpConnection(conn);
    }

    void set_blocking(bool blocking) {
        detail::check(glu_tcp_set_blocking(conn_, blocking ? 1 : 0));
    }

    glu_tcp_connection_t* handle() noexcept { return conn_; }

private:
    friend class TcpListener;
    explicit TcpConnection(glu_tcp_connection_t* conn) : conn_(conn) {}

    glu_tcp_connection_t* conn_ = nullptr;
};

class TcpListener {
public:
    explicit TcpListener(uint16_t port) {
        detail::check(glu_tcp_listen(port, &listener_));
    }

    ~TcpListener() { if (listener_) glu_tcp_listener_deinit(listener_); }

    TcpListener(const TcpListener&) = delete;
    TcpListener& operator=(const TcpListener&) = delete;

    TcpListener(TcpListener&& other) noexcept : listener_(std::exchange(other.listener_, nullptr)) {}
    TcpListener& operator=(TcpListener&& other) noexcept {
        if (this != &other) {
            if (listener_) glu_tcp_listener_deinit(listener_);
            listener_ = std::exchange(other.listener_, nullptr);
        }
        return *this;
    }

    uint16_t port() const noexcept { return glu_tcp_listener_port(listener_); }

    TcpConnection accept() {
        glu_tcp_connection_t* conn;
        detail::check(glu_tcp_accept(listener_, &conn));
        return TcpConnection(conn);
    }

    static TcpConnection connect(const char* host, uint16_t port) {
        glu_tcp_connection_t* conn;
        detail::check(glu_tcp_connect(host, port, &conn));
        return TcpConnection(conn);
    }

    glu_tcp_listener_t* handle() noexcept { return listener_; }

private:
    glu_tcp_listener_t* listener_ = nullptr;
};

// ── UDP ────────────────────────────────────────────────────────────────────

class UdpSocket {
public:
    explicit UdpSocket(uint16_t port) {
        detail::check(glu_udp_bind(port, &sock_));
    }

    ~UdpSocket() { if (sock_) glu_udp_deinit(sock_); }

    UdpSocket(const UdpSocket&) = delete;
    UdpSocket& operator=(const UdpSocket&) = delete;

    UdpSocket(UdpSocket&& other) noexcept : sock_(std::exchange(other.sock_, nullptr)) {}
    UdpSocket& operator=(UdpSocket&& other) noexcept {
        if (this != &other) {
            if (sock_) glu_udp_deinit(sock_);
            sock_ = std::exchange(other.sock_, nullptr);
        }
        return *this;
    }

    int send_to(const char* host, uint16_t port, const void* data, uint32_t len) {
        int rc = glu_udp_send_to(sock_, host, port, data, len);
        if (rc < 0) throw Error(rc);
        return rc;
    }

    struct ReceiveResult {
        std::vector<char> buffer;
        std::string host;
        uint16_t port;
    };

    ReceiveResult receive_from(size_t max_len = 65536) {
        ReceiveResult result;
        result.buffer.resize(max_len);
        uint32_t bytes = 0;
        glu_udp_endpoint_t endpoint;
        int rc = glu_udp_receive_from(
            sock_, result.buffer.data(),
            static_cast<uint32_t>(max_len), &bytes, &endpoint);
        if (rc < 0) throw Error(rc);
        result.buffer.resize(bytes);
        auto host_len = endpoint.host_len < 46 ? endpoint.host_len : 45;
        result.host.assign(endpoint.host, host_len);
        result.port = endpoint.port;
        return result;
    }

    void set_blocking(bool blocking) {
        detail::check(glu_udp_set_blocking(sock_, blocking ? 1 : 0));
    }

    glu_udp_socket_t* handle() noexcept { return sock_; }

private:
    glu_udp_socket_t* sock_ = nullptr;
};



} // namespace glu

#endif // GLU_GLU_HPP
