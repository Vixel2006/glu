/// Directory where node stdout/stderr logs are written.
pub const LOGS_DIR = "/tmp/glu/logs";

/// Maximum size of a single message in bytes.
pub const MAX_MSG_SIZE: u32 = 1 << 16;

/// Maximum total channel capacity in messages.
pub const MAX_CAPACITY: u32 = 1 << 22;

/// Maximum topic-name length stored in a segment header.
pub const MAX_NAME_LEN: u32 = 63;

/// Magic number used to identify glu shared memory segments (`0x474C5500` = "GLU\0").
pub const GLU_MAGIC = 0x474C5500;

/// Maximum number of concurrent readers (subscribers) per channel.
pub const MAX_READERS = 8;

/// IPv4 multicast group everything publishes to. Every channel is carried
/// over this one group; traffic is demultiplexed by (port, name).
pub const MULTICAST_HOST = "239.255.43.1";

/// Base UDP port for network channels.
pub const PORT_BASE: u16 = 49152;
pub const PORT_SLOTS: u32 = 256;

/// Maximum UDP payload over IPv4
pub const NET_PAYLOAD_MAX = 65507;
pub const NET_CAP_MAX = 8;

/// Magic identifying a glu network frame (`"GLNW"`).
pub const NET_MAGIC = 0x474C4E57;

/// Maximum number of nodes in a single launch manifest.
pub const MAX_NODES = 16;

/// Maximum number of shared memory channels in a single launch
pub const MAX_SHM_CHANS = 64;

/// Maximum
pub const MAX_NET_CHANS = 64;

/// Maximum `extra_cfg` arguments per node in a launch manifest.
pub const MAX_ARGS = 8;

/// glu CLI version string.
pub const VERSION = "0.2.0";

/// Maximum node/topic entries in a `glu status` snapshot.
pub const MAX_ENTRIES = 128;

/// Path to the daemon's Unix domain socket.
pub const DAEMON_SOCK = "/tmp/glu/glud.sock";
