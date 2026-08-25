#!/usr/bin/env python3
import math, os, sys, time

sys.path.insert(
    0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../../glu/python"))
)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import glupy
from messages import CmdVel, Pose


def main():
    sub = glupy.Subscriber("/turtle1/cmd_vel", CmdVel)
    pub = glupy.Publisher("/turtle1/pose", Pose)

    x = y = 5.544445
    theta = v = w = tv = tw = 0.0
    last = time.monotonic()

    print("🐢 Sim node running...")
    while True:
        now = time.monotonic()
        dt = now - last
        last = now

        while cmd := sub.peek_as(CmdVel):
            tv, tw = cmd.linear, cmd.angular
            sub.ack()

        v += (tv - v) * min(1.0, dt * 15.0)
        w += (tw - w) * min(1.0, dt * 15.0)

        x = max(0.5, min(10.5, x + v * math.cos(theta) * dt))
        y = max(0.5, min(10.5, y + v * math.sin(theta) * dt))
        theta = (theta + w * dt + math.pi) % (2 * math.pi) - math.pi

        with pub.reserve_as(Pose) as p:
            if p:
                p.x, p.y, p.theta, p.linear_velocity, p.angular_velocity = (
                    x,
                    y,
                    theta,
                    v,
                    w,
                )

        time.sleep(max(0.001, (1 / 60) - (time.monotonic() - now)))


if __name__ == "__main__":
    main()
