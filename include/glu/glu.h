#ifndef GLU_GLU_H
#define GLU_GLU_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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
#define GLU_ERR_NO_SPACE (-17)

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
                     glu_channel_t **out);
void glu_channel_close(glu_channel_t *chan);
void glu_channel_write(glu_channel_t *chan, const void *msg, uint32_t msg_size);
void *glu_channel_read(glu_channel_t *chan, uint32_t sub_id);
uint32_t glu_channel_msg_size(const glu_channel_t *chan);
uint32_t glu_channel_capacity(const glu_channel_t *chan);
uint32_t glu_channel_write_cursor(const glu_channel_t *chan);

/* ── Publisher ────────────────────────────── */

int glu_publisher_init(const char *name, uint32_t msg_size, uint32_t capacity,
                       glu_publisher_t **out);
void glu_publisher_deinit(glu_publisher_t *pub);
void *glu_publisher_reserve(glu_publisher_t *pub);
void glu_publisher_commit(glu_publisher_t *pub);
void glu_publisher_publish(glu_publisher_t *pub, const void *msg,
                           uint32_t msg_size);

/* ── Subscriber ───────────────────────────── */

int glu_subscriber_init(uint32_t id, const char *name, uint32_t msg_size,
                        uint32_t capacity, glu_subscriber_t **out);
void glu_subscriber_deinit(glu_subscriber_t *sub);
void *glu_subscriber_receive(glu_subscriber_t *sub);

/* ── TCP ──────────────────────────────────── */

int glu_tcp_listen(uint16_t port, glu_tcp_listener_t **out);
void glu_tcp_listener_deinit(glu_tcp_listener_t *listener);
uint16_t glu_tcp_listener_port(const glu_tcp_listener_t *listener);
int glu_tcp_accept(glu_tcp_listener_t *listener, glu_tcp_connection_t **out);
int glu_tcp_connect(const char *host, uint16_t port,
                    glu_tcp_connection_t **out);
int glu_tcp_send(glu_tcp_connection_t *conn, const void *data, uint32_t len);
int glu_tcp_receive(glu_tcp_connection_t *conn, void *buffer, uint32_t len);
void glu_tcp_connection_deinit(glu_tcp_connection_t *conn);
int glu_tcp_set_blocking(glu_tcp_connection_t *conn, int blocking);

/* ── UDP ──────────────────────────────────── */

int glu_udp_bind(uint16_t port, glu_udp_socket_t **out);
void glu_udp_deinit(glu_udp_socket_t *sock);
int glu_udp_send_to(glu_udp_socket_t *sock, const char *host, uint16_t port,
                    const void *data, uint32_t len);
int glu_udp_receive_from(glu_udp_socket_t *sock, void *buffer, uint32_t len,
                         uint32_t *out_bytes, glu_udp_endpoint_t *out_endpoint);
int glu_udp_set_blocking(glu_udp_socket_t *sock, int blocking);

#ifdef __cplusplus
}
#endif

#endif /* GLU_GLU_H */
