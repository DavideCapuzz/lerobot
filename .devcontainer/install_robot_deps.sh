#!/bin/bash

set -e

PROFILE=${1:-default}
ROS_DISTRO=${ROS_DISTRO:-jazzy}

echo "======================================"
echo "Installing dependencies"
echo "Profile: ${PROFILE}"
echo "ROS: ${ROS_DISTRO}"
echo "======================================"


install_gazebo() {

    apt-get update

    apt-get install -y \
        ros-${ROS_DISTRO}-ros-gz \
        ros-${ROS_DISTRO}-ros-gz-bridge \
        ros-${ROS_DISTRO}-ros-gz-sim \
        ros-${ROS_DISTRO}-xacro

    rm -rf /var/lib/apt/lists/*
}


install_robot() {

    apt-get update

    apt-get install -y \
        build-essential \
        cmake \
        git \
        curl \
        wget \
        python3-pip \
        python3-venv \
        python3-colcon-common-extensions \
        python3-rosdep \
        python3-vcstool \
        python3-numpy \
        python3-opencv \
        ros-${ROS_DISTRO}-rviz2 \
        ros-${ROS_DISTRO}-moveit \
        ros-${ROS_DISTRO}-ros2-control \
        ros-${ROS_DISTRO}-ros2-controllers \
        ros-${ROS_DISTRO}-controller-manager \
        ros-${ROS_DISTRO}-joint-state-broadcaster \
        ros-${ROS_DISTRO}-joint-trajectory-controller \
        ros-${ROS_DISTRO}-robot-state-publisher \
        ros-${ROS_DISTRO}-joint-state-publisher \
        ros-${ROS_DISTRO}-xacro \
        ros-${ROS_DISTRO}-ros-gz-bridge \
        ros-${ROS_DISTRO}-ros-gz-sim \
        ros-${ROS_DISTRO}-rmw-cyclonedds-cpp

    rm -rf /var/lib/apt/lists/*
}


case "$PROFILE" in

    gazebo)
        install_gazebo
        ;;

    custom)
        install_robot
        ;;

    default)
        echo "No additional packages installed"
        ;;

    *)
        echo "Unknown profile: $PROFILE"
        exit 1
        ;;

esac

echo "Dependency installation completed."
