I'll rebuild the setup as a complete, copy-and-paste implementation, using the actual upstream `ros2docker` files as the starting point.

This version will distinguish between:

- **Unchanged upstream files:** no need to replace them.
- **Modified ros2docker files:** complete replacement contents.
- **New project files:** complete contents and exact paths.
- **Downloaded files:** commands to retrieve the original SO-101 description and dependencies.

I'm also correcting an important issue in the previous version: the original SO-101 URDF contains transmissions, but those transmissions do not automatically create Gazebo controllers. The first implementation will spawn the original model without claiming that simulated joint control is already working.

### Decisions retained

- Two containers: `gazebo` and `robot1`.
- Ubuntu 24.04 and ROS 2 Jazzy.
- Gazebo Harmonic.
- Original TheRobotStudio SO-101 model.
- URDF-to-SDF conversion at runtime.
- `ros_gz_bridge` inside `robot1`.
- Gazebo Transport between containers.
- Original `/home/ubuntu/ros2_ws` naming convention.
- Existing ros2docker generator and volume-generation architecture.
- No custom Dockerfile unless absolutely necessary.

# SO-101 Multicontainer — corrected implementation

## 1\. What changes compared with the previous version?

I'm making one important architectural improvement: **we won't replace the ros2docker Compose generator.**

Instead, we will:

- Keep `init_docker-compose.sh` unchanged.
- Keep the original Dockerfile and entrypoint.
- Fix `init_setup.sh` so errors stop generation and fallback directories exist.
- Add a small Python script that adjusts the generated Compose file.
- Preserve the generator's named-volume definitions.
- Keep all SO-101-specific configuration outside the ros2docker submodule.

This means the project-specific changes are modular and can be removed without rewriting ros2docker.

The upstream generator currently creates the same `src` and `launch` mounts for every service, then generates named volumes separately. Our post-processing step changes only the service-level mounts and preserves the top-level volume definitions.  GitHub

The original SO-101 repository provides the URDF and mesh assets in the `Simulation/SO101` directory. We will use those files directly.  GitHub+1

## 2\. Final architecture

text

```text
UBUNTU 24.04 HOST
       |
       | NVIDIA GPU
       |
       v
  DOCKER COMPOSE
       |
       +--------------------------+
       |                          |
       v                          v
   GAZEBO                    ROBOT1
   CONTAINER                 CONTAINER
   ---------                 ---------
   Ubuntu 24.04              Ubuntu 24.04
   ROS 2 Jazzy               ROS 2 Jazzy
   Gazebo Harmonic           RViz2
   Physics                   MoveIt 2
   World                     ros2_control
   Robot simulation          ros_gz_bridge
                             LeRobot
                             PyTorch
                             SO-101 workspace
       |                          |
       |                          |
       +--------------------------+
                 |
                 v
          GAZEBO TRANSPORT
             TCP / UDP
```

Communication:

| Communication | Protocol |
| --- | --- |
| Robot1 → Gazebo | Gazebo Transport |
| Gazebo → Robot1 | Gazebo Transport |
| Bridge → ROS nodes | ROS 2 DDS, inside robot1 |
| Robot1 → other future robots | ROS 2 DDS, configurable |

The containers will have different `ROS_DOMAIN_ID` values. The bridge is the only component that connects ROS messages to Gazebo Transport.

**Important:** Gazebo Transport discovery across Docker bridge networks must be tested. Sharing a network and `GZ_PARTITION` does not automatically guarantee multicast discovery.

---

## 3\. Final project structure

text

```text
lerobot_multibot/
│
├── .devcontainer/
│   │
│   ├── ros2docker/                 # Existing Git submodule
│   │
│   ├── setup.ini                   # Two-container configuration
│   ├── install_robot_deps.sh       # Custom dependency profiles
│   ├── generate_compose.sh         # Generation wrapper
│   ├── patch_compose.py            # Compose postprocessor
│   │
│   ├── gazebo/
│   │   └── endfunction.sh
│   │
│   └── robot1/
│       └── endfunction.sh
│
├── simulation/
│   └── worlds/
│       └── warehouse.sdf
│
├── robots/
│   └── so101/
│       │
│       ├── description/
│       │   └── original/
│       │       └── SO-ARM100/
│       │           └── Simulation/
│       │               └── SO101/
│       │                   ├── so101_new_calib.urdf
│       │                   ├── so101_old_calib.urdf
│       │                   ├── so101_new_calib.xml
│       │                   ├── scene.xml
│       │                   └── assets/
│       │
│       └── ros2_ws/
│           │
│           ├── src/
│           │   └── so101_bringup/
│           │       ├── CMakeLists.txt
│           │       ├── package.xml
│           │       ├── launch/
│           │       │   └── simulation.launch.py
│           │       └── config/
│           │           └── gazebo_bridge.yaml
│           │
│           ├── build/
│           ├── install/
│           └── log/
│
├── data/
│   └── lerobot/
│
├── .gitignore
└── README.md
```

Notice that:

- The complete SO-101 workspace exists only in `robot1`.
- Gazebo receives only the simulation world and robot description.
- The original SO-101 model is not modified.
- `build`, `install` and `log` are independent Docker volumes.

---

# PART A — Download and prepare the original model

## 4\. Download TheRobotStudio repository

From the project root:

bash

```bash
mkdir -p robots/so101/description/original

git clone \
    https://github.com/TheRobotStudio/SO-ARM100.git \
    robots/so101/description/original/SO-ARM100
```

The model we use is:

text

```text
robots/so101/description/original/SO-ARM100/Simulation/SO101/so101_new_calib.urdf
```

