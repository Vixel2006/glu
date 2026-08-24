#!/usr/bin/env python3
"""Turtle Physics Node.

Simulates differential drive kinematics for /turtle1, consuming /turtle1/cmd_vel
and publishing /turtle1/pose at 60 Hz.
"""

import math
import os
import signal
import sys
import time

# Ensure glupy and example packages are in import path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../../glu/python")))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import glupy
from messages import TOPIC_CMD_VEL, TOPIC_POSE, WORLD_SIZE, CmdVel, Pose


def main() -> None:
    print(f"🐢 Starting Turtle Simulation Node [PID: {os.getpid()}]...")

    # Cleanup potential stale shared memory segments from previous crashed runs
    glupy.shm_unlink(TOPIC_POSE)
    glupy.shm_unlink(TOPIC_CMD_VEL)

    # Initial state (center of 11x11 grid, facing right)
    x = 5.544445
    y = 5.544445
    theta = 0.0
    linear_vel = 0.0
    angular_vel = 0.0

    target_linear = 0.0
    target_angular = 0.0

    running = True

    def signal_handler(sig, frame):
        nonlocal running
        print("\nStopping Turtle Node...")
        running = False

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    with glupy.Subscriber(TOPIC_CMD_VEL, CmdVel, capacity=64) as sub_cmd, \
         glupy.Publisher(TOPIC_POSE, Pose, capacity=64, tos=glupy.Tos.RELIABLE) as pub_pose:

        print("Listening for /turtle1/cmd_vel and publishing /turtle1/pose...")
        
        # Publish initial pose
        with pub_pose.reserve_as(Pose) as slot:
            if slot is not None:
                slot.x = x
                slot.y = y
                slot.theta = theta
                slot.linear_velocity = 0.0
                slot.angular_velocity = 0.0

        last_time = time.monotonic()
        
        while running:
            now = time.monotonic()
            dt = now - last_time
            last_time = now

            # Drain latest velocity command
            while True:
                cmd = sub_cmd.peek_as(CmdVel)
                if cmd is None:
                    break
                target_linear = cmd.linear
                target_angular = cmd.angular
                sub_cmd.ack()

            # Smoothly transition velocities (accel/decel filter)
            linear_vel += (target_linear - linear_vel) * min(1.0, dt * 15.0)
            angular_vel += (target_angular - angular_vel) * min(1.0, dt * 15.0)

            # Integrate kinematics
            x += linear_vel * math.cos(theta) * dt
            y += linear_vel * math.sin(theta) * dt
            theta += angular_vel * dt

            # Wrap theta to [-pi, pi]
            while theta > math.pi:
                theta -= 2.0 * math.pi
            while theta < -math.pi:
                theta += 2.0 * math.pi

            # Enforce boundary collisions (ROS 2 turtlesim world boundaries: 0.0 to 11.0)
            wall_hit = False
            if x < 0.5:
                x = 0.5
                wall_hit = True
            elif x > WORLD_SIZE - 0.5:
                x = WORLD_SIZE - 0.5
                wall_hit = True

            if y < 0.5:
                y = 0.5
                wall_hit = True
            elif y > WORLD_SIZE - 0.5:
                y = WORLD_SIZE - 0.5
                wall_hit = True

            if wall_hit:
                linear_vel = 0.0

            # Zero-copy reservation and publish
            with pub_pose.reserve_as(Pose) as slot:
                if slot is not None:
                    slot.x = x
                    slot.y = y
                    slot.theta = theta
                    slot.linear_velocity = linear_vel
                    slot.angular_velocity = angular_vel

            # 60 Hz loop timing
            elapsed = time.monotonic() - now
            sleep_time = max(0.001, (1.0 / 60.0) - elapsed)
            time.sleep(sleep_time)

    # Cleanup SHM
    glupy.shm_unlink(TOPIC_POSE)
    glupy.shm_unlink(TOPIC_CMD_VEL)
    print("Turtle Node stopped cleanly.")


if __name__ == "__main__":
    main()
