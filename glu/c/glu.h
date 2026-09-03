/*
 * glu.h — C/C++ bindings for libglu (built from src/c_api.zig).
 *
 * Link against `-lglu` (libglu.so). All functions are safe to call from any
 * thread; per-thread error state is readable via glu_last_error().
 *
 * Error convention: functions returning a pointer return NULL on failure,
 * functions returning int return -1 (or nonzero) on failure and 0 on success.
 * Call glu_last_error() for a human-readable message describing the most
 * recent error on the calling thread.
 *
 * Ownership: every `*_new`/`listen`/`bind`/`connect`/`accept` call returns a
 * handle that must be released with its matching `_free`/`_close` function.
 * Handles are opaque; do not dereference or free() them directly.
 */

#ifndef GLU_GLU_H
#define GLU_GLU_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ===========================================================================
 * Error handling
 * ===========================================================================
 */

/** Static string describing the most recent error on this thread ("OK" if
 * none). */
const char *glu_last_error(void);

/* ===========================================================================
 * Types of Service (shared-memory pub/sub)
 * ===========================================================================
 */

typedef enum GluTos {
  GLU_TOS_RELIABLE =
      0, /* writers block when the ring is full of unread messages */
  GLU_TOS_BEST_EFFORT = 1 /* readers skip messages they cannot keep up with */
} GluTos;

/* ===========================================================================
 * Opaque handle types
 * ===========================================================================
 */

typedef struct GluPublisher GluPublisher;
typedef struct GluSubscriber GluSubscriber;
typedef struct GluPeer GluPeer;
typedef struct GluTcpServer GluTcpServer;
typedef struct GluTcpStream GluTcpStream;
typedef struct GluUdpSocket GluUdpSocket;

/* ===========================================================================
 * Shared-memory Publisher / Subscriber (SPSC ring per topic)
 * ===========================================================================
 */

/**
 * Create a publisher on topic `name` (e.g. "/telemetry"). Messages are fixed
 * size (`msg_size` bytes); the shared ring holds `capacity` slots. Returns
 * NULL on failure.
 */
GluPublisher *glu_publisher_new(const char *name, uint32_t msg_size,
                                uint32_t capacity, GluTos tos);
void glu_publisher_free(GluPublisher *pub);

/** Reserve a slot for writing. Returns NULL if no slot is free yet. */
void *glu_publisher_reserve(GluPublisher *pub);
/** Publish the previously reserved slot, waking subscribers. */
void glu_publisher_commit(GluPublisher *pub);
/** Convenience: memcpy `msg` into a fresh slot and commit it. Blocks while
 * full. */
int glu_publisher_publish(GluPublisher *pub, const void *msg);

/** Create a subscriber for topic `name`; must match msg_size/capacity of
 * writers. */
GluSubscriber *glu_subscriber_new(const char *name, uint32_t msg_size,
                                  uint32_t capacity);
void glu_subscriber_free(GluSubscriber *sub);

/** Peek at the newest unread message. Returns NULL when nothing is available.
 */
void *glu_subscriber_peek(GluSubscriber *sub);
/** Release the message returned by the last peek(). */
void glu_subscriber_ack(GluSubscriber *sub);

/* ===========================================================================
 * Peer — multicast network session (reliable/best-effort datagrams)
 * ===========================================================================
 */

GluPeer *glu_peer_new(const char *name, uint32_t msg_size, uint32_t capacity,
                      GluTos tos);
void glu_peer_free(GluPeer *peer);

/** Send one datagram. Returns 0 on success, -1 on failure. */
int glu_peer_send(GluPeer *peer, const uint8_t *data, size_t len);
/**
 * Receive into `out` (capacity `cap`). Writes the number of bytes received to
 * *out_len. Returns 0 on success, -1 on failure.
 */
int glu_peer_recv(GluPeer *peer, uint8_t *out, size_t cap, size_t *out_len);

/* ===========================================================================
 * TCP transport
 * ===========================================================================
 */

/**
 * Socket options mirroring transport/tcp.zig::Config. Fields set to -1 mean
 * "leave at OS default" for the buffer/timeout options.
 */
typedef struct GluTcpConfig {
  bool nodelay;                /* TCP_NODELAY                            */
  bool quickack;               /* TCP_QUICKACK                           */
  bool keepalive;              /* SO_KEEPALIVE                           */
  uint32_t keepalive_idle;     /* seconds before probes start            */
  uint32_t keepalive_interval; /* seconds between probes                 */
  uint32_t keepalive_count;    /* probes before dropping the connection   */
  int32_t recv_buf;            /* SO_RCVBUF bytes, -1 = default          */
  int32_t send_buf;            /* SO_SNDBUF bytes, -1 = default          */
  bool defer_accept;           /* TCP_DEFER_ACCEPT                       */
  uint32_t connect_timeout_ms;
  int32_t recv_timeout_ms; /* -1 = blocking                          */
  int32_t send_timeout_ms; /* -1 = blocking                          */
} GluTcpConfig;

/** Start listening on `host:port`. Returns NULL on failure. Caller frees with
 * glu_tcp_close_server(). */
GluTcpServer *glu_tcp_listen(uint16_t port, const char *host,
                             const GluTcpConfig *cfg /* NULL = defaults */);