The corresponding meshes are in:

text

```text
robots/so101/description/original/SO-ARM100/Simulation/SO101/assets/
```

The original README explains the calibration conventions and the relationship between the URDF and MuJoCo models.

References:

- [TheRobotStudio SO-ARM100](<https://github.com/TheRobotStudio/SO-ARM100?utm_source=chatgpt.com>)
- [SO-101 documentation](<https://github.com/TheRobotStudio/SO-ARM100/blob/main/Simulation/SO101/README.md?utm_source=chatgpt.com>)
- [Original new-calibration URDF](<https://github.com/TheRobotStudio/SO-ARM100/blob/main/Simulation/SO101/so101_new_calib.urdf?utm_source=chatgpt.com>)

## 5\. Validate the original meshes

Run:

bash

```bash
cd robots/so101/description/original/SO-ARM100/Simulation/SO101
```

Check the files:

bash

```bash
ls -l so101_new_calib.urdf

ls assets/
```

Check every referenced mesh:

bash

```bash
python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

urdf = "so101_new_calib.urdf"
root = ET.parse(urdf).getroot()

missing = []

for mesh in root.findall(".//mesh"):
    filename = mesh.attrib["filename"]

    path = os.path.join(
        os.path.dirname(urdf),
        filename
    )

    if not os.path.isfile(path):
        missing.append(path)

if missing:
    print("Missing meshes:")
    for path in missing:
        print(path)
    raise SystemExit(1)

print("All referenced meshes exist.")
PY
```

Do not change the original URDF to solve a resource-path problem.

---

# PART B — ros2docker

## 6\. Clone ros2docker

If it is not already installed:

bash

```bash
git submodule add \
    https://github.com/DavideCapuzz/ros2docker.git \
    .devcontainer/ros2docker

git submodule update --init --recursive
```

We retain its existing:

- Dockerfile.
- Entrypoint.
- Compose generator.
- Template files.
- Workspace convention.

We will add only the project-specific files described below.

## 7\. Fix ros2docker init\_setup.sh

**Path:**

text

```text
.devcontainer/ros2docker/scripts/init_setup.sh
```

Replace the complete file with:

bash

```bash
#!/bin/bash

set -e

mkdir -p ./tmp
mkdir -p ./tmp/robot1

copy_or_template() {
    local source_file="$1"
    local template_file="$2"
    local destination="$3"
    local description="$4"

    if [ -f "$source_file" ]; then
        cp "$source_file" "$destination"
        echo "Copied $description"
    else
        cp "$template_file" "$destination"
        echo "Using template for $description"
    fi
}

if [ -f ../docker-compose.yml ]; then

    cp ../docker-compose.yml ./tmp/docker-compose.yml

    bash scripts/copy_endfunction.sh

elif [ -f ../setup.ini ]; then

    bash scripts/init_docker-compose.sh ../setup.ini

else

    cp template/docker-compose.yml ./tmp/docker-compose.yml

    copy_or_template \
        ../endfunction.sh \
        template/endfunction.sh \
        ./tmp/robot1/endfunction.sh \
        "endfunction.sh"

fi

copy_or_template \
    ../entrypoint.sh \
    template/entrypoint.sh \
    ./tmp/entrypoint.sh \
    "entrypoint.sh"

copy_or_template \
    ../install_robot_deps.sh \
    template/install_robot_deps.sh \
    ./tmp/install_robot_deps.sh \
    "install_robot_deps.sh"

echo "ros2docker initialization completed."
```

This fixes the fallback directory problem and ensures that a failing generator stops initialization.

We do not change `init_docker-compose.sh`.

---

# PART C — Two-container configuration

## 8\. setup.ini

**Path:**

text

```text
.devcontainer/setup.ini
```

Complete file:

ini

```ini
[gazebo]
install_profile=gazebo
ros_install=osrf/ros:jazzy-ros-base
ros_domain=42
network=ros2_network
volumes=
endfunction=gazebo/endfunction.sh


[robot1]
install_profile=custom
ros_install=osrf/ros:jazzy-desktop-full
ros_domain=0
network=ros2_network
volumes=build,install,log
endfunction=robot1/endfunction.sh
```

### Why these settings?

| Parameter | Gazebo | Robot1 |
| --- | --- | --- |
| Image | ROS base | ROS desktop full |
| ROS distribution | Jazzy | Jazzy |
| ROS domain | 42 | 0 |
| Network | ros2\_network | ros2\_network |
| Workspace | None mounted | Complete SO-101 workspace |
| Build volumes | None | Independent |
| Startup | Gazebo server | ROS environment |

Gazebo does not need the complete robot workspace.

Robot1 does.

The different ROS domains prevent accidental ROS 2 DDS communication between the containers.

Gazebo Transport is independent of these ROS domain IDs.

---

## 9\. install\_robot\_deps.sh

**Path:**

text

```text
.devcontainer/install_robot_deps.sh
```

Complete file:

bash

```bash
#!/bin/bash

set -e

PROFILE="${1:-custom}"
ROS_DISTRO="${ROS_DISTRO:-jazzy}"

echo "===================================="
echo "Installing dependencies"
echo "Profile: $PROFILE"
echo "ROS: $ROS_DISTRO"
echo "===================================="

install_common() {

    apt-get update

    apt-get install -y \
        x11-utils \
        python3-pip \
        python3-venv \
        python3-colcon-common-extensions \
        python3-rosdep \
        git \
        curl \
        wget

}

install_gazebo() {

    echo "Installing Gazebo Harmonic integration"

    apt-get update

    apt-get install -y \
        ros-${ROS_DISTRO}-ros-gz-sim

}

install_robot() {

    echo "Installing SO-101 ROS dependencies"

    apt-get update

    apt-get install -y \
        ros-${ROS_DISTRO}-ros-gz \
        ros-${ROS_DISTRO}-ros-gz-bridge \
        ros-${ROS_DISTRO}-ros-gz-sim \
        ros-${ROS_DISTRO}-robot-state-publisher \
        ros-${ROS_DISTRO}-xacro \
        ros-${ROS_DISTRO}-ros2-control \
        ros-${ROS_DISTRO}-ros2-controllers \
        ros-${ROS_DISTRO}-moveit

}

install_common

case "$PROFILE" in

    gazebo)

        install_gazebo
        ;;

    custom)

        install_robot
        ;;

    minimal)

        install_common
        ;;

    *)

        echo "Unknown profile: $PROFILE"
        echo "Available profiles: gazebo, custom, minimal"

        exit 1
        ;;

esac

apt-get clean

rm -rf /var/lib/apt/lists/*

echo "===================================="
echo "Installation completed"
echo "===================================="
```

A few important details:

- `x11-utils` provides `xdpyinfo`, which the ros2docker entrypoint uses.
- `ros-gz-sim` provides the Gazebo integration and spawning utility.
- `ros-gz-bridge` is installed in robot1.
- MoveIt and ros2\_control are installed in robot1, but we will configure them in later phases.
- LeRobot and PyTorch are installed separately.

The `gazebo` profile deliberately does not install the complete ROS desktop stack.

---

# PART D — Compose post-processing

## 10\. Why we need patch\_compose.py

The original generator mounts:

yaml

```yaml
volumes:
  - ../../../src:/home/ubuntu/ros2_ws/src
  - ../../../launch:/home/ubuntu/ros2_ws/launch
```

into every container.

That is not what we want.

We want:

Gazebo:

yaml

```yaml
volumes:
  - ../../../simulation:/simulation:ro
  - ../../../robots/so101/description/original/SO-ARM100/Simulation/SO101:/robot_assets/so101:ro
```

Robot1:

yaml

```yaml
volumes:
  - ../../../robots/so101/ros2_ws:/home/ubuntu/ros2_ws
  - ../../../robots/so101/description/original/SO-ARM100/Simulation/SO101:/robot_assets/so101:ro
  - ../../../data:/data
  - robot1_build:/home/ubuntu/ros2_ws/build
  - robot1_install:/home/ubuntu/ros2_ws/install
  - robot1_log:/home/ubuntu/ros2_ws/log
```

We also want:

- Unique Compose project name.
- GPU access for robot1.
- noVNC exposed only on localhost.
- No unnecessary raw VNC port publication.

Instead of modifying the original generator, we post-process its output.

## 11\. patch\_compose.py

**Path:**

text

```text
.devcontainer/patch_compose.py
```

Complete file:

python

```python
#!/usr/bin/env python3

import os
import re
import sys
from pathlib import Path


if len(sys.argv) != 2:
    print("Usage: patch_compose.py <docker-compose.yml>")
    sys.exit(1)


compose_file = Path(sys.argv[1])

if not compose_file.is_file():
    raise FileNotFoundError(compose_file)


project_root = Path(__file__).resolve().parent.parent

project_name = os.environ.get(
    "ROS2DOCKER_PROJECT_NAME",
    project_root.name.lower()
)

project_name = re.sub(
    r"[^a-z0-9_-]",
    "_",
    project_name
)


lines = compose_file.read_text().splitlines()


def find_service(name):

    pattern = re.compile(rf"^  {re.escape(name)}:\s*$")

    for i, line in enumerate(lines):

        if pattern.match(line):

            start = i

            end = len(lines)

            for j in range(i + 1, len(lines)):

                if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[j]):
                    end = j
                    break

                if re.match(r"^[A-Za-z][A-Za-z0-9_-]*:\s*$", lines[j]):
                    end = j
                    break

            return start, end

    raise RuntimeError(f"Service not found: {name}")


def replace_section(block, section, replacement):

    start = None

    for i, line in enumerate(block):

        if line == f"    {section}:":

            start = i
            break

    if start is None:

        block.extend(replacement)
        return block

    end = len(block)

    for j in range(start + 1, len(block)):

        if re.match(r"^    [A-Za-z0-9_-]+:", block[j]):
            end = j
            break

    return block[:start] + replacement + block[end:]


def patch_service(name, mounts, novnc_port, gpu=False):

    start, end = find_service(name)

    block = lines[start:end]

    # ------------------------------------------------
    # Service-specific volumes
    # ------------------------------------------------

    volume_lines = [
        "",
        "    volumes:",
    ]

    for mount in mounts:

        volume_lines.append(f"      - {mount}")

    block = replace_section(
        block,
        "volumes",
        volume_lines
    )

    # ------------------------------------------------
    # Ports: noVNC only, bound to localhost
    # ------------------------------------------------

    port_lines = [
        "",
        "    ports:",
        f'      - "127.0.0.1:{novnc_port}:{novnc_port}"',
    ]

    block = replace_section(
        block,
        "ports",
        port_lines
    )

    # ------------------------------------------------
    # GPU support
    # ------------------------------------------------

    if gpu:

        if not any(line.strip() == "gpus: all" for line in block):

            insert_at = 1

            for i, line in enumerate(block):

                if line.strip().startswith("container_name:"):

                    insert_at = i + 1
                    break

            block.insert(insert_at, "    gpus: all")

        for i, line in enumerate(block):

            if 'LIBGL_ALWAYS_SOFTWARE:' in line:

                block[i] = '      LIBGL_ALWAYS_SOFTWARE: "0"'

        environment_index = None

        for i, line in enumerate(block):

            if line == "    environment:":

                environment_index = i
                break

        if environment_index is not None:

            existing = "\n".join(block)

            if "NVIDIA_VISIBLE_DEVICES:" not in existing:

                block.insert(
                    environment_index + 1,
                    "      NVIDIA_VISIBLE_DEVICES: all"
                )

                block.insert(
                    environment_index + 2,
                    "      NVIDIA_DRIVER_CAPABILITIES: all"
                )

    # ------------------------------------------------
    # Write the modified service back
    # ------------------------------------------------

    lines[start:end] = block


# ----------------------------------------------------
# Add unique Compose project name
# ----------------------------------------------------

if not any(line.startswith("name:") for line in lines):

    service_index = next(
        i for i, line in enumerate(lines)
        if line == "services:"
    )

    lines.insert(
        service_index,
        f"name: {project_name}"
    )


# ----------------------------------------------------
# Gazebo
# ----------------------------------------------------

patch_service(
    name="gazebo",
    mounts=[
        "../../../simulation:/simulation:ro",
        "../../../robots/so101/description/original/SO-ARM100/Simulation/SO101:/robot_assets/so101:ro",
    ],
    novnc_port=6080,
)


# ----------------------------------------------------
# Robot1
# ----------------------------------------------------

patch_service(
    name="robot1",
    mounts=[
        "../../../robots/so101/ros2_ws:/home/ubuntu/ros2_ws",
        "../../../robots/so101/description/original/SO-ARM100/Simulation/SO101:/robot_assets/so101:ro",
        "../../../data:/data",
        "robot1_build:/home/ubuntu/ros2_ws/build",
        "robot1_install:/home/ubuntu/ros2_ws/install",
        "robot1_log:/home/ubuntu/ros2_ws/log",
    ],
    novnc_port=6081,
    gpu=True,
)


compose_file.write_text(
    "\n".join(lines) + "\n"
)

print("====================================")
print("Compose post-processing completed")
print("Project:", project_name)
print("GPU enabled: robot1")
print("Gazebo mounts: simulation + description")
print("Robot1 mounts: workspace + description + data")
print("VNC ports: localhost only")
print("====================================")
```

This script preserves the top-level `volumes:` and `networks:` sections generated by ros2docker.

It also retains the named-volume definitions generated from:

ini

```ini
volumes=build,install,log
```

The GPU configuration requires a sufficiently recent Docker Compose version and NVIDIA Container Toolkit on the host.

---

## 12\. generate\_compose.sh

**Path:**

text

```text
.devcontainer/generate_compose.sh
```

Complete file:

bash

```bash
#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROS2DOCKER_DIR="$SCRIPT_DIR/ros2docker"

cd "$ROS2DOCKER_DIR"

echo "Generating Compose using ros2docker..."

bash scripts/init_setup.sh

echo "Applying project-specific configuration..."

python3 "$SCRIPT_DIR/patch_compose.py" \
    tmp/docker-compose.yml

echo "Validating generated Compose..."

docker compose \
    -f tmp/docker-compose.yml \
    config

echo "===================================="
echo "Compose generation completed"
echo "===================================="
```

Make executable:

bash

```bash
chmod +x .devcontainer/generate_compose.sh
```

The resulting generated file remains:

text

```text
.devcontainer/ros2docker/tmp/docker-compose.yml
```

We preserve the original ros2docker output location.

# PART E — Container startup files

## 13\. Gazebo endfunction.sh

**Path:**

text

```text
.devcontainer/gazebo/endfunction.sh
```

Complete file:

bash

```bash
#!/bin/bash

set -e

ROS_DISTRO="${ROS_DISTRO:-jazzy}"

source "/opt/ros/${ROS_DISTRO}/setup.bash"

export GZ_SIM_RESOURCE_PATH="/robot_assets/so101:${GZ_SIM_RESOURCE_PATH:-}"

WORLD="/simulation/worlds/warehouse.sdf"

echo "===================================="
echo "Starting Gazebo Harmonic"
echo "===================================="

if [ ! -f "$WORLD" ]; then

    echo "ERROR: World not found: $WORLD"

    exit 1

fi

if ! command -v gz >/dev/null 2>&1; then

    echo "ERROR: Gazebo executable not found"

    exit 1

fi

exec gz sim -s -r "$WORLD"
```

This starts Gazebo in server-only mode.

It does not start an additional ROS 2 bridge.

Gazebo is responsible for physics and simulation.

## 14\. Robot1 endfunction.sh

**Path:**

text

```text
.devcontainer/robot1/endfunction.sh
```

Complete file:

bash

```bash
#!/bin/bash

set -e

ROS_DISTRO="${ROS_DISTRO:-jazzy}"

source "/opt/ros/${ROS_DISTRO}/setup.bash"

export GZ_SIM_RESOURCE_PATH="/robot_assets/so101:${GZ_SIM_RESOURCE_PATH:-}"

export SO101_URDF="/robot_assets/so101/so101_new_calib.urdf"

cd /home/ubuntu/ros2_ws

if [ -f install/setup.bash ]; then

    source install/setup.bash

fi

echo "===================================="
echo "SO-101 Robot Environment"
echo "===================================="

echo "ROS: $ROS_DISTRO"

echo "Workspace: /home/ubuntu/ros2_ws"

echo "Robot description: $SO101_URDF"

echo "Gazebo partition: $GZ_PARTITION"

if [ ! -f "$SO101_URDF" ]; then

    echo "ERROR: SO-101 URDF not found"

    exit 1

fi

# Start the window manager for RViz and other GUI applications.
openbox >/tmp/openbox.log 2>&1 &

# Keep the container running.
exec sleep infinity
```

Make both scripts executable:

bash

```bash
chmod +x .devcontainer/gazebo/endfunction.sh

chmod +x .devcontainer/robot1/endfunction.sh
```

---

# PART F — Gazebo simulation

## 15\. Gazebo world

**Path:**

text

```text
simulation/worlds/warehouse.sdf
```

Complete file:

xml

```xml
<?xml version="1.0"?>

<sdf version="1.9">

  <world name="warehouse">

    <gravity>0 0 -9.8</gravity>

    <physics name="default_physics" type="ignored">

      <max_step_size>0.001</max_step_size>

      <real_time_factor>1.0</real_time_factor>

      <real_time_update_rate>1000</real_time_update_rate>

    </physics>

    <!-- Physics engine -->

    <plugin
      filename="gz-sim-physics-system"
      name="gz::sim::systems::Physics">
    </plugin>

    <!-- Entity creation and deletion -->

    <plugin
      filename="gz-sim-user-commands-system"
      name="gz::sim::systems::UserCommands">
    </plugin>

    <!-- Scene updates -->

    <plugin
      filename="gz-sim-scene-broadcaster-system"
      name="gz::sim::systems::SceneBroadcaster">
    </plugin>

    <!-- Lighting -->

    <light name="sun" type="directional">

      <pose>0 0 10 0 0 0</pose>

      <cast_shadows>true</cast_shadows>

      <diffuse>0.8 0.8 0.8 1</diffuse>

      <specular>0.2 0.2 0.2 1</specular>

      <direction>-0.5 0.1 -0.9</direction>

    </light>

    <!-- Ground -->

    <model name="ground_plane">

      <static>true</static>

      <link name="link">

        <collision name="collision">

          <geometry>

            <plane>

              <normal>0 0 1</normal>

              <size>100 100</size>

            </plane>

          </geometry>

        </collision>

        <visual name="visual">

          <geometry>

            <plane>

              <normal>0 0 1</normal>

              <size>100 100</size>

            </plane>

          </geometry>

        </visual>

      </link>

    </model>

  </world>

</sdf>
```

This is a minimal physics world.

We will add tables, objects and other robots later.

---

# PART G — Robot1 ROS workspace

## 16\. Create the bringup package

Create:

text

```text
robots/so101/ros2_ws/src/so101_bringup/
```

The package will contain:

text

```text
so101_bringup/
│
├── CMakeLists.txt
├── package.xml
│
├── launch/
│   └── simulation.launch.py
│
└── config/
    └── gazebo_bridge.yaml
```

Create directories:

bash

```bash
mkdir -p robots/so101/ros2_ws/src/so101_bringup/launch

mkdir -p robots/so101/ros2_ws/src/so101_bringup/config
```

## 17\. package.xml

**Path:**

text

```text
robots/so101/ros2_ws/src/so101_bringup/package.xml
```

Complete file:

xml

```xml
<?xml version="1.0"?>

<package format="3">

  <name>so101_bringup</name>

  <version>0.1.0</version>

  <description>
    SO-101 Gazebo simulation bringup package.
  </description>

  <maintainer email="maintainer@example.com">
    SO-101 Development
  </maintainer>

  <license>Apache-2.0</license>

  <buildtool_depend>ament_cmake</buildtool_depend>

  <exec_depend>launch</exec_depend>

  <exec_depend>launch_ros</exec_depend>

  <exec_depend>robot_state_publisher</exec_depend>

  <exec_depend>ros_gz_bridge</exec_depend>

  <exec_depend>ros_gz_sim</exec_depend>

  <exec_depend>rosgraph_msgs</exec_depend>

  <export>

    <build_type>ament_cmake</build_type>

  </export>

</package>
```

## 18\. CMakeLists.txt

**Path:**

text

```text
robots/so101/ros2_ws/src/so101_bringup/CMakeLists.txt
```

Complete file:

cmake

```cmake
cmake_minimum_required(VERSION 3.8)

project(so101_bringup)

find_package(ament_cmake REQUIRED)

install(
    DIRECTORY
        launch
        config
    DESTINATION share/${PROJECT_NAME}
)

ament_package()
```

---

## 19\. Gazebo bridge configuration

**Path:**

text

```text
robots/so101/ros2_ws/src/so101_bringup/config/gazebo_bridge.yaml
```

Complete file:

yaml

```yaml
---

- ros_topic_name: "/clock"

  gz_topic_name: "/clock"

  ros_type_name: "rosgraph_msgs/msg/Clock"

  gz_type_name: "gz.msgs.Clock"

  direction: GZ_TO_ROS
```

For now, we only bridge simulation time.

We do not configure joint commands yet.

The official bridge documentation supports YAML configuration with `GZ_TO_ROS` and `ROS_TO_GZ` directions.  Gazebo

---

## 20\. Simulation launch file

**Path:**

text

```text
robots/so101/ros2_ws/src/so101_bringup/launch/simulation.launch.py
```

Complete file:

python

```python
import os

from launch import LaunchDescription

from launch.actions import TimerAction, ExecuteProcess

from launch_ros.actions import Node

from ament_index_python.packages import get_package_share_directory


def generate_launch_description():

    urdf_path = "/robot_assets/so101/so101_new_calib.urdf"

    package_share = get_package_share_directory(
        "so101_bringup"
    )

    bridge_config = os.path.join(
        package_share,
        "config",
        "gazebo_bridge.yaml"
    )

    # -------------------------------------------------
    # Original SO-101 URDF
    # -------------------------------------------------

    if not os.path.isfile(urdf_path):

        raise FileNotFoundError(
            f"SO-101 URDF not found: {urdf_path}"
        )

    with open(urdf_path, "r") as urdf_file:

        robot_description = urdf_file.read()

    # -------------------------------------------------
    # Robot State Publisher
    # -------------------------------------------------

    robot_state_publisher = Node(

        package="robot_state_publisher",

        executable="robot_state_publisher",

        name="robot_state_publisher",

        output="screen",

        parameters=[
            {
                "robot_description": robot_description,
                "use_sim_time": True,
            }
        ],

    )

    # -------------------------------------------------
    # Gazebo -> ROS clock bridge
    # -------------------------------------------------

    clock_bridge = Node(

        package="ros_gz_bridge",

        executable="parameter_bridge",

        name="clock_bridge",

        output="screen",

        parameters=[
            {
                "config_file": bridge_config
            }
        ],

    )

    # -------------------------------------------------
    # Spawn original URDF
    # -------------------------------------------------

    spawn_robot = ExecuteProcess(

        cmd=[

            "ros2",
            "run",
            "ros_gz_sim",
            "create",

            "-world",
            "warehouse",

            "-file",
            urdf_path,

            "-name",
            "so101",

            "-x",
            "0",

            "-y",
            "0",

            "-z",
            "0.05",

        ],

        output="screen",

    )

    delayed_spawn = TimerAction(

        period=5.0,

        actions=[
            spawn_robot
        ]

    )

    return LaunchDescription([

        clock_bridge,

        robot_state_publisher,

        delayed_spawn,

    ])
```

### Important correction about URDF spawning

We do not need to generate our own SDF file.

The `ros_gz_sim create` utility supports spawning URDF files directly. The official Gazebo documentation describes spawning models from a file.  Gazebo+1

We therefore use:

bash

```bash
ros2 run ros_gz_sim create \
    -world warehouse \
    -file /robot_assets/so101/so101_new_calib.urdf \
    -name so101
```

The original URDF remains untouched.

**Important limitation:** this launch file publishes the robot description and requests spawning. It does not provide simulated joint controllers. We must add those separately.

---

# PART H — Build and validation

## 21\. Validate mesh resources inside both containers

The description directory is mounted into both containers:

text

```text
/robot_assets/so101/
│
├── so101_new_calib.urdf
├── so101_old_calib.urdf
├── so101_new_calib.xml
├── scene.xml
└── assets/
```

Both startup scripts export:

bash

```bash
export GZ_SIM_RESOURCE_PATH="/robot_assets/so101:${GZ_SIM_RESOURCE_PATH:-}"
```

This allows Gazebo to search the directory containing the original relative mesh references.

After starting the containers, check robot1:

bash

```bash
docker exec -it robot1 bash
```

Run:

bash

```bash
ls -l /robot_assets/so101/so101_new_calib.urdf

ls /robot_assets/so101/assets/
```

Check Gazebo:

bash

```bash
docker exec -it gazebo bash
```

Run:

bash

```bash
ls -l /robot_assets/so101/assets/
```

The fact that the files are mounted does not prove that Gazebo successfully resolves every mesh. Check the simulator logs after spawning.

## 22\. Prepare the ROS workspace

Inside robot1:

bash

```bash
docker exec -it robot1 bash
```

Run:

bash

```bash
source /opt/ros/jazzy/setup.bash

cd /home/ubuntu/ros2_ws

rosdep update

rosdep install \
    --from-paths src \
    --ignore-src \
    -r -y

colcon build --symlink-install

source install/setup.bash
```

Check:

bash

```bash
ros2 pkg list | grep so101
```

Expected:

text

```text
so101_bringup
```

## 23\. NVIDIA GPU configuration

The postprocessor enables:

yaml

```yaml
gpus: all
```

for robot1.

It also sets:

yaml

```yaml
NVIDIA_VISIBLE_DEVICES: all
NVIDIA_DRIVER_CAPABILITIES: all
LIBGL_ALWAYS_SOFTWARE: "0"
```

On the host, verify:

bash

```bash
nvidia-smi
```

Check NVIDIA Container Toolkit:

bash

```bash
docker run --rm --gpus all \
    nvidia/cuda:12.8.0-base-ubuntu24.04 \
    nvidia-smi
```

You need a compatible NVIDIA driver and NVIDIA Container Toolkit.

Also use a Docker Compose version supporting the `gpus` service property.

The Gazebo server is initially CPU-based for physics. GPU access is assigned to robot1 for PyTorch.

---

# PART I — Start everything

## 24\. Generate Docker Compose

From the project root:

bash

```bash
chmod +x .devcontainer/generate_compose.sh

.devcontainer/generate_compose.sh
```

Generated file:

text

```text
.devcontainer/ros2docker/tmp/docker-compose.yml
```

## 25\. Inspect generated services

bash

```bash
docker compose \
    -f .devcontainer/ros2docker/tmp/docker-compose.yml \
    config --services
```

Expected:

text

```text
gazebo
robot1
```

Inspect mounts:

bash

```bash
docker compose \
    -f .devcontainer/ros2docker/tmp/docker-compose.yml \
    config
```

Verify:

- Gazebo does not mount the SO-101 ROS workspace.
- Robot1 mounts the complete workspace.
- Both mount the original description.
- Robot1 has independent build/install/log volumes.
- GPU access is enabled for robot1.
- noVNC ports are bound to localhost.
- The top-level named volumes still exist.

## 26\. Build the containers

bash

```bash
docker compose \
    -f .devcontainer/ros2docker/tmp/docker-compose.yml \
    build
```

## 27\. Start the containers

bash

```bash
docker compose \
    -f .devcontainer/ros2docker/tmp/docker-compose.yml \
    up -d
```

Check:

bash

```bash
docker ps
```

Expected:

text

```text
gazebo
robot1
```

## 28\. Inspect Gazebo

bash

```bash
docker logs -f gazebo
```

Expected:

- Gazebo executable found.
- World loaded.
- Physics system initialized.
- Scene broadcaster initialized.

## 29\. Access robot1

bash

```bash
docker exec -it robot1 bash
```

Source the workspace:

bash

```bash
source /opt/ros/jazzy/setup.bash

source /home/ubuntu/ros2_ws/install/setup.bash
```

Start the simulation:

bash

```bash
ros2 launch so101_bringup simulation.launch.py
```

The launch file will:

1. Start the clock bridge.
2. Start `robot_state_publisher`.
3. Wait five seconds.
4. Request the original SO-101 URDF to be spawned in Gazebo.

The five-second delay is only a basic startup allowance. If Gazebo is not ready, spawning can fail; in that case retry the spawn command after confirming the world is running.

## 30\. Check Gazebo Transport

Inside Gazebo:

bash

```bash
gz topic -l
```

Inside robot1:

bash

```bash
gz topic -l
```

Both containers must discover the same Gazebo partition and relevant simulation topics.

The generated Compose file currently sets:

yaml

```yaml
GZ_PARTITION: ros2_gz_partition
```

for both services.

If discovery does not work over the Docker bridge network, configure a Gazebo Transport Discovery Server or use an alternative networking configuration. Do not attempt to solve this by putting the containers in the same ROS domain.

## 31\. Check ROS topics

Inside robot1:

bash

```bash
ros2 topic list
```

Check the simulation clock:

bash

```bash
ros2 topic echo /clock
```

Check joint states:

bash

```bash
ros2 topic list | grep joint_states
```

At this stage, a working `/clock` bridge is expected.

**Do not expect working****`/joint_states`****yet.** We have not added a Gazebo joint-state publisher system.

---

# PART J — LeRobot and PyTorch

## 32\. Install LeRobot in robot1

We keep Python dependencies separate from the ROS system Python.

Inside robot1:

bash

```bash
python3 -m venv ~/lerobot_venv

source ~/lerobot_venv/bin/activate

pip install --upgrade pip

pip install lerobot
```

Install the appropriate CUDA-enabled PyTorch build using the official selector:

[PyTorch installation selector](<https://pytorch.org/get-started/locally/?utm_source=chatgpt.com>)

Then verify:

bash

```bash
python3 -c \
'import torch; print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else "No GPU")'
```

Expected:

text

```text
True
NVIDIA ...
```

Your LeRobot data directory is:

text

```text
/data/lerobot/
```

Inside the container:

bash

```bash
mkdir -p /data/lerobot
```

Official project:

[LeRobot documentation and repository](<https://github.com/huggingface/lerobot?utm_source=chatgpt.com>)

---

# PART K — Git and documentation

## 33\. .gitignore

**Path:**

text

```text
.gitignore
```

Complete file:

gitignore

```gitignore
# ROS 2
build/
install/
log/

# Python
__pycache__/
*.pyc
.venv/
venv/

# LeRobot datasets
data/lerobot/

# HuggingFace
.cache/

# IDE
.idea/
.vscode/

# Generated ros2docker files
.devcontainer/ros2docker/tmp/

# Environment
.env
.env.local

# OS
.DS_Store
Thumbs.db
```

Do not ignore:

text

```text
.devcontainer/ros2docker/
```

It is a Git submodule.

## 34\. README.md

**Path:**

text

```text
README.md
```

Complete file:

markdown

```markdown
# SO-101 LeRobot Multicontainer

Docker-based development environment for the SO-101 robot.

## System

- Ubuntu 24.04
- NVIDIA GPU
- ROS 2 Jazzy
- Gazebo Harmonic
- LeRobot
- PyTorch
- MoveIt 2
- ros2_control

## Architecture

Two independent containers.

### Gazebo

- Gazebo Harmonic
- Physics simulation
- Simulation worlds
- Robot spawning
- Gazebo Transport

### Robot1

- ROS 2 Jazzy
- SO-101 ROS workspace
- ros_gz_bridge
- RViz2
- MoveIt
- ros2_control
- LeRobot
- PyTorch

## Communication

Gazebo and robot1 communicate through Gazebo Transport.

The ros_gz_bridge runs in robot1.

The ROS 2 domains are separate.

## Original robot description

The SO-101 description is downloaded from:

https://github.com/TheRobotStudio/SO-ARM100

The original new-calibration URDF is used.

## Initialize submodules

    git submodule update --init --recursive

## Generate Compose

    .devcontainer/generate_compose.sh

## Build

    docker compose \
      -f .devcontainer/ros2docker/tmp/docker-compose.yml \
      build

## Start

    docker compose \
      -f .devcontainer/ros2docker/tmp/docker-compose.yml \
      up -d

## Enter Gazebo

    docker exec -it gazebo bash

## Enter robot1

    docker exec -it robot1 bash

## Build ROS workspace

    source /opt/ros/jazzy/setup.bash

    cd /home/ubuntu/ros2_ws

    rosdep install \
      --from-paths src \
      --ignore-src \
      -r -y

    colcon build --symlink-install

    source install/setup.bash

## Launch simulation

    ros2 launch so101_bringup simulation.launch.py

## Stop containers

    docker compose \
      -f .devcontainer/ros2docker/tmp/docker-compose.yml \
      down
```

# PART L — What is implemented and what comes next

## 35\. Current implementation versus future work

There is an important distinction between spawning the robot and controlling it.

The original SO-101 URDF provides:

- Link geometry.
- Collision geometry.
- Inertial properties.
- Joint definitions.
- Joint limits.
- Transmission descriptions.

It does not provide a complete Gazebo control integration.

Therefore, the current implementation provides the following:

| Feature | Status |
| --- | --- |
| Two independent containers | Configured |
| Gazebo Harmonic installation | Configured |
| Gazebo world | Implemented |
| Original SO-101 URDF | Reused |
| Original mesh assets | Mounted |
| URDF spawning | Configured |
| ROS 2 robot description | Configured |
| Gazebo-to-ROS clock bridge | Configured |
| NVIDIA access for robot1 | Configured |
| LeRobot installation | Manual installation |
| Joint-state feedback | Not implemented |
| Joint position controllers | Not implemented |
| ros2\_control hardware integration | Not implemented |
| MoveIt configuration | Not implemented |

These files are an implementation starting point, not a verified running system. In particular, validate the original URDF's mesh resolution and spawning against your actual Gazebo image before proceeding.

## 36\. Next development phases

I recommend implementing the remaining functionality in this order.

### Phase 1 — Simulation

text

```text
Gazebo
  |
  +-- World
  |
  +-- SO-101 URDF
  |
  +-- Physics
  |
  +-- Robot spawning
```

### Phase 2 — Joint feedback

Add Gazebo's:

text

```text
JointStatePublisher
```

Bridge joint feedback into robot1:

text

```text
Gazebo
   |
   | Gazebo Transport
   v
ros_gz_bridge
   |
   | ROS 2
   v
/joint_states
```

### Phase 3 — Joint commands

Add Gazebo native joint controllers.

For example:

text

```text
ROS 2 Controller
       |
       v
ros_gz_bridge
       |
       | Gazebo Transport
       v
Gazebo Joint Controller
       |
       v
SO-101
```

Relevant documentation:

- [Gazebo JointPositionController](<https://gazebosim.org/api/sim/10/classgz_1_1sim_1_1systems_1_1JointPositionController.html?utm_source=chatgpt.com>)
- [Gazebo JointStatePublisher](<https://gazebosim.org/api/sim/10/classgz_1_1sim_1_1systems_1_1JointStatePublisher.html?utm_source=chatgpt.com>)

### Phase 4 — ros2\_control

Configure the SO-101 hardware interface in robot1.

One architectural decision remains: whether to use Gazebo's `gz_ros2_control` plugin or a custom Gazebo Transport hardware interface.

For your strict container separation, I would investigate the second option first.

### Phase 5 — MoveIt

Add:

text

```text
robots/so101/ros2_ws/src/
    so101_moveit_config/
```

Use the original SO-101 joint names and geometry.

### Phase 6 — LeRobot

Connect the LeRobot policy to the ROS 2 control interface.

Eventually:

text

```text
              LeRobot
                 |
                 v
          ROS 2 Controller
                 |
                 v
            ros_gz_bridge
                 |
                 v
              Gazebo
                 |
                 v
              SO-101
```

---

## 37\. Important references

| Component | Documentation |
| --- | --- |
| ros2docker | [GitHub repository](<https://github.com/DavideCapuzz/ros2docker?utm_source=chatgpt.com>) |
| SO-ARM100/SO-101 | [GitHub repository](<https://github.com/TheRobotStudio/SO-ARM100?utm_source=chatgpt.com>) |
| Gazebo Harmonic | [Gazebo documentation](<https://gazebosim.org/docs/harmonic/?utm_source=chatgpt.com>) |
| ROS-Gazebo integration | [ROS-Gazebo documentation](<https://gazebosim.org/docs/harmonic/ros2_integration/?utm_source=chatgpt.com>) |
| ros\_gz\_bridge | [Bridge documentation](<https://github.com/gazebosim/ros_gz/blob/ros2/ros_gz_bridge/README.md?utm_source=chatgpt.com>) |
| ros2\_control | [ros2\_control documentation](<https://control.ros.org/jazzy/index.html?utm_source=chatgpt.com>) |
| MoveIt 2 | [MoveIt documentation](<https://moveit.picknik.ai/main/index.html?utm_source=chatgpt.com>) |
| LeRobot | [LeRobot repository](<https://github.com/huggingface/lerobot?utm_source=chatgpt.com>) |

---

## 38\. Final design principles

The architecture deliberately follows these rules:

1. Do not modify the original SO-101 URDF.
2. Do not duplicate robot geometry.
3. Do not put the SO-101 ROS workspace inside Gazebo.
4. Do not put Gazebo-specific robot controllers inside the original model repository.
5. Keep `ros_gz_bridge` inside robot1.
6. Use Gazebo Transport between containers.
7. Keep ROS 2 DDS domains separate between containers.
8. Preserve ros2docker's original naming convention.
9. Preserve independent build/install/log volumes.
10. Add future functionality through separate ROS packages.

**One final point about ros2docker:** use the previously bug-fixed copy of the submodule as your starting point. The only additional ros2docker source-file replacement in this implementation is `scripts/init_setup.sh`; the Compose generator itself remains unchanged.

This gives you a relatively clean foundation for adding robot2, robot3 and additional simulators later without redesigning the container architecture.

:::