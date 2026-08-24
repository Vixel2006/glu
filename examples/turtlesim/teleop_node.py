#!/usr/bin/env python3
"""CLI Keyboard Teleop Node for Turtlesim.

Publishes velocity commands to /turtle1/cmd_vel from terminal keypresses.
"""

import os
import sys
import termios
import time
import tty

# Ensure glupy and example packages are in import path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../../glu/python")))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import glupy
from messages import TOPIC_CMD_VEL, CmdVel

BANNER = """
---------------------------------------------
glu Turtlesim Keyboard Teleop
---------------------------------------------
Control the turtle:
   W / Up    : Forward
   S / Down  : Backward
   A / Left  : Turn Left
   D / Right : Turn Right
   Space     : Stop
   Q / Ctrl+C: Quit
---------------------------------------------
"""


def get_key(fd):
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        ch = sys.stdin.read(1)
        if ch == "\x1b":  # Escape sequence for arrow keys
            ch += sys.stdin.read(2)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    return ch


def main():
    print(BANNER)
    
    try:
        pub = glupy.Publisher(TOPIC_CMD_VEL, CmdVel, capacity=64, tos=glupy.Tos.BEST_EFFORT)
    except Exception as e:
        print(f"Failed to create publisher: {e}")
        sys.exit(1)

    linear_speed = 2.0
    angular_speed = 2.0
    fd = sys.stdin.fileno()

    try:
        while True:
            key = get_key(fd)
            linear = 0.0
            angular = 0.0

            if key in ("w", "W", "\x1b[A"):  # Up arrow or W
                linear = linear_speed
            elif key in ("s", "S", "\x1b[B"):  # Down arrow or S
                linear = -linear_speed
            elif key in ("a", "A", "\x1b[D"):  # Left arrow or A
                angular = angular_speed
            elif key in ("d", "D", "\x1b[C"):  # Right arrow or D
                angular = -angular_speed
            elif key == " ":
                linear = 0.0
                angular = 0.0
            elif key in ("q", "Q", "\x03"):  # Q or Ctrl+C
                print("\nExiting Teleop.")
                break
            else:
                continue

            pub.publish(CmdVel(linear=linear, angular=angular))
            print(f"\rPublished CmdVel: linear={linear:4.1f}, angular={angular:4.1f}   ", end="", flush=True)

    except KeyboardInterrupt:
        print("\nTeleop interrupted.")
    finally:
        pub.close()


if __name__ == "__main__":
    main()
