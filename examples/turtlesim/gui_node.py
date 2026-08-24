#!/usr/bin/env python3
"""Minimalist Turtlesim GUI Node using Tkinter.

Renders turtle position, orientation, and pen trail on a clean ROS 2 turtlesim canvas.
Subscribes to /turtle1/pose and publishes /turtle1/cmd_vel via Arrow keys / WASD.
"""

import math
import os
import sys
import tkinter as tk
from typing import Optional

# Ensure glupy and example packages are in import path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../../glu/python")))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import glupy
from messages import TOPIC_CMD_VEL, TOPIC_POSE, WORLD_SIZE, CmdVel, Pose


class MinimalTurtlesimGUI:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("glu Turtlesim")
        self.root.geometry("540x600")
        self.root.configure(bg="#1e1e2e")
        self.root.resizable(False, False)

        # Canvas parameters (500x500 px canvas for 11x11 world)
        self.canvas_size = 500
        self.scale = self.canvas_size / WORLD_SIZE

        # Teleop velocity speeds
        self.linear_speed = 2.2
        self.angular_speed = 2.5
        self.active_keys = set()

        self.last_pose: Optional[Pose] = None

        # Setup GLU Pub/Sub
        try:
            self.sub_pose = glupy.Subscriber(TOPIC_POSE, Pose, capacity=64)
            self.pub_cmd = glupy.Publisher(TOPIC_CMD_VEL, CmdVel, capacity=64, tos=glupy.Tos.BEST_EFFORT)
        except Exception as e:
            print(f"Error initializing glupy: {e}")
            sys.exit(1)

        self._build_ui()
        self._bind_events()

        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        self.root.after(16, self.update_loop)

    def _build_ui(self):
        # Header Status Bar
        self.header = tk.Frame(self.root, bg="#181825", padx=12, pady=8)
        self.header.pack(fill=tk.X, side=tk.TOP)

        self.lbl_title = tk.Label(
            self.header, text="turtlesim", font=("Helvetica", 13, "bold"), fg="#89b4fa", bg="#181825"
        )
        self.lbl_title.pack(side=tk.LEFT)

        self.lbl_pose = tk.Label(
            self.header, text="x: 5.54  y: 5.54  θ: 0.00 rad", font=("Monospace", 10), fg="#cdd6f4", bg="#181825"
        )
        self.lbl_pose.pack(side=tk.RIGHT)

        self.canvas = tk.Canvas(
            self.root,
            width=self.canvas_size,
            height=self.canvas_size,
            bg="#4570b5",
            highlightthickness=0,
        )
        self.canvas.pack(pady=10)

        # Draw Grid
        for i in range(1, int(WORLD_SIZE)):
            p = i * self.scale
            self.canvas.create_line(p, 0, p, self.canvas_size, fill="#5a85cb", dash=(2, 4))
            self.canvas.create_line(0, p, self.canvas_size, p, fill="#5a85cb", dash=(2, 4))

        # Minimal Footer
        self.lbl_footer = tk.Label(
            self.root,
            text="Controls: Arrow keys / WASD  |  Space = Stop  |  C = Clear Trail",
            font=("Helvetica", 9),
            fg="#a6adc8",
            bg="#1e1e2e",
            pady=4,
        )
        self.lbl_footer.pack(side=tk.BOTTOM)

    def _bind_events(self):
        self.root.bind("<KeyPress>", self.on_key_press)
        self.root.bind("<KeyRelease>", self.on_key_release)

    def on_key_press(self, event: tk.Event):
        key = event.keysym.lower()
        if key == "c":
            self.canvas.delete("trail")
            return
        self.active_keys.add(key)
        self.send_cmd()

    def on_key_release(self, event: tk.Event):
        key = event.keysym.lower()
        self.active_keys.discard(key)
        self.send_cmd()

    def send_cmd(self):
        linear = 0.0
        angular = 0.0
        if "up" in self.active_keys or "w" in self.active_keys:
            linear += self.linear_speed
        if "down" in self.active_keys or "s" in self.active_keys:
            linear -= self.linear_speed

        if "left" in self.active_keys or "a" in self.active_keys:
            angular += self.angular_speed
        if "right" in self.active_keys or "d" in self.active_keys:
            angular -= self.angular_speed

        if "space" in self.active_keys:
            linear = 0.0
            angular = 0.0

        self.pub_cmd.publish(CmdVel(linear=linear, angular=angular))

    def world_to_screen(self, wx: float, wy: float) -> tuple[float, float]:
        return wx * self.scale, self.canvas_size - (wy * self.scale)

    def update_loop(self):
        # Read latest pose from shared memory
        latest_pose: Optional[Pose] = None
        while True:
            pose = self.sub_pose.peek_as(Pose)
            if pose is None:
                break
            latest_pose = pose
            self.sub_pose.ack()

        if latest_pose is not None:
            self.render(latest_pose)

        self.root.after(16, self.update_loop)

    def render(self, pose: Pose):
        sx, sy = self.world_to_screen(pose.x, pose.y)

        # Update HUD text
        self.lbl_pose.config(text=f"x: {pose.x:5.2f}  y: {pose.y:5.2f}  θ: {pose.theta:5.2f} rad")

        # Draw pen trail
        if self.last_pose is not None:
            px, py = self.world_to_screen(self.last_pose.x, self.last_pose.y)
            if math.hypot(sx - px, sy - py) > 0.3:
                self.canvas.create_line(
                    px, py, sx, sy, fill="#ffffff", width=3, capstyle=tk.ROUND, tags="trail"
                )

        self.last_pose = pose

        # Render Turtle Vector (Shell + Nose Pointer)
        self.canvas.delete("turtle")
        r = 16.0

        # Turtle Shell
        self.canvas.create_oval(
            sx - r, sy - r, sx + r, sy + r, fill="#52b788", outline="#2d6a4f", width=2, tags="turtle"
        )

        # Direction Nose Triangle
        hx = sx + (r * 1.35) * math.cos(pose.theta)
        hy = sy - (r * 1.35) * math.sin(pose.theta)
        a1, a2 = pose.theta + math.radians(140), pose.theta - math.radians(140)
        nx1 = sx + (r * 0.75) * math.cos(a1)
        ny1 = sy - (r * 0.75) * math.sin(a1)
        nx2 = sx + (r * 0.75) * math.cos(a2)
        ny2 = sy - (r * 0.75) * math.sin(a2)

        self.canvas.create_polygon(
            hx, hy, nx1, ny1, nx2, ny2, fill="#74c69d", outline="#1b4332", width=1.5, tags="turtle"
        )

        # Eye
        ex = sx + (r * 0.95) * math.cos(pose.theta)
        ey = sy - (r * 0.95) * math.sin(pose.theta)
        self.canvas.create_oval(ex - 2, ey - 2, ex + 2, ey + 2, fill="#ffffff", outline="", tags="turtle")

    def on_close(self):
        try:
            self.sub_pose.close()
            self.pub_cmd.close()
        except Exception:
            pass
        self.root.destroy()


def main():
    root = tk.Tk()
    app = MinimalTurtlesimGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()
