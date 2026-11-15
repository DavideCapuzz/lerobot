
# SO101\_Gazebo\_Project.md

**Project:** Multi-robot SO-101 manipulation simulation\
**Host:** Ubuntu 24.04 + NVIDIA GPU\
**ROS 2:** Jazzy\
**Simulator:** Gazebo Harmonic\
**Robot:** LeRobot SO-101\
**Architecture:** Two Docker containers\
**Environment:** Dynamically generated from configuration files

---

# 1\. Project objectives

Build a robotics development environment with:

1. One container dedicated exclusively to Gazebo.
2. One container containing ROS 2, LeRobot and SO-101 interfaces.
3. Direct Gazebo Transport communication between containers.
4. No ROS 2 installation in the Gazebo container.
5. Multiple SO-101 robots in one simulation.
6. Support for simulated and physical SO-101 robots.
7. Dynamic environment generation.
8. Configurable tables, objects, cameras and robot positions.
9. NVIDIA GPU support.
10. Integration with MoveIt 2 and RViz2.
11. Dataset recording for LeRobot.

The project should extend the existing ros2docker repository rather than replace its architecture.

Original repositories:

- https://github.com/DavideCapuzz/ros2docker
- https://github.com/DavideCapuzz/multibot

---

# 2\. Architecture

text

```text
                 UBUNTU 24.04 HOST
                   NVIDIA GPU
                        |
                        |
                  DOCKER COMPOSE
                        |
             +----------+----------+
             |                     |
             v                     v
     GAZEBO CONTAINER       SO101 CONTAINER
             |                     |
     Ubuntu 24.04           Ubuntu 24.04
     Gazebo Harmonic        ROS 2 Jazzy
                            LeRobot
     Physics                MoveIt 2
     World                  RViz2
     Objects                ros2_control
     Robot models           SO-101 interface
     Gazebo plugins         PyTorch
             |                     |
             |                     |
             +---------------------+
                 GAZEBO TRANSPORT
                   TCP / UDP
```

## Communication principle

Gazebo and ROS 2 use different communication systems.

Gazebo uses Gazebo Transport.

ROS 2 uses DDS.

The SO-101 hardware interface connects directly to Gazebo Transport and exposes standard ROS 2 hardware interfaces.

text

```text
Gazebo
  |
  | Gazebo Transport
  |
  v
Gazebo Transport Client
  |
  v
SO101SystemInterface (C++)
  |
  v
ROS 2 Controller Manager
  |
  +------------------+
  |                  |
  v                  v
LeRobot            MoveIt 2
```

The Gazebo container does not require ROS 2.

Each robot must have its own namespace and Gazebo topic prefix.

---

# 3\. Project directory structure

text

```text
so101_ros2docker/
│
├── README.md
├── docker-compose.yml
├── .env
│
├── ros2docker/
│   ├── Dockerfile
│   ├── setup.ini
│   ├── template/
│   │   ├── init_setup.sh
│   │   └── install_robot_deps.sh
│   └── scripts/
│       ├── check_environment.sh
│       └── test_profiles.sh
│
├── gazebo/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   │
│   ├── worlds/
│   │   └── table_world.sdf
│   │
│   ├── models/
│   │   ├── table/
│   │   └── so101/
│   │
│   └── plugins/
│       └── so101_system/
│           ├── CMakeLists.txt
│           ├── include/
│           └── src/
│
├── so101/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   │
│   ├── config/
│   │   ├── environment.json
│   │   ├── robots.yaml
│   │   └── controllers.yaml
│   │
│   ├── ros2_ws/
│   │   └── src/
│   │       ├── so101_description/
│   │       ├── so101_hardware/
│   │       ├── so101_bringup/
│   │       ├── so101_interfaces/
│   │       └── so101_moveit_config/
│   │
│   └── lerobot/
│       └── so101_gazebo/
│           ├── robot.py
│           ├── config.py
│           └── cameras.py
│
├── tools/
│   └── generate_world.py
│
├── scripts/
│   ├── build.sh
│   ├── start.sh
│   ├── stop.sh
│   ├── generate_world.sh
│   ├── shell_gazebo.sh
│   ├── shell_so101.sh
│   └── test.sh
│
└── data/
    ├── calibration/
    ├── datasets/
    └── checkpoints/
```

---

# 4\. Docker configuration

## 4.1 `.env`

bash

```bash
ROS_DISTRO=jazzy
GZ_VERSION=harmonic

ROS_DOMAIN_ID=10
GZ_PARTITION=so101_simulation

GAZEBO_CONTAINER=gazebo_sim
SO101_CONTAINER=so101_environment

NVIDIA_VISIBLE_DEVICES=all
NVIDIA_DRIVER_CAPABILITIES=all

WORLD_NAME=table_world
```

## 4.2 `docker-compose.yml`

