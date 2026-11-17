#!/bin/bash

set -e

source /opt/ros/jazzy/setup.bash

WORLD=/simulation/worlds/warehouse.sdf

export GZ_SIM_RESOURCE_PATH="/robot_assets/so101:${GZ_SIM_RESOURCE_PATH:-}"

echo "======================================"
echo "Starting Gazebo Harmonic"
echo "======================================"

echo "World: ${WORLD}"
echo "Partition: ${GZ_PARTITION}"

if [ ! -f "$WORLD" ]; then
    echo "ERROR: World not found: $WORLD"
    exit 1
fi

exec gz sim -s -r "$WORLD"
