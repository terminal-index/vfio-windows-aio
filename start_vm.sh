#!/bin/bash
# Configuration and details are described on the main repository.

VM_DIR="/opt/windowsvm"
VBIOS="$VM_DIR/vbios.rom" 
DISK_IMAGE="$VM_DIR/windows11drive.qcow2" 
NVRAM="$VM_DIR/nvram.fd"

GPU_VIDEO="0000:01:00.0"
GPU_AUDIO="0000:01:00.1"
GPU_USB="0000:01:00.2"
GPU_SERIAL="0000:01:00.3"


echo "Stopping display manager..."
if systemctl is-active --quiet sddm; then
    DM="sddm"
    systemctl stop sddm
elif systemctl is-active --quiet gdm; then
    DM="gdm"
    systemctl stop gdm
else
    killall Hyprland
fi
sleep 2
echo "Unloading NVIDIA drivers..."

echo 0 > /sys/class/vtconsole/vtcon0/bind
echo 0 > /sys/class/vtconsole/vtcon1/bind

if [ -e "/sys/devices/platform/efi-framebuffer.0/driver" ]; then
    echo "efi-framebuffer.0" > /sys/devices/platform/efi-framebuffer.0/driver/unbind
fi


modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia i2c_nvidia_gpu


echo "Loading VFIO..."
modprobe vfio_pci vfio_iommu_type1

for dev in "$GPU_VIDEO" "$GPU_AUDIO" "$GPU_USB" "$GPU_SERIAL"; do
    vendor=$(cat /sys/bus/pci/devices/$dev/vendor)
    device=$(cat /sys/bus/pci/devices/$dev/device)
    if [ -e /sys/bus/pci/devices/$dev/driver ]; then
        echo "$dev" > /sys/bus/pci/devices/$dev/driver/unbind
    fi
    echo "$vendor $device" > /sys/bus/pci/drivers/vfio-pci/new_id
done

sleep 1

echo "Launching Windows..."

qemu-system-x86_64 \
  -name "win11-gaming" \
  -machine type=q35,accel=kvm,kernel_irqchip=on \
  -acpitable file=/opt/windowsvm/SSDT1.dat \
  -enable-kvm \
  -cpu host,l3-cache=on,kvm=off,hv_vendor_id=NV43FIX,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,+invtsc,migratable=no,hypervisor=off \
  -smp sockets=1,cores=12,threads=1 \
  -m 32G \
  -rtc clock=host,base=localtime \
  -nic user,model=virtio-net-pci,smb=/home/szoltysek \
  \
  -device qemu-xhci,id=xhci \
  \
  -device vfio-pci,host=01:00.0,multifunction=on,x-vga=on,romfile=/opt/windowsvm/vbios.rom,x-pci-sub-vendor-id=0x17aa,x-pci-sub-device-id=0x2297 \
  -device vfio-pci,host=01:00.1 \
  -device vfio-pci,host=01:00.2 \
  -device vfio-pci,host=01:00.3 \
  \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=$NVRAM \
  -object iothread,id=io1 \
  -device virtio-blk-pci,drive=disk0,iothread=io1 \
  -drive if=none,id=disk0,format=qcow2,file=$DISK_IMAGE \
  -drive file=/opt/windowsvm/virtio-win.iso,media=cdrom,index=2 \
  \
  -device usb-host,vendorid=0x320f,productid=0x511c `# Keyboard passthrough` \
  -device usb-host,vendorid=0x1038,productid=0x1840 `# SteelSeries mouse passthrough` \
  -device usb-host,vendorid=0x0d8c,productid=0x0005 `# Mic passthrough` \
  -device usb-host,vendorid=0x043e,productid=0x9a39 `# LG Monitor Hub passthrough` \
  \
  -audiodev alsa,id=snd0,out.dev=sysdefault:CARD=PCH,in.dev=sysdefault:CARD=PCH \
  -device ich9-intel-hda \
  -device hda-duplex,audiodev=snd0 \
  \
  -nic user,model=virtio-net-pci \
  -display none \
  -vga none \
  -serial none \
  -parallel none \
  -monitor stdio


echo "VM Powered off. Going back to Linux..."

# 1. Load NVIDIA modules first, to be ready to accept the device
echo "Loading NVIDIA modules..."
modprobe nvidia_drm
modprobe nvidia_modeset
modprobe nvidia_uvm
modprobe nvidia
modprobe i2c_nvidia_gpu

# 2. Device loop cleaning
echo "Unloading VFIO and restoring drivers..."

for dev in "$GPU_VIDEO" "$GPU_AUDIO" "$GPU_USB" "$GPU_SERIAL"; do
    vendor=$(cat /sys/bus/pci/devices/$dev/vendor)
    device=$(cat /sys/bus/pci/devices/$dev/device)

    echo "$vendor $device" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null

    if [ -e /sys/bus/pci/devices/$dev/driver/unbind ]; then
        echo "$dev" > /sys/bus/pci/devices/$dev/driver/unbind
    fi

    echo "" > /sys/bus/pci/devices/$dev/driver_override
    echo "$dev" > /sys/bus/pci/drivers_probe
done

echo "Restoring console..."
if [ -e "/sys/bus/platform/drivers/efi-framebuffer/bind" ]; then
    echo "efi-framebuffer.0" > /sys/bus/platform/drivers/efi-framebuffer/bind
fi
echo 1 > /sys/class/vtconsole/vtcon0/bind
echo 1 > /sys/class/vtconsole/vtcon1/bind

echo "Waking up GPU..."
nvidia-smi > /dev/null 2>&1
sleep 1

if [ -n "$DM" ]; then
    echo "Restarting $DM..."
    systemctl restart "$DM" --now
else
    echo "Display manager not present, returning to tty."
fi
