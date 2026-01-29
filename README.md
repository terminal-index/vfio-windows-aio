# vfio-windows-aio - Windows on Linux Without Rebooting

This is a **2-in-1 system implementation** with a single `.sh` script that allows you to run Windows inside Linux without requiring a reboot. It uses GPU passthrough (VFIO) technology to give the Windows virtual machine direct access to your dedicated GPU, providing near-native gaming performance while keeping your Linux host system intact (you can use both - Windows with GUI and Linux via SSH).

**Designed for**: NVIDIA GPU + Intel CPU  
**Compatibility**: May also work with AMD GPUs and CPUs with minor adjustments

> **My testing configuration**: Lenovo ThinkPad P53 • Intel i7-9850H • 128GB RAM • NVIDIA Quadro RTX 5000 Max-Q 16GB

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
  - [Creating the VM Directory](#creating-the-vm-directory)
  - [VBIOS Patching](#vbios-patching)
  - [Finding PCI Addresses](#finding-pci-addresses)
- [Initial Windows Installation](#initial-windows-installation)
- [What the Script Does](#what-the-script-does)
  - [Step 1: Stopping the Display Manager](#step-1-stopping-the-display-manager)
  - [Step 2: Unbinding NVIDIA Drivers](#step-2-unbinding-nvidia-drivers)
  - [Step 3: Loading VFIO Modules](#step-3-loading-vfio-modules)
  - [Step 4: Launching QEMU](#step-4-launching-qemu)
  - [Step 5: Returning to Linux](#step-5-returning-to-linux)
- [QEMU Configuration Explained](#qemu-configuration-explained)
- [Known Issues](#known-issues)

## Overview

Main script (`start_vm.sh`) automates the process of:
1. Shutting down your Linux display manager (SDDM, GDM, or Hyprland*)
2. Unbinding the NVIDIA GPU from Linux drivers
3. Binding the GPU to VFIO drivers for passthrough
4. Launching a Windows virtual machine with direct GPU access
5. Returning control to Linux after shutdown

The result is a seamless transition between Linux and Windows without rebooting your computer.

## Prerequisites

- **Hardware**: IOMMU-capable CPU and motherboard (Intel VT-d or AMD-Vi - AMD not tested, but may work!)
- **Software**: 
  - QEMU/KVM
  - OVMF (UEFI firmware for virtual machines)
  - VFIO kernel modules
  - virtio-win drivers ISO
- **BIOS Settings**: Enable IOMMU/VT-d/AMD-Vi in your BIOS
- **Kernel Parameters**: Add `intel_iommu=on iommu=pt` (Intel CPU) or `amd_iommu=on iommu=pt` (AMD CPU) to your bootloader

## Setup

### Creating the VM Directory

You need to create a directory in `/opt` to store your VM files:

```bash
# Create the directory
sudo mkdir -p /opt/windowsvm

# Set appropriate permissions
sudo chown $USER:$USER /opt/windowsvm

# Create the disk image (adjust size as needed)
qemu-img create -f qcow2 /opt/windowsvm/emugaming.qcow2 256G

# Create NVRAM file
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd /opt/windowsvm/nvram.fd

# Download virtio-win drivers from Fedora Repository
wget -O /opt/windowsvm/virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.240/virtio-win.iso
```

#### Understanding the VM Files

**What is a `.qcow2` file?**

QCOW2 is a virtual disk image format used by QEMU. It's a virtual root drive for your Windows Virtual Machine (the C: drive).

Key features:
- **Dynamic sizing**: The file starts small and grows as you install software (up to the maximum size you specified)
- **Space efficient**: A 256GB `.qcow2` file only takes up actual disk space for the data written to it
- **Snapshot support**: Allows you to save VM states and revert if needed
- **Compression**: Supports internal compression to save disk space

To create a `.qcow2` file with desired size:
```bash
# Change [size] to desired size: 128GB = 128G etc; 1024GB = 1TB = 1T
qemu-img create -f qcow2 /opt/windowsvm/windows11drive.qcow2 [size]

```

To check actual disk usage vs. allocated size:
```bash
qemu-img info /opt/windowsvm/windows11drive.qcow2
```

**What is `nvram.fd`?**

The `nvram.fd` file stores UEFI (BIOS) variables for your virtual machine. It's essentially the emulation of NVRAM chip that would exist on a physical motherboard. But it doesn't since this is a Virtual Machine - that's why we need to emulate it. Obvious.

What it contains:
- **UEFI boot entries**: Information about bootable devices and boot order
- **Secure Boot keys**: Cryptographic keys (if Secure Boot is enabled)
- **UEFI settings**: Firmware configuration that persists across reboots
- **Hardware configuration**: Settings saved by the UEFI firmware

Why you need it:
- **Persistence**: Without it, UEFI settings would reset on every boot
- **Boot management**: Windows stores its boot loader registration here
- **Unique per VM**: Each VM needs its own `nvram.fd` file to maintain separate UEFI settings

The file is copied from the OVMF template:
```bash
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd /opt/vm-gaming/nvram.fd

# files in /usr/share/edk2/x64/ are installed default with QEMU package

```

> **Important**: The `nvram.fd` file is **writable** and will be modified by the VM as it saves UEFI settings. If you ever need to reset your VM's UEFI settings, simply delete this file and copy a fresh one from the template.

### VBIOS Patching Guide

> **Note**: This section is for advanced users who need to patch their GPU's VBIOS ROM.

**Why patch VBIOS?** Some NVIDIA GPUs require a patched VBIOS ROM to work properly in a VM. The UEFI headers in the stock VBIOS can cause issues, so we need to remove them.
#### Tools required:
- TechPowerUp's [nvflash](https://www.techpowerup.com/download/nvidia-nvflash/): NVIDIA GPU BIOS flashing tool
- [Okteta](https://apps.kde.org/pl/okteta/): Hex editor for patching the ROM
#### Step 1: Prepare Your System

Before dumping the VBIOS, you need to unload NVIDIA drivers:

1. **Switch to TTY** (text console):
   - Press `Ctrl + Alt + F3` (or F2, F4, depending on your system)
   - Log in with your username and password

2. **Stop your display manager**:
   ```bash
   sudo systemctl stop sddm
   # or
   sudo systemctl stop gdm
   # or whatever you use
   ```
3. **Unload NVIDIA kernel modules**:
   ```bash
   sudo modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia i2c_nvidia_gpu
   ```
#### Step 2: Dump the VBIOS

Once NVIDIA drivers are unloaded, use nvflash to dump your GPU's VBIOS:

```bash
# Make nvflash executable
sudo chmod +x nvflash

# Dump the VBIOS ROM
sudo ./nvflash --save vbios.rom
```

This will create a `vbios.rom` file in your current directory.

#### Step 3: Copy VBIOS to VM Folder

```bash
# Copy the dumped ROM to your VM directory
cp vbios.rom /opt/windowsvm/vbios.rom
```
#### Step 4: Patch the VBIOS with Okteta

Now we need to remove the UEFI headers from the ROM:

1. **Install Okteta** (if not already installed).

2. **Open the VBIOS in Okteta**:
   ```bash
   okteta /opt/windowsvm/vbios.rom
   ```

3. **Find the VIDEO string**:
   - Press `Ctrl + F` to open search
   - Change search type to **"Char"**
   - Search for: `VIDEO`

4. **Remove everything before VIDEO**:
   - Select all bytes **before** the first occurrence of `VIDEO`
   - Delete them

   ![Example of Okteta identifying VIDEO string](assets/vbios-example.png)
   
5. **Save as patched ROM**:
   - Save as: `/opt/windowsvm/vbios-patched.rom`
   - **DO NOT OVERWRITE** the original `vbios.rom`!

#### Step 5: Use the Patched VBIOS

Update your `start_vm.sh` or QEMU config to use `/opt/windowsvm/vbios-patched.rom`.

### Finding PCI Addresses

You need to identify the PCI addresses of your GPU components. Run the following command:

```bash
lspci -nn | grep -i nvidia
```

Example output:
```
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation TU104GLM [Quadro RTX 5000 Mobile / Max-Q] [10de:1eb5] (rev a1)
01:00.1 Audio device [0403]: NVIDIA Corporation TU104 HD Audio Controller [10de:10f8] (rev a1)
01:00.2 USB controller [0c03]: NVIDIA Corporation TU104 USB 3.1 Host Controller [10de:1ad8] (rev a1)
01:00.3 Serial bus controller [0c80]: NVIDIA Corporation TU104 USB Type-C UCSI Controller [10de:1ad9] (rev a1)
```

In the script, update these lines with your actual PCI addresses:

```bash
GPU_VIDEO="0000:01:00.0"    # VGA controller
GPU_AUDIO="0000:01:00.1"    # Audio device
GPU_USB="0000:01:00.2"      # USB controller
GPU_SERIAL="0000:01:00.3"   # Serial bus controller
```

## Initial Windows Installation

Before using the `start_vm.sh` script for daily use, you need to install Windows on the virtual machine. Here's how:

1. **Download Windows 11 ISO** from @massgravel [massgrave.dev (🤎)](https://massgrave.dev/genuine-installation-media) or Microsoft website.

2. **Create a basic QEMU installation script** (e.g., `windows.sh`):

```bash
#!/bin/bash
VM_DIR="/opt/windowsvm"
DISK_IMAGE="$VM_DIR/windows11drive.qcow2" `# Earlier created .qcow2 drive`
NVRAM="$VM_DIR/nvram.fd"
WINDOWS_ISO="/path/to/downloaded/windows.iso"  `# Update this path`

qemu-system-x86_64 \
  -name "windows11" \
  -machine type=q35,accel=kvm \
  -enable-kvm \
  -cpu host \
  -smp cores=4,threads=2 \ `# Remember to change this part to correct Core/Thread count`
  -m 8G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=$NVRAM \
  -drive if=none,id=disk0,format=qcow2,file=$DISK_IMAGE \
  -device virtio-blk-pci,drive=disk0 \
  -drive file=$WINDOWS_ISO,media=cdrom,index=0 \
  -drive file=/opt/windowsvm/virtio-win.iso,media=cdrom,index=1 \
  -net nic,model=virtio \
  -net user \
  -vga qxl \
  -device qemu-xhci \
  -device usb-tablet
```

3. **Run the installation**:
```bash
chmod +x install_windows.sh
sudo ./install_windows.sh
```

4. **During Windows installation**:
   - When asked for a disk, click "Load driver" and browse to the virtio-win CD (E:\ or D:\)
   - Navigate to `vioscsi\w11\amd64` and install the Red Hat VirtIO SCSI driver
   - Your disk should now appear in the list
   - Complete the Windows installation normally

5. **After installation**:
   - Install all virtio drivers from the virtio-win CD (network, balloon, controller, etc.)
   - (*Optional*) Activate your Windows with @massgravel [massgrave.dev](https://massgrave.dev/) script (recommended) or purchased Windows Key.
   - Install your GPU drivers (NVIDIA or AMD)
   - Install games and configure Windows as desired

6. **Now you can use** `start_vm.sh` for Windows VM with NVIDIA GPU Passthrough working.

## What the Script Does

### Step 1: Stopping the Display Manager

The script first identifies and stops your display manager (SDDM or GDM) or Hyprland compositor:

```bash
systemctl stop sddm  # or gdm, there's an automatic DM detection.
```

This is necessary because Linux must release control of the GPU before it can be passed to the VM.

### Step 2: Unbinding NVIDIA Drivers

The script unbinds the virtual consoles and NVIDIA drivers from the GPU:

```bash
# Unbind virtual consoles
echo 0 > /sys/class/vtconsole/vtcon0/bind
echo 0 > /sys/class/vtconsole/vtcon1/bind

# Remove NVIDIA kernel modules
modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia i2c_nvidia_gpu
```

This ensures that no Linux driver is using the GPU when we attempt passthrough.

### Step 3: Loading VFIO Modules

The script loads VFIO (Virtual Function I/O) modules and binds each GPU component to the VFIO driver:

```bash
modprobe vfio_pci vfio_iommu_type1

# Bind each GPU component to VFIO
for dev in GPU_VIDEO GPU_AUDIO GPU_USB GPU_SERIAL; do
    # 1. Read vendor and device IDs defined earlier in the script
    # 2. Unbind from current driver (Linux)
    # 3. Bind to vfio-pci driver
done
```

VFIO allows userspace programs (like QEMU) to directly access PCI devices.

### Step 4: Launching QEMU

The script launches QEMU with the Windows VM, passing through the GPU and other devices. See [QEMU Configuration Explained](#qemu-configuration-explained) for details.

### Step 5: Returning to Linux

After the VM shuts down, the script automatically:
1. Reloads NVIDIA kernel modules
2. Unbinds devices from VFIO
3. Restores devices to their original drivers (at least it tries)
4. Restores the virtual console
5. Restarts the display manager

> **Note**: See [Known Issues](#known-issues) for limitations.

## QEMU Configuration Explained

The QEMU command in this script is heavily configured to provide optimal performance and compatibility. Here's what each section does:

### Machine Type and Acceleration

```bash
-machine type=q35,accel=kvm,kernel_irqchip=on
```

- **q35**: Modern Intel chipset emulation (recommended over older i440fx)
- **accel=kvm**: Use KVM hardware acceleration for near-native performance
- **kernel_irqchip=on**: Improves interrupt performance

### ACPI Table (Laptop Specific)

```bash
-acpitable file=/opt/windowsvm/SSDT1.dat
```

**⚠️ IMPORTANT FOR LAPTOP USERS**: This ACPI table provides artificial battery status to the VM, which is required for NVIDIA mobile GPUs to function properly. NVIDIA drivers check for battery presence and may not initialize correctly without it.

**⚠️ YOU MUST GENERATE YOUR OWN ACPI TABLE** if you're on a laptop. This file is specific to your hardware - please refer to [Arch Wiki's PCI Passthrough via OVMF]('https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF#%22Error_43:_Driver_failed_to_load%22_with_mobile_(Optimus/max-q)_nvidia_GPUs') guide.

### CPU Configuration

```bash
-cpu host,l3-cache=on,kvm=off,hv_vendor_id=NV43FIX,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,+invtsc,migratable=no,hypervisor=off
```

**QEMU is configured to hide the fact that it's a virtual machine.** Here's why each flag matters:

- **host**: Pass through your actual CPU model for best compatibility
- **kvm=off**: Hide KVM from the guest
- **hv_vendor_id=NV43FIX**: **REQUIRED FOR NVIDIA GPUs** - Sets a custom Hyper-V vendor ID. NVIDIA drivers detect virtual machines and refuses to load driver. This spoofs the vendor ID to bypass QEMU/VM detection.
- **hypervisor=off**: Hide the hypervisor CPUID bit
- **hv_relaxed, hv_spinlocks, hv_vapic, hv_time**: Hyper-V enlightenments for better Windows performance
- **+invtsc**: Provides invariant TSC for better timekeeping
- **migratable=no**: Disables migration features for performance

### CPU Cores

```bash
-smp sockets=1,cores=12,threads=1
```

**⚠️ YOU MUST ADJUST THIS**: Change `cores=12` to match your desired core allocation. For best performance, allocate half or 3/4 of your physical cores. Never allocate all cores, as the host needs some for overhead.

### Memory

```bash
-m 32G
```

Allocates 32GB of RAM to the VM. Adjust based on your system's available memory.

### Network

```bash
-nic user,model=virtio-net-pci,smb=/home/[Your-Linux-Username]
```

- **user networking**: Simple NAT networking (no bridge required)
- **virtio-net-pci**: High-performance virtual network adapter
- **smb=/home/[Your-Linux-Username]**: Shares the Linux's home directory to Windows via SMB. Fast and easy.

### GPU Passthrough

```bash
-device vfio-pci,host=01:00.0,multifunction=on,x-vga=on,romfile=/opt/vm-gaming/vbios.rom,x-pci-sub-vendor-id=0x17aa,x-pci-sub-device-id=0x2297
-device vfio-pci,host=01:00.1  # Audio
-device vfio-pci,host=01:00.2  # USB
-device vfio-pci,host=01:00.3  # Serial
```

- **multifunction=on**: Required for multi-function PCI devices
- **x-vga=on**: Enables VGA arbitration for the primary GPU
- **romfile**: Custom VBIOS ROM (needed if patched)
- **x-pci-sub-vendor-id/device-id**: Sets subsystem IDs (laptop-specific, may help with mobile GPU detection)

### Storage

```bash
-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd
-drive if=pflash,format=raw,file=$NVRAM
```

UEFI firmware (OVMF) for booting Windows.

```bash
-object iothread,id=io1
-device virtio-blk-pci,drive=disk0,iothread=io1
-drive if=none,id=disk0,format=qcow2,file=$DISK_IMAGE
```

- **iothread**: Dedicated I/O thread for better disk performance
- **virtio-blk-pci**: High-performance virtual block device

### USB Passthrough

```bash
-device usb-host,vendorid=0x320f,productid=0x511c  # Keyboard
-device usb-host,vendorid=0x1038,productid=0x1840  # Mouse
```

Passes through specific USB devices by vendor/product ID. Find your device IDs with:

```bash
lsusb
```

### Audio

```bash
-audiodev alsa,id=snd0,out.dev=sysdefault:CARD=PCH,in.dev=sysdefault:CARD=PCH
-device ich9-intel-hda
-device hda-duplex,audiodev=snd0
```

Provides audio passthrough from the host to the VM.
> **Note:** Host needs to set the volume to 100%.
### Display

```bash
-display none
-vga none
```

No virtual display is used because the VM outputs directly to the physical monitor through the passed-through GPU. Elsewise it'll not work.

## ⚠️  Known Issues

### 1. NVIDIA Driver Recovery After VM Shutdown

**Issue**: After shutting down the Windows VM, the system successfully returns to Linux, but the NVIDIA GPU cannot be fully restored until the computer is rebooted.

**Symptoms**:
- Linux desktop may run on integrated graphics or software rendering
- `nvidia-smi` may show errors or no GPU detected
- Display manager restarts but GPU acceleration is unavailable

**Workaround**: Reboot the system to fully restore NVIDIA functionality in Linux.

**Root Cause**: The NVIDIA proprietary driver has difficulty re-initializing the GPU after it has been reset from VFIO passthrough. This is a known limitation of the current driver architecture.

**Future Solutions**:
- Fix the script's driver reloading
- Use the open-source `nouveau` driver for Linux (limited gaming performance)?
- Wait for better NVIDIA driver support for dynamic rebinding
- Consider using AMD GPUs, which generally have better VFIO support (and anything related to Linux support. We [love](https://geekpedia.pl/wp-content/uploads/2024/10/linus_torvalds_krytykuje_technologicznych_gigantow_1.webp) you NVIDIA!)

### 2. Audio Volume Too Low in Windows VM

**Issue**: Audio in the Windows VM may be too quiet, even when Windows volume is set to 100%.

**Symptoms**:
- Audio playback in the VM is noticeably quieter than expected
- Increasing Windows volume doesn't help
- Audio works but requires very high volume settings on external speakers/headphones

**Workaround**: Set the Linux host audio volume to **100%** before starting the VM.

**How to fix**:
- The CLI way:
```bash
# Check current volume levels
amixer get Master

# Set volume to 100% on the host before launching VM
amixer set Master 100%

# Or use PipeWire/PulseAudio commands
pactl set-sink-volume @DEFAULT_SINK@ 100%
```
- The GUI way: 
`Use any volume manager to increase the volume.`

**Root Cause**: QEMU's ALSA audio passthrough forwards audio at the host's current volume level. If the host volume is set to 50%, the VM receives audio at that reduced level, which cannot be amplified within the VM.

**Alternative Solutions**:
- Add a volume control script before launching the VM in `start_vm.sh`
- Use PipeWire/PulseAudio for better audio routing (may require different QEMU audio configuration)
- Consider using SCREAM (network audio) or Looking Glass with audio support for better audio quality
---

## Contributing

If you discover improvements or solutions to known issues, please **open an issue** to discuss them or submit a Pull Request! All contributions are welcome to make this script better for everyone.

## Support My Work

If this project helped you run your favorite games on Linux, consider supporting my "research" (and energy drink consumption ☕) - especially since I'm a student at **SUT (Silesian University of Technology)**:
- [GitHub Sponsors](https://github.com/sponsors/terminal-index)

## License

This project is licensed under the **MIT License** - you are free to modify, fork, copy, and distribute this script as you wish. See the `LICENSE` file for details.

Made with :brown_heart: in 🇵🇱