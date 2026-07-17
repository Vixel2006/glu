pub const TemperatureReading = struct {
    seq: u32,
    timestamp: i64,
    temperature: f32,
    humidity: f32,
    sensor_id: u32,
};

pub const SensorStatus = struct {
    seq: u32,
    timestamp: i64,
    uptime_sec: u32,
    battery_voltage: f32,
    error_count: u32,
};

pub const FilteredTemperature = struct {
    seq: u32,
    timestamp: i64,
    raw_temp: f32,
    filtered_temp: f32,
    humidity: f32,
    sample_count: u32,
};

pub const AlertMessage = struct {
    seq: u32,
    timestamp: i64,
    severity: u8,
    message: [64]u8,
};