yaml

```yaml
services:

  gazebo:
    build:
      context: ./gazebo
      dockerfile: Dockerfile

    container_name: gazebo_sim

    environment:
      GZ_PARTITION: ${GZ_PARTITION}
      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: all
      DISPLAY: ${DISPLAY}

    volumes:
      - ./gazebo/worlds:/workspace/worlds
      - ./gazebo/models:/workspace/models
      - ./data:/data
      - /tmp/.X11-unix:/tmp/.X11-unix

    network_mode: host

    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

    command:
      - gz
      - sim
      - -r
      - -v
      - "4"
      - /workspace/worlds/table_world.sdf

  so101:
    build:
      context: ./so101
      dockerfile: Dockerfile

    container_name: so101_environment

    environment:
      ROS_DOMAIN_ID: ${ROS_DOMAIN_ID}
      GZ_PARTITION: ${GZ_PARTITION}
      GZ_TRANSPORT_IP: ${GZ_TRANSPORT_IP:-127.0.0.1}

      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: all

    volumes:
      - ./so101/ros2_ws:/workspace/ros2_ws
      - ./so101/lerobot:/workspace/lerobot
      - ./data:/data

    network_mode: host

    depends_on:
      - gazebo

    tty: true
    stdin_open: true

    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

**Networking:** Host networking is used initially to simplify Gazebo Transport discovery. This also shares the host network namespace, so Gazebo and ROS 2 ports must be managed carefully. A later deployment can use an isolated network with explicitly configured Gazebo Transport discovery.

---

# 5\. Gazebo Dockerfile

File: `gazebo/Dockerfile`

dockerfile

```dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    lsb-release \
    gnupg \
    wget \
    git \
    build-essential \
    cmake \
    libgl1 \
    libegl1 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://packages.osrfoundation.org/gazebo.gpg \
    -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg

RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] https://packages.osrfoundation.org/gazebo/ubuntu-stable noble main" \
    > /etc/apt/sources.list.d/gazebo-stable.list

