# VirtIO-GPU Phase 3: capability report and 3D probe. The regression harness
# boots with -vga std, so the device is absent: both commands must say so and
# return cleanly instead of waiting on a queue that does not exist. The real
# ctx/submit/blob path runs under -display egl-headless with virtio-gpu-gl-pci.
gpu
gpu probe
