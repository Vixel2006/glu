"""Message definitions for turtlesim demo."""

from dataclasses import dataclass
import glupy

TOPIC_POSE = "/turtle1/pose"
TOPIC_CMD_VEL = "/turtle1/cmd_vel"

WORLD_SIZE = 11.0  # ROS 2 turtlesim standard coordinate space (0.0 .. 11.0)


@dataclass
class Pose:
    x: glupy.f32
    y: glupy.f32
    theta: glupy.f32
    linear_velocity: glupy.f32
    angular_velocity: glupy.f32


@dataclass
class CmdVel:
    linear: glupy.f32
    angular: glupy.f32