RUN apt-get update && apt-get install -y \
    gz-harmonic \
    && rm -rf /var/lib/apt/lists/*

ENV GZ_PARTITION=so101_simulation

WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

## 5.1 `gazebo/entrypoint.sh`

bash

```bash
#!/bin/bash

set -e

echo "Starting Gazebo Harmonic"
echo "Partition: ${GZ_PARTITION}"

exec "$@"
```

---

# 6\. SO-101 Dockerfile

File: `so101/Dockerfile`

dockerfile

```dockerfile
FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    gnupg \
    lsb-release \
    build-essential \
    cmake \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-vcstool \
    libusb-1.0-0-dev \
    libudev-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    -o /usr/share/keyrings/ros-archive-keyring.gpg

RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu noble main" \
    > /etc/apt/sources.list.d/ros2.list

RUN apt-get update && apt-get install -y \
    ros-jazzy-desktop \
    ros-jazzy-ros2-control \
    ros-jazzy-ros2-controllers \
    ros-jazzy-joint-state-broadcaster \
    ros-jazzy-joint-trajectory-controller \
    ros-jazzy-moveit \
    ros-jazzy-rmw-cyclonedds-cpp \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv --system-site-packages /opt/lerobot-venv

ENV PATH="/opt/lerobot-venv/bin:${PATH}"

RUN pip install --no-cache-dir \
    numpy \
    opencv-python-headless \
    pyserial \
    feetech-servo-sdk

WORKDIR /workspace

RUN mkdir -p \
    /workspace/ros2_ws/src \
    /workspace/lerobot \
    /data

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

CMD ["bash"]
```

**Dependency note:** This is a starting image, not a tested build. The exact PyTorch/CUDA wheel, LeRobot release, Gazebo Transport client and SO-101 dependencies must be pinned and validated together.

## 6.1 `so101/entrypoint.sh`

bash

```bash
#!/bin/bash

set -e

source /opt/ros/jazzy/setup.bash

if [ -f /workspace/ros2_ws/install/setup.bash ]; then
    source /workspace/ros2_ws/install/setup.bash
fi

exec "$@"
```

---

# 7\. Dynamic Gazebo environment

This is an important part of the project.

The environment must not be hardcoded.

Instead, the user provides parameters and a Python generator creates the SDF world.

The workflow:

text

```text
environment.json
       |
       v
generate_world.py
       |
       v
table_world.sdf
       |
       v
Gazebo Harmonic
```

The Docker image does not need rebuilding when the environment changes.

## 7.1 Configuration file

File: `so101/config/environment.json`

json

```json
{
  "world": {
    "name": "table_world",
    "physics": {
      "step_size": 0.001,
      "real_time_factor": 1.0
    }
  },

  "table": {
    "size": [1.2, 0.8, 0.05],
    "height": 0.75,
    "color": [0.55, 0.35, 0.15, 1.0]
  },

  "objects": [
    {
      "name": "red_cube",
      "type": "box",
      "size": [0.04, 0.04, 0.04],
      "position": [-0.25, 0.0, 0.80],
      "color": [1, 0, 0, 1],
      "mass": 0.1
    },

    {
      "name": "blue_cube",
      "type": "box",
      "size": [0.04, 0.04, 0.04],
      "position": [0, 0, 0.80],
      "color": [0, 0, 1, 1],
      "mass": 0.1
    },

    {
      "name": "green_cylinder",
      "type": "cylinder",
      "radius": 0.025,
      "length": 0.08,
      "position": [0.25, 0, 0.82],
      "color": [0, 1, 0, 1],
      "mass": 0.15
    }
  ],

  "robots": [
    {
      "name": "so101_01",
      "model_uri": "/workspace/models/so101",
      "position": [-0.7, 0, 0],
      "orientation": [0, 0, 0]
    },

    {
      "name": "so101_02",
      "model_uri": "/workspace/models/so101",
      "position": [0.7, 0, 0],
      "orientation": [0, 0, 3.14159]
    }
  ],

  "cameras": [
    {
      "name": "overhead_camera",
      "position": [0, 0, 1.8],
      "orientation": [0, 1.5708, 0],
      "width": 1280,
      "height": 720,
      "fov": 1.047
    }
  ]
}
```

## 7.2 Supported parameters

| Parameter | Description |
| --- | --- |
| `world.name` | World name |
| `physics.step_size` | Physics time step |
| `physics.real_time_factor` | Simulation speed |
| `table.size` | Table dimensions |
| `table.height` | Table height |
| `table.color` | Table color |
| `objects` | List of objects |
| `objects[].type` | Box, cylinder or sphere |
| `objects[].position` | Object coordinates |
| `objects[].color` | Object color |
| `robots` | List of robots |
| `robots[].name` | Robot namespace/name |
| `robots[].position` | Robot spawn position |
| `robots[].orientation` | Robot orientation |
| `cameras` | Camera definitions |

# 8\. Python Gazebo world generator

File: `tools/generate_world.py`

This version supports:

- Tables.
- Boxes.
- Cylinders.
- Spheres.
- Multiple robots using existing Gazebo model directories.
- Multiple cameras.
- Physics parameters.
- SDF output.
- Environment ZIP export.

python

```python
#!/usr/bin/env python3

import argparse
import json
import zipfile

from pathlib import Path
from xml.etree import ElementTree as ET


def add(parent, tag, value=None, **attrs):
    node = ET.SubElement(parent, tag, attrs)

    if value is not None:
        node.text = str(value)

    return node


def vec(values):
    return " ".join(map(str, values))


def add_geometry(parent, obj):
    geometry = add(parent, "geometry")
    kind = obj["type"]

    if kind == "box":
        box = add(geometry, "box")
        add(box, "size", vec(obj["size"]))

    elif kind == "cylinder":
        cylinder = add(geometry, "cylinder")
        add(cylinder, "radius", obj["radius"])
        add(cylinder, "length", obj["length"])

    elif kind == "sphere":
        sphere = add(geometry, "sphere")
        add(sphere, "radius", obj["radius"])

    else:
        raise ValueError(f"Unsupported type: {kind}")


def inertia(obj, mass):
    if obj["type"] == "box":
        x, y, z = obj["size"]

        return (
            mass * (y*y + z*z) / 12,
            mass * (x*x + z*z) / 12,
            mass * (x*x + y*y) / 12
        )

    if obj["type"] == "cylinder":
        r = obj["radius"]
        h = obj["length"]

        i = mass * (3*r*r + h*h) / 12
        iz = mass * r*r / 2

        return i, i, iz

    if obj["type"] == "sphere":
        i = 0.4 * mass * obj["radius"]**2
        return i, i, i

    raise ValueError(obj["type"])


def add_object(world, obj):
    model = add(world, "model", name=obj["name"])

    x, y, z = obj["position"]
    add(model, "pose", f"{x} {y} {z} 0 0 0")

    link = add(model, "link", name="link")

    mass = float(obj.get("mass", 0.1))
    ixx, iyy, izz = inertia(obj, mass)

    inertial = add(link, "inertial")
    add(inertial, "mass", mass)

    tensor = add(inertial, "inertia")
    add(tensor, "ixx", ixx)
    add(tensor, "iyy", iyy)
    add(tensor, "izz", izz)
    add(tensor, "ixy", 0)
    add(tensor, "ixz", 0)
    add(tensor, "iyz", 0)

    collision = add(link, "collision", name="collision")
    add_geometry(collision, obj)

    visual = add(link, "visual", name="visual")
    add_geometry(visual, obj)

    material = add(visual, "material")
    add(material, "ambient", vec(obj["color"]))
    add(material, "diffuse", vec(obj["color"]))


def add_table(world, config):
    table = config["table"]

    x, y, thickness = table["size"]
    height = table["height"]

    model = add(world, "model", name="table")
    add(model, "static", "true")

    link = add(model, "link", name="table_link")

    add(
        model,
        "pose",
        f"0 0 {height - thickness / 2} 0 0 0"
    )

    shape = {
        "type": "box",
        "size": [x, y, thickness]
    }

    collision = add(link, "collision", name="collision")
    add_geometry(collision, shape)

    visual = add(link, "visual", name="visual")
    add_geometry(visual, shape)

    material = add(visual, "material")
    color = vec(table["color"])

    add(material, "ambient", color)
    add(material, "diffuse", color)

    leg_height = height - thickness
    leg_size = 0.05

    for index, (lx, ly) in enumerate([
        (-x/2 + leg_size, -y/2 + leg_size),
        ( x/2 - leg_size, -y/2 + leg_size),
        (-x/2 + leg_size,  y/2 - leg_size),
        ( x/2 - leg_size,  y/2 - leg_size)
    ]):

        leg = add(model, "link", name=f"leg_{index}")

        add(
            leg,
            "pose",
            f"{lx} {ly} {-leg_height/2 - thickness/2} 0 0 0"
        )

        leg_shape = {
            "type": "box",
            "size": [leg_size, leg_size, leg_height]
        }

        collision = add(leg, "collision", name="collision")
        add_geometry(collision, leg_shape)

        visual = add(leg, "visual", name="visual")
        add_geometry(visual, leg_shape)

        material = add(visual, "material")
        add(material, "ambient", color)
        add(material, "diffuse", color)


def add_robot(world, robot):
    model_path = Path(robot["model_uri"])

    if not model_path.exists():
        raise FileNotFoundError(
            f"Missing robot model: {model_path}"
        )

    include = add(world, "include")

    add(
        include,
        "uri",
        model_path.resolve().as_uri()
    )

    add(include, "name", robot["name"])

    x, y, z = robot["position"]
    r, p, yaw = robot.get("orientation", [0, 0, 0])

    add(include, "pose", f"{x} {y} {z} {r} {p} {yaw}")


def add_camera(world, camera):
    model = add(world, "model", name=camera["name"])

    add(model, "static", "true")

    x, y, z = camera["position"]
    r, p, yaw = camera.get("orientation", [0, 0, 0])

    add(model, "pose", f"{x} {y} {z} {r} {p} {yaw}")

    link = add(model, "link", name="camera_link")

    sensor = add(
        link,
        "sensor",
        name=camera["name"],
        type="camera"
    )

    add(sensor, "always_on", "true")
    add(sensor, "update_rate", camera.get("update_rate", 30))

    camera_node = add(sensor, "camera")

    add(
        camera_node,
        "horizontal_fov",
        camera.get("fov", 1.047)
    )

    image = add(camera_node, "image")

    add(image, "width", camera.get("width", 640))
    add(image, "height", camera.get("height", 480))
    add(image, "format", "R8G8B8")

    clip = add(camera_node, "clip")

    add(clip, "near", 0.05)
    add(clip, "far", 20.0)


def generate(config, output):
    root = ET.Element("sdf", version="1.9")

    world = add(
        root,
        "world",
        name=config["world"]["name"]
    )

    physics = config["world"]["physics"]

    physics_node = add(
        world,
        "physics",
        name="physics",
        type="ignored"
    )

    add(
        physics_node,
        "max_step_size",
        physics["step_size"]
    )

    add(
        physics_node,
        "real_time_factor",
        physics["real_time_factor"]
    )

    for filename, name in [
        (
            "gz-sim-physics-system",
            "gz::sim::systems::Physics"
        ),
        (
            "gz-sim-user-commands-system",
            "gz::sim::systems::UserCommands"
        ),
        (
            "gz-sim-scene-broadcaster-system",
            "gz::sim::systems::SceneBroadcaster"
        ),
        (
            "gz-sim-sensors-system",
            "gz::sim::systems::Sensors"
        )
    ]:
        plugin = add(
            world,
            "plugin",
            filename=filename,
            name=name
        )

        if name.endswith("Sensors"):
            add(plugin, "render_engine", "ogre2")

    light = add(world, "light", name="sun", type="directional")

    add(light, "pose", "0 0 5 0 0 0")
    add(light, "direction", "-0.5 0.5 -1")
    add(light, "diffuse", "0.8 0.8 0.8 1")

    ground = add(world, "model", name="ground")
    add(ground, "static", "true")

    ground_link = add(ground, "link", name="ground_link")

    for tag in ["collision", "visual"]:
        node = add(ground_link, tag, name=tag)

        geometry = add(node, "geometry")
        plane = add(geometry, "plane")

        add(plane, "normal", "0 0 1")
        add(plane, "size", "20 20")

    add_table(world, config)

    for obj in config.get("objects", []):
        add_object(world, obj)

    for robot in config.get("robots", []):
        add_robot(world, robot)

    for camera in config.get("cameras", []):
        add_camera(world, camera)

    output.parent.mkdir(parents=True, exist_ok=True)

    ET.indent(root, space="  ")

    ET.ElementTree(root).write(
        output,
        encoding="utf-8",
        xml_declaration=True
    )

    print(f"Generated world: {output}")


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--config",
        default="so101/config/environment.json"
    )

    parser.add_argument(
        "--output",
        default="gazebo/worlds/table_world.sdf"
    )

    parser.add_argument(
        "--zip",
        default="output/gazebo_environment.zip"
    )

    args = parser.parse_args()

    config_path = Path(args.config)
    output_path = Path(args.output)

    config = json.loads(config_path.read_text())

    generate(config, output_path)

    zip_path = Path(args.zip)
    zip_path.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(
        zip_path,
        "w",
        zipfile.ZIP_DEFLATED
    ) as archive:

        archive.write(
            output_path,
            "worlds/table_world.sdf"
        )

        archive.write(
            config_path,
            "environment.json"
        )

    print(f"Created environment archive: {zip_path}")


if __name__ == "__main__":
    main()
```

**Note:** The camera sensor requires the Gazebo Sensors system and a working rendering backend. The generator creates camera models but does not yet configure camera-to-ROS image transport.

---

# 9\. Multi-robot configuration

File: `so101/config/robots.yaml`

yaml

```yaml
world: table_world

gazebo_partition: so101_simulation

robots:

  - name: so101_01
    backend: gazebo

    x: -0.7
    y: 0.0
    z: 0.0

    yaw: 0.0

  - name: so101_02
    backend: gazebo

    x: 0.7
    y: 0.0
    z: 0.0

    yaw: 3.14159

  - name: so101_03
    backend: gazebo

    x: 0.0
    y: 0.7
    z: 0.0

    yaw: 1.5708
```

Each robot must have:

- Unique Gazebo model name.
- Unique Gazebo command topic.
- Unique state topic.
- Unique ROS 2 namespace.
- Independent controller manager.
- Independent joint states.
- Independent LeRobot instance configuration.

For example:

text

```text
/model/so101_01/joint_cmd
/model/so101_01/joint_state

/model/so101_02/joint_cmd
/model/so101_02/joint_state
```

These are proposed custom Gazebo Transport topics. They must be implemented in the Gazebo plugin.

---

# 10\. SO-101 joint configuration

The SO-101 has six actuated joints.

File: `so101/config/controllers.yaml`

yaml

```yaml
controller_manager:
  ros__parameters:

    update_rate: 100

    joint_state_broadcaster:
      type: joint_state_broadcaster/JointStateBroadcaster

    arm_controller:
      type: joint_trajectory_controller/JointTrajectoryController

    gripper_controller:
      type: forward_command_controller/ForwardCommandController


arm_controller:
  ros__parameters:

    joints:
      - shoulder_pan
      - shoulder_lift
      - elbow_flex
      - wrist_flex
      - wrist_roll

    command_interfaces:
      - position

    state_interfaces:
      - position
      - velocity

    state_publish_rate: 50.0
    action_monitor_rate: 20.0


gripper_controller:
  ros__parameters:

    joints:
      - gripper

    interface_name: position

    state_interfaces:
      - position
      - velocity
```

The final joint names and limits must be checked against the selected official SO-101 URDF.

---

# 11\. C++ ROS 2 hardware interface

Package:

`so101_hardware`

Directory:

text

```text
so101_hardware/
├── CMakeLists.txt
├── package.xml
│
├── include/
│   └── so101_hardware/
│       ├── so101_system.hpp
│       └── gazebo_transport.hpp
│
└── src/
    ├── so101_system.cpp
    └── gazebo_transport.cpp
```

## 11.1 Responsibilities

The hardware interface should:

1. Implement `hardware_interface::SystemInterface`.
2. Export six position command interfaces.
3. Export position and velocity state interfaces.
4. Receive joint state from Gazebo Transport.
5. Send joint commands to Gazebo Transport.
6. Support multiple independent robot instances.
7. Provide communication timeout handling.
8. Support physical Feetech hardware as a separate backend.

## 11.2 Header

File:

`include/so101_hardware/so101_system.hpp`

cpp

```cpp
#pragma once

#include <string>
#include <vector>

#include "hardware_interface/system_interface.hpp"
#include "hardware_interface/types/hardware_interface_type_values.hpp"

#include "rclcpp/rclcpp.hpp"

namespace so101_hardware
{

class SO101System : public hardware_interface::SystemInterface
{

public:

    hardware_interface::CallbackReturn on_init(
        const hardware_interface::HardwareInfo & info
    ) override;

    std::vector<hardware_interface::StateInterface>
    export_state_interfaces() override;

    std::vector<hardware_interface::CommandInterface>
    export_command_interfaces() override;

    hardware_interface::CallbackReturn on_activate(
        const rclcpp_lifecycle::State & previous_state
    ) override;

    hardware_interface::CallbackReturn on_deactivate(
        const rclcpp_lifecycle::State & previous_state
    ) override;

    hardware_interface::return_type read(
        const rclcpp::Time & time,
        const rclcpp::Duration & period
    ) override;

    hardware_interface::return_type write(
        const rclcpp::Time & time,
        const rclcpp::Duration & period
    ) override;


private:

    std::string robot_name_;

    std::vector<double> position_;
    std::vector<double> velocity_;
    std::vector<double> command_;

};

}
```

This header defines the interface, not a complete plugin. The source implementation and Gazebo Transport client must be added before it can be loaded by controller manager.

## 11.3 Communication design

The Gazebo client should expose an abstraction similar to:

cpp

```cpp
class GazeboTransportClient
{
public:

    bool connect(const std::string & robot_name);

    bool send_command(
        const std::vector<double> & positions
    );

    bool get_state(
        std::vector<double> & positions,
        std::vector<double> & velocities
    );

    bool is_connected() const;

    void stop();

};
```

Use Gazebo Transport publishers and subscribers.

A suitable message choice is a custom Gazebo message containing:

- Robot identifier.
- Joint names.
- Position commands.
- Timestamp or sequence number.

The state message should contain:

- Joint names.
- Positions.
- Velocities.
- Simulation timestamp.

For a first implementation, `gz.msgs.Joint` or `gz.msgs.Model` can be evaluated, but a custom message provides better control over robot identity and joint ordering.

**Important:** The actual C++ Gazebo client, plugin and `SystemInterface` implementation are not included here. They must be implemented and tested together. The header alone is not a functioning hardware interface.

---

# 12\. LeRobot integration

LeRobot should communicate through the ROS 2 hardware interface.

It should not independently control Gazebo motors.

text

```text
LeRobot policy
     |
     v
SO-101 Python adapter
     |
     v
ROS 2 action / controller
     |
     v
SO101SystemInterface
     |
     v
Gazebo Transport
```

This provides one consistent control path for simulation and physical hardware.

## 12.1 Python adapter structure

File:

`so101/lerobot/so101_gazebo/robot.py`

python

```python
class SO101Robot:

    def __init__(
        self,
        robot_id="so101_01",
        backend="simulation"
    ):

        self.robot_id = robot_id
        self.backend = backend

    def connect(self):
        """
        Connect to the selected SO-101 backend.
        """
        raise NotImplementedError

    def get_observation(self):
        """
        Return joint positions and camera observations.
        """
        raise NotImplementedError

    def send_action(self, action):
        """
        Send a validated robot action.
        """
        raise NotImplementedError

    def disconnect(self):
        """
        Release communication resources.
        """
        raise NotImplementedError
```

The final adapter must implement the interface required by the pinned LeRobot version.

## 12.2 Observation structure

Example:

python

```python
observation = {

    "observation.state": [
        0.0,
        0.2,
        -0.3,
        0.1,
        0.0,
        0.4
    ],

    "observation.images.top": camera_image

}
```

## 12.3 Action structure

python

```python
action = {

    "shoulder_pan": 0.1,

    "shoulder_lift": 0.3,

    "elbow_flex": -0.2,

    "wrist_flex": 0.1,

    "wrist_roll": 0.0,

    "gripper": 0.5

}
```

---

# 13\. MoveIt 2 and RViz2

MoveIt should use the same robot description as the Gazebo simulation.

The package should contain:

text

```text
so101_moveit_config/
├── config/
│   ├── joint_limits.yaml
│   ├── kinematics.yaml
│   ├── moveit_controllers.yaml
│   └── ros2_controllers.yaml
│
├── launch/
│   ├── demo.launch.py
│   └── move_group.launch.py
│
└── config/
    └── so101.srdf
```

Each robot should have its own MoveIt planning group and namespace.

For example:

text

```text
/so101_01/move_group
/so101_02/move_group
```

The MoveIt controller configuration must point to the corresponding ROS 2 controllers.

---

# 14\. ros2docker modifications

The original repository should remain the foundation.

Repository:

https://github.com/DavideCapuzz/ros2docker

The proposed modifications are:

| File | Modification |
| --- | --- |
| `template/install_robot_deps.sh` | Fix installation functions |
| `template/install_robot_deps.sh` | Remove empty APT commands |
| `template/install_robot_deps.sh` | Validate profile names |
| `template/init_setup.sh` | Create directories before copying |
| `setup.ini` | Add Gazebo and SO-101 profiles |
| Dockerfile | Ubuntu 24.04 compatibility |
| Dockerfile | ROS 2 Jazzy support |
| Scripts | NVIDIA validation |

## 14.1 Installation profiles

text

```text
minimal
    ROS 2 essentials

gazebo
    Gazebo-related development dependencies

so101
    ros2_control
    Feetech SDK
    Python dependencies

navigation
    Nav2

perception
    OpenCV
    PCL

full
    Selected robotics development dependencies
```

The Gazebo container remains independent of ROS 2.

The SO-101 container installs ROS 2 and LeRobot.

The final profile composition should be validated against the actual original ros2docker setup mechanism.

# 15\. Environment generation commands

## Generate a world

bash

```bash
python3 tools/generate_world.py \
    --config so101/config/environment.json \
    --output gazebo/worlds/table_world.sdf
```

## Export the environment

bash

```bash
python3 tools/generate_world.py \
    --config so101/config/environment.json \
    --output gazebo/worlds/table_world.sdf \
    --zip output/environment.zip
```

## Start Gazebo

bash

```bash
docker compose up -d gazebo
```

## Change the environment

1. Edit `environment.json`.
2. Generate a new SDF.
3. Stop Gazebo.
4. Start Gazebo again.

bash

```bash
docker compose stop gazebo

python3 tools/generate_world.py \
    --config so101/config/environment.json

docker compose up -d gazebo
```

No image rebuild is needed.

## Important improvement: randomization

The next version of the generator should support:

bash

```bash
python3 tools/generate_world.py \
    --config so101/config/environment.json \
    --randomize \
    --seed 42
```

Randomization should include:

- Object positions.
- Object rotations.
- Object dimensions within configured limits.
- Object colors.
- Object count.
- Camera positions.
- Table dimensions.

The generator should validate object collisions and table boundaries before producing the world.

A random seed must be saved alongside each dataset so that a training scene can be reproduced.

---

# 16\. Docker build scripts

## `scripts/build.sh`

bash

```bash
#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building Gazebo..."

docker compose build gazebo

echo "Building SO-101..."

docker compose build so101

echo "Build complete."
```

## `scripts/start.sh`

bash

```bash
#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

docker compose up -d

docker compose ps
```

## `scripts/stop.sh`

bash

```bash
#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

docker compose down
```

## `scripts/shell_gazebo.sh`

bash

```bash
#!/usr/bin/env bash

docker exec -it gazebo_sim bash
```

## `scripts/shell_so101.sh`

bash

```bash
#!/usr/bin/env bash

docker exec -it so101_environment bash
```

## `scripts/generate_world.sh`

bash

```bash
#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

python3 tools/generate_world.py \
    --config so101/config/environment.json \
    --output gazebo/worlds/table_world.sdf \
    --zip output/environment.zip
```

Make scripts executable:

bash

```bash
chmod +x scripts/*.sh
```

---

# 17\. Ubuntu 24.04 installation

Install Docker Engine and NVIDIA Container Toolkit.

Official documentation:

- Docker: https://docs.docker.com/engine/install/ubuntu/
- NVIDIA: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html

Check the GPU:

bash

```bash
nvidia-smi
```

Check Docker:

bash

```bash
docker --version

docker compose version
```

Check GPU access from Docker:

bash

```bash
docker run --rm --gpus all \
    nvidia/cuda:12.8.1-base-ubuntu24.04 \
    nvidia-smi
```

If the command succeeds, NVIDIA GPU access is working inside Docker.

---

# 18\. Build and launch

From the project root:

bash

```bash
./scripts/build.sh
```

Generate the environment:

bash

```bash
./scripts/generate_world.sh
```

Start the containers:

bash

```bash
./scripts/start.sh
```

Check the containers:

bash

```bash
docker compose ps
```

Open the Gazebo terminal:

bash

```bash
./scripts/shell_gazebo.sh
```

Open the SO-101 terminal:

bash

```bash
./scripts/shell_so101.sh
```

---

# 19\. Testing

These are the acceptance tests for the completed implementation.

## Test 1: Gazebo

bash

```bash
gz sim --versions
```

## Test 2: ROS 2

bash

```bash
source /opt/ros/jazzy/setup.bash

ros2 doctor
```

## Test 3: Gazebo Transport

bash

```bash
gz topic -l
```

## Test 4: ROS 2 controllers

bash

```bash
ros2 control list_controllers
```

## Test 5: Robot namespaces

bash

```bash
ros2 topic list | grep so101
```

Expected:

text

```text
/so101_01/joint_states
/so101_02/joint_states
/so101_03/joint_states
```

## Test 6: Gazebo communication

The SO-101 container should subscribe to each robot's Gazebo state topic and publish commands to its corresponding command topic.

Test:

bash

```bash
gz topic -l | grep so101
```

Then inspect a specific topic:

bash

```bash
gz topic -i -t /model/so101_01/joint_state
```

These tests require the custom Gazebo plugin and transport client to be implemented first.

---

# 20\. Dataset recording

The dataset structure should preserve the environment configuration.

text

```text
data/
└── datasets/
    └── pick_and_place_001/
        ├── environment.json
        ├── metadata.json
        ├── calibration/
        ├── images/
        └── episodes/
```

Example metadata:

json

```json
{
  "task": "pick_and_place",

  "robot": "so101_01",

  "backend": "gazebo",

  "world": "table_world",

  "environment_seed": 42,

  "objects": [
    "red_cube",
    "blue_cube",
    "green_cylinder"
  ],

  "camera": "overhead_camera",

  "ros_distro": "jazzy",

  "gazebo_version": "harmonic"
}
```

The environment configuration should be copied into the dataset directory whenever recording begins.

This ensures that the exact simulation can be reproduced later.

---

# 21\. Final implementation priorities

| Milestone | Deliverable | Status |
| --- | --- | --- |
| 01 | ros2docker bug fixes | Pending complete patch |
| 02 | Docker infrastructure | Starter configuration provided |
| 03 | Dynamic Gazebo world | Initial generator provided |
| 04 | SO-101 Gazebo model | Pending |
| 05 | Gazebo C++ plugin | Pending |
| 06 | ROS 2 hardware interface | Interface design provided |
| 07 | Feetech physical backend | Pending |
| 08 | LeRobot adapter | Interface design provided |
| 09 | Multi-robot support | Architecture defined |
| 10 | MoveIt 2 integration | Pending |
| 11 | RViz2 integration | Pending |
| 12 | Dataset recording | Architecture defined |
| 13 | Integration tests | Pending |

# 22\. Important technical requirements before production

There are several components that must be completed before this becomes a working robotics platform.

### A. SO-101 model

Use the official LeRobot SO-101 robot description as the starting point.

https://github.com/huggingface/lerobot

The model must include:

- Five arm joints.
- One gripper joint.
- Correct joint limits.
- Visual meshes.
- Collision meshes.
- Inertial parameters.
- Gazebo-compatible transmissions or plugin interfaces.

### B. Gazebo plugin

The custom Gazebo plugin must:

- Discover SO-101 models.
- Identify robots by model name.
- Publish joint states.
- Receive joint commands.
- Support multiple independent robots.
- Maintain independent command and state topics.

### C. ROS 2 hardware interface

The C++ hardware interface must:

- Implement `SystemInterface`.
- Connect to Gazebo Transport.
- Export the six joint interfaces.
- Handle communication timeouts.
- Support multiple instances.
- Allow switching between simulation and physical hardware.

### D. LeRobot

The Python adapter must use the actual LeRobot robot interface for the selected version.

It must support:

- Teleoperation.
- Observation retrieval.
- Action execution.
- Camera images.
- Dataset recording.
- Policy inference.

### E. Network isolation

The ROS 2 DDS domain and Gazebo Transport partition are separate settings.

For example:

bash

```bash
ROS_DOMAIN_ID=10
GZ_PARTITION=so101_simulation
```

Changing `ROS_DOMAIN_ID` must not prevent the SO-101 hardware interface from communicating with Gazebo.

---

# 23\. Final project goals

The final system should allow you to do something like:

bash

```bash
# Generate a new environment
python3 tools/generate_world.py \
    --config experiments/pick_and_place.json

# Start simulation
docker compose up -d

# Launch robot controllers
ros2 launch so101_bringup simulation.launch.py \
    robot_name:=so101_01

# Start LeRobot
python3 lerobot/teleoperate.py \
    --robot so101_01
```

Then change the environment:

bash

```bash
python3 tools/generate_world.py \
    --config experiments/stacking.json

docker compose restart gazebo
```

The same SO-101 ROS 2 and LeRobot installation should work with the new world.

---

# 24\. What I recommend implementing first

The most important next milestone is **01 — ros2docker\_fixed**.

I would not start implementing MoveIt or LeRobot policies before establishing that:

1. Both containers build.
2. Gazebo starts.
3. Gazebo Transport works across containers.
4. A robot can be spawned.
5. ROS 2 receives its joint states.
6. ROS 2 can command its joints.
7. Two robots can operate independently.

Once these seven tests pass, the foundation is ready for LeRobot integration.

**Important:** This Markdown document is the complete project specification and starter implementation supplied so far, not a tested release. Several critical source files, particularly the SO-101 model, Gazebo plugin and C++ hardware interface, still need implementation.

You can save everything above as:

`SO101_Gazebo_Project.md`

I recommend keeping this document as the project's main technical specification and updating it with every completed milestone.