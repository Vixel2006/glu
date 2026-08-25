from dataclasses import dataclass
import glupy

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
