#!/usr/bin/env python3
import math, os, sys, tkinter as tk

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../../glu/python")))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import glupy
from messages import CmdVel, Pose


class TurtlesimGUI:
    def __init__(self, root: tk.Tk):
        self.root = root
        root.title("glu Turtlesim")
        root.geometry("540x600")
        root.configure(bg="#1e1e2e")

        self.sub = glupy.Subscriber("/turtle1/pose", Pose)
        self.pub = glupy.Publisher("/turtle1/cmd_vel", CmdVel)
        self.keys = set()
        self.last_pose = None

        header = tk.Frame(root, bg="#181825", padx=12, pady=8)
        header.pack(fill=tk.X)
        tk.Label(header, text="turtlesim", font=("Helvetica", 13, "bold"), fg="#89b4fa", bg="#181825").pack(side=tk.LEFT)
        self.lbl_pose = tk.Label(header, text="x: 5.54  y: 5.54  θ: 0.00 rad", font=("Monospace", 10), fg="#cdd6f4", bg="#181825")
        self.lbl_pose.pack(side=tk.RIGHT)

        self.canvas = tk.Canvas(root, width=500, height=500, bg="#4570b5", highlightthickness=0)
        self.canvas.pack(pady=10)
        for i in range(1, 11):
            p = i * 45.45
            self.canvas.create_line(p, 0, p, 500, fill="#5a85cb", dash=(2, 4))
            self.canvas.create_line(0, p, 500, p, fill="#5a85cb", dash=(2, 4))

        tk.Label(root, text="Controls: Arrow keys / WASD | Space = Stop | C = Clear",
                 font=("Helvetica", 9), fg="#a6adc8", bg="#1e1e2e", pady=4).pack(side=tk.BOTTOM)

        root.bind("<KeyPress>", self.on_press)
        root.bind("<KeyRelease>", self.on_release)
        self.update_loop()

    def send_cmd(self):
        lin = (2.2 if "up" in self.keys or "w" in self.keys else 0.0) - (2.2 if "down" in self.keys or "s" in self.keys else 0.0)
        ang = (2.5 if "left" in self.keys or "a" in self.keys else 0.0) - (2.5 if "right" in self.keys or "d" in self.keys else 0.0)
        if "space" in self.keys:
            lin = ang = 0.0
        self.pub.publish(CmdVel(linear=lin, angular=ang))

    def on_press(self, event):
        k = event.keysym.lower()
        if k == "c":
            self.canvas.delete("trail")
            return
        self.keys.add(k)
        self.send_cmd()

    def on_release(self, event):
        self.keys.discard(event.keysym.lower())
        self.send_cmd()

    def update_loop(self):
        pose = None
        while p := self.sub.peek_as(Pose):
            pose = p
            self.sub.ack()

        if pose:
            sx, sy = pose.x * 45.45, 500 - (pose.y * 45.45)
            self.lbl_pose.config(text=f"x: {pose.x:5.2f}  y: {pose.y:5.2f}  θ: {pose.theta:5.2f} rad")

            if self.last_pose:
                px, py = self.last_pose[0] * 45.45, 500 - (self.last_pose[1] * 45.45)
                if math.hypot(sx - px, sy - py) > 0.3:
                    self.canvas.create_line(px, py, sx, sy, fill="#ffffff", width=3, capstyle=tk.ROUND, tags="trail")
            self.last_pose = (pose.x, pose.y)

            self.canvas.delete("turtle")
            r, th = 16.0, pose.theta
            self.canvas.create_oval(sx - r, sy - r, sx + r, sy + r, fill="#52b788", outline="#2d6a4f", width=2, tags="turtle")
            hx, hy = sx + r * 1.35 * math.cos(th), sy - r * 1.35 * math.sin(th)
            a1, a2 = th + math.radians(140), th - math.radians(140)
            n1x, n1y = sx + r * 0.75 * math.cos(a1), sy - r * 0.75 * math.sin(a1)
            n2x, n2y = sx + r * 0.75 * math.cos(a2), sy - r * 0.75 * math.sin(a2)
            self.canvas.create_polygon(hx, hy, n1x, n1y, n2x, n2y, fill="#74c69d", outline="#1b4332", width=1.5, tags="turtle")

        self.root.after(16, self.update_loop)


def main():
    root = tk.Tk()
    app = TurtlesimGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()
