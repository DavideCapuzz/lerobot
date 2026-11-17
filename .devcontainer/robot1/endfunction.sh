#!/bin/bash

set -e

source /opt/ros/jazzy/setup.bash

cd /home/ubuntu/so101_ws

echo "======================================"
echo "SO-101 development environment"
echo "======================================"

echo "ROS_DISTRO: ${ROS_DISTRO}"
echo "ROS_DOMAIN_ID: ${ROS_DOMAIN_ID}"
echo "Gazebo partition: ${GZ_PARTITION}"

if [ -f install/setup.bash ]; then
    source install/setup.bash
fi

echo "SO-101 workspace ready."

exec sleep infinity