/** Same as glu_tcp_listen(port, "0.0.0.0", NULL). */
GluTcpServer *glu_tcp_listen_default(uint16_t port);

/** Block until a client connects; stores the new stream in *out_stream. Returns
 * 0/-1. */
int glu_tcp_accept(GluTcpServer *server, GluTcpStream **out_stream);

/** Connect to `host:port`. Returns NULL on failure. Caller frees with
 * glu_tcp_close_stream(). */
GluTcpStream *glu_tcp_connect(const char *host, uint16_t port);

/** Send up to `len` bytes; writes bytes actually sent to *sent. Returns 0/-1.
 */
int glu_tcp_send(GluTcpStream *stream, const uint8_t *data, size_t len,
                 size_t *sent);
/** Receive up to `cap` bytes; writes bytes actually read to *got. Returns 0/-1.
 */
int glu_tcp_receive(GluTcpStream *stream, uint8_t *buf, size_t cap,
                    size_t *got);

/** Apply `cfg` to an existing socket fd. cfg may be NULL for defaults. Returns
 * 0 on success. */
int glu_tcp_apply_socket_opts(int fd, const GluTcpConfig *cfg);

void glu_tcp_close_stream(GluTcpStream *stream);
void glu_tcp_close_server(GluTcpServer *server);

/* ===========================================================================
 * UDP transport
 * ===========================================================================
 */

/**
 * Socket options mirroring transport/udp.zig::SocketConfig. -1 means
 * "leave at OS default" for buffer/timeout options.
 */
typedef struct GluUdpSocketConfig {
  int32_t recv_buf;        /* SO_RCVBUF bytes, -1 = default */
  int32_t send_buf;        /* SO_SNDBUF bytes, -1 = default */
  bool broadcast;          /* SO_BROADCAST                  */
  bool reuse_addr;         /* SO_REUSEADDR                  */
  int32_t recv_timeout_ms; /* -1 = blocking                 */
  int32_t send_timeout_ms; /* -1 = blocking                 */
} GluUdpSocketConfig;

/** Remote endpoint written by glu_udp_receive_from(). */
typedef struct GluEndpoint {
  char host[46]; /* dotted-quad IPv4 string, NUL-padded */
  uint32_t host_len;
  uint16_t port;
  uint16_t _pad;
} GluEndpoint;

/** Bind a UDP socket to `host:port`. Returns NULL on failure. */
GluUdpSocket *glu_udp_bind(uint16_t port, const char *host,
                           const GluUdpSocketConfig *cfg /* NULL = defaults */);
/** Same as glu_udp_bind(port, "0.0.0.0", NULL). */
GluUdpSocket *glu_udp_bind_default(uint16_t port);

/** Send `len` bytes to `host:port`; writes bytes sent to *sent. Returns 0/-1.
 */
int glu_udp_send_to(GluUdpSocket *sock, const char *host, uint16_t port,
                    const uint8_t *data, size_t len, size_t *sent);

/**
 * Receive up to `cap` bytes; writes count to *got and the sender address to
 * `addr` (may be NULL to ignore). Returns 0/-1.
 */
int glu_udp_receive_from(GluUdpSocket *sock, uint8_t *buf, size_t cap,
                         size_t *got, GluEndpoint *addr /* nullable */);

/** Connect the socket (locks sends/receives to one peer). Returns 0/-1. */
int glu_udp_connect(GluUdpSocket *sock, const char *host, uint16_t port);

/** Connected-socket send; writes bytes sent to *sent. Returns 0/-1. */
int glu_udp_send(GluUdpSocket *sock, const uint8_t *data, size_t len,
                 size_t *sent);
/** Connected-socket receive; writes byte count to *got. Returns 0/-1. */
int glu_udp_receive(GluUdpSocket *sock, uint8_t *buf, size_t cap, size_t *got);

/** Join multicast `group` on interface `interface` (IPv4 strings). */
void glu_udp_join_multicast(GluUdpSocket *sock, const char *group,
                            uint16_t port, const char *interface);

void glu_udp_close(GluUdpSocket *sock);

/* ===========================================================================
 * Shared-memory helpers
 * ===========================================================================
 */

/** Remove a stale shared-memory topic from /dev/shm, ignoring failures. */
void glu_shm_unlink(const char *name);

/* ===========================================================================
 * Default configuration helpers (usable from both C and C++)
 * ===========================================================================
 */

static inline GluTcpConfig glu_tcp_config_default(void) {
  GluTcpConfig cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.nodelay = true;
  cfg.quickack = true;
  cfg.keepalive = false;
  cfg.keepalive_idle = 7200;
  cfg.keepalive_interval = 75;
  cfg.keepalive_count = 9;
  cfg.recv_buf = -1;
  cfg.send_buf = -1;
  cfg.defer_accept = false;
  cfg.connect_timeout_ms = 5000;
  cfg.recv_timeout_ms = -1;
  cfg.send_timeout_ms = -1;
  return cfg;
}

static inline GluUdpSocketConfig glu_udp_socket_config_default(void) {
  GluUdpSocketConfig cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.recv_buf = -1;
  cfg.send_buf = -1;
  cfg.broadcast = false;
  cfg.reuse_addr = false;
  cfg.recv_timeout_ms = -1;
  cfg.send_timeout_ms = -1;
  return cfg;
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* GLU_GLU_H */
