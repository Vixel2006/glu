#!/usr/bin/env python3
import math
import os
import sys
import time

sys.path.insert(
    0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../../glu/python"))
)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import glupy
from messages import CmdVel, Pose


def main():
    sig = glupy.Signal()
    log = glupy.Logger("turtle_sim")
    log.info("starting: publishing /turtle1/pose, subscribing /turtle1/cmd_vel")

    sub = glupy.Subscriber("/turtle1/cmd_vel", CmdVel)
    pub = glupy.Publisher("/turtle1/pose", Pose)

    x = y = 5.544445
    theta = v = w = tv = tw = 0.0
    last = time.monotonic()
    last_cmd = (0.0, 0.0)

    print("🐢 Sim node running...")
    try:
        while sig.running():
            now = time.monotonic()
            dt = now - last
            last = now

            while cmd := sub.peek_as(CmdVel):
                tv, tw = cmd.linear, cmd.angular
                sub.ack()

            if (tv, tw) != last_cmd:
                last_cmd = (tv, tw)
                log.info(f"cmd_vel: linear={tv:.2f} angular={tw:.2f}")

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
    except BaseException as exc:
        log.fatal(f"crashed: {exc!r}")
        raise
    finally:
        log.info("stopped")
        log.close()


if __name__ == "__main__":
    main()
