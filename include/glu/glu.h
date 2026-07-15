#ifndef GLU_GLU_H
#define GLU_GLU_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Type of Service ──────────────────────── */

#define GLU_RELIABLE 0
#define GLU_BEST_EFFORT 1

/* ── Error codes ──────────────────────────── */

#define GLU_OK 0
#define GLU_ERR_OUT_OF_MEM (-1)
#define GLU_ERR_SHM_OPEN (-2)
#define GLU_ERR_MMAP (-3)
#define GLU_ERR_SOCKET (-4)
#define GLU_ERR_BIND (-5)
#define GLU_ERR_LISTEN (-6)
#define GLU_ERR_ACCEPT (-7)
#define GLU_ERR_CONNECT (-8)
#define GLU_ERR_SEND (-9)
#define GLU_ERR_RECV (-10)
#define GLU_ERR_ADDR_RESOLVE (-11)
#define GLU_ERR_WOULD_BLOCK (-12)
#define GLU_ERR_CONN_RESET (-13)
#define GLU_ERR_INTERRUPTED (-14)
#define GLU_ERR_SETSOCKOPT (-15)
#define GLU_ERR_MESSAGE_TOO_LARGE (-16)
#define GLU_ERR_NO_SPACE (-17)
#define GLU_ERR_MULTICAST (-18)
#define GLU_ERR_NOT_CONNECTED (-19)

/* ── Opaque handle types ──────────────────── */

typedef struct glu_channel glu_channel_t;
typedef struct glu_publisher glu_publisher_t;
typedef struct glu_subscriber glu_subscriber_t;
typedef struct glu_tcp_listener glu_tcp_listener_t;
typedef struct glu_tcp_connection glu_tcp_connection_t;
typedef struct glu_udp_socket glu_udp_socket_t;

/* ── Struct return types ──────────────────── */

typedef struct {
  char host[46];
  size_t host_len;
  uint16_t port;
} glu_udp_endpoint_t;

/* ── Channel ──────────────────────────────── */

int glu_channel_open(const char *name, uint32_t msg_size, uint32_t capacity,
                     int tos, glu_channel_t **out);
void glu_channel_close(glu_channel_t *chan);
void glu_channel_write(glu_channel_t *chan, const void *msg, uint32_t msg_size);
void *glu_channel_read(glu_channel_t *chan, uint32_t sub_id);
uint32_t glu_channel_msg_size(const glu_channel_t *chan);
uint32_t glu_channel_capacity(const glu_channel_t *chan);
uint32_t glu_channel_write_cursor(const glu_channel_t *chan);

/* ── Publisher ────────────────────────────── */

int glu_publisher_init(const char *name, uint32_t msg_size, uint32_t capacity,
                       int tos, glu_publisher_t **out);
void glu_publisher_deinit(glu_publisher_t *pub);
void *glu_publisher_reserve(glu_publisher_t *pub);
void glu_publisher_commit(glu_publisher_t *pub);
void glu_publisher_publish(glu_publisher_t *pub, const void *msg,
                           uint32_t msg_size);

/* ── Subscriber ───────────────────────────── */

int glu_subscriber_init(const char *name, uint32_t msg_size,
                        uint32_t capacity, glu_subscriber_t **out);
void glu_subscriber_deinit(glu_subscriber_t *sub);
void *glu_subscriber_receive(glu_subscriber_t *sub);

/* ── TCP (basic) ──────────────────────────── */

int glu_tcp_listen(uint16_t port, glu_tcp_listener_t **out);
void glu_tcp_listener_deinit(glu_tcp_listener_t *listener);
uint16_t glu_tcp_listener_port(const glu_tcp_listener_t *listener);
int glu_tcp_accept(glu_tcp_listener_t *listener, glu_tcp_connection_t **out);
int glu_tcp_connect(const char *host, uint16_t port,
                    glu_tcp_connection_t **out);
int glu_tcp_send(glu_tcp_connection_t *conn, const void *data, uint32_t len);
int glu_tcp_receive(glu_tcp_connection_t *conn, void *buffer, uint32_t len);
void glu_tcp_connection_deinit(glu_tcp_connection_t *conn);

/* ── TCP (extended) ───────────────────────── */

int glu_tcp_listen_with_config(uint16_t port,
                               int nodelay, int quickack,
                               int keepalive, uint32_t keepalive_idle,
                               uint32_t keepalive_interval,
                               uint32_t keepalive_count,
                               int32_t recv_buf, int32_t send_buf,
                               int defer_accept, uint32_t connect_timeout_ms,
                               uint32_t recv_timeout_ms,
                               uint32_t send_timeout_ms,
                               glu_tcp_listener_t **out);
int glu_tcp_connect_with_config(const char *host, uint16_t port,
                                uint32_t connect_timeout_ms,
                                uint32_t recv_timeout_ms,
                                uint32_t send_timeout_ms,
                                glu_tcp_connection_t **out);

/* ── UDP (basic) ──────────────────────────── */

int glu_udp_bind(uint16_t port, glu_udp_socket_t **out);
void glu_udp_deinit(glu_udp_socket_t *sock);
int glu_udp_send_to(glu_udp_socket_t *sock, const char *host, uint16_t port,
                    const void *data, uint32_t len);
int glu_udp_receive_from(glu_udp_socket_t *sock, void *buffer, uint32_t len,
                         uint32_t *out_bytes, glu_udp_endpoint_t *out_endpoint);
int glu_udp_socket_connect(glu_udp_socket_t *sock, const char *host,
                           uint16_t port);
int glu_udp_send(glu_udp_socket_t *sock, const void *data, uint32_t len);
int glu_udp_receive(glu_udp_socket_t *sock, void *buffer, uint32_t len);

/* ── UDP (extended) ───────────────────────── */

int glu_udp_bind_with_config(uint16_t port,
                             int32_t recv_buf, int32_t send_buf,
                             int broadcast, uint32_t recv_timeout_ms,
                             uint32_t send_timeout_ms,
                             glu_udp_socket_t **out);
int glu_udp_join_multicast(glu_udp_socket_t *sock, const char *group);
int glu_udp_leave_multicast(glu_udp_socket_t *sock, const char *group);

#ifdef __cplusplus
}
#endif

#endif /* GLU_GLU_H */
