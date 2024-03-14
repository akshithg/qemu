#!/usr/bin/env bash

set -euxo pipefail

# Environment variables
# LINUXSRC - path to the Linux source code

# Check if the environment variables are set
if [ -z "${LINUXSRC}" ]; then
    echo "LINUXSRC is not set"
    exit 1
fi

BUILDDIR=${PWD}/build

QEMUSRC=${PWD}
QEMUBUILDDIR=${BUILDDIR}/qemu
QEMUBIN="${QEMUBUILDDIR}"/x86_64-softmmu/qemu-system-x86_64
function build_qemu() {
    # Build QEMU
    echo "Building QEMU"
    mkdir -p "${QEMUBUILDDIR}"
    pushd "${QEMUBUILDDIR}"
    "${QEMUSRC}"/configure --target-list=x86_64-softmmu --enable-slirp # apt install libslirp-dev, for user mode networking
    make -j"$(nproc)"
    popd
}

LINUXBUILDDIR=${BUILDDIR}/linux
KERNEL=${LINUXBUILDDIR}/arch/x86/boot/bzImage
function build_kernel() {
    # Build defconfig kernel
    echo "Building defconfig kernel"
    make -C "${LINUXSRC}" O="${LINUXBUILDDIR}" defconfig
    make -C "${LINUXSRC}" O="${LINUXBUILDDIR}" -j"$(nproc)" all
}

INITRAMFSDIR=${BUILDDIR}/initramfs
INITRAMFS=${INITRAMFSDIR}/initramfs.cpio.gz
function build_initramfs() {
    # Build a simple initramfs
    echo "Building initramfs"
    mkdir -p "${INITRAMFSDIR}"/{bin,etc,dev,proc,sys}
    cp /bin/busybox "${INITRAMFSDIR}"/bin
    chmod +x "${INITRAMFSDIR}"/bin/busybox
    ln -sf busybox "${INITRAMFSDIR}"/bin/sh
    cat >"${INITRAMFSDIR}"/init <<EOF
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
echo "Hello, World!"
exec /bin/sh
EOF
    chmod +x "${INITRAMFSDIR}"/init
    pushd "${INITRAMFSDIR}"
    find . | cpio -H newc -o | gzip >"${INITRAMFS}"
    popd
}

if [ ! -f "${QEMUBIN}" ]; then
    build_qemu
fi

if [ ! -f "${KERNEL}" ]; then
    build_kernel
fi

if [ ! -f "${INITRAMFS}" ]; then
    build_initramfs
fi

# Run QEMU with the kernel and initramfs with tracing enabled
TRACE_FILE=/tmp/qemu-trace.log
rm -f "${TRACE_FILE}"
"${QEMUBIN}" -nographic \
    -device e1000,netdev=net0 -netdev user,id=net0 \
    -kernel "${KERNEL}" -initrd "${INITRAMFS}" -append "console=ttyS0 root=/dev/ram0" \
    -trace exec_tb_cr3 -D /tmp/qemu-trace.log &
QEMU_PID=$!
sleep 5
kill -9 $QEMU_PID
# Check if the trace file is created and has logs like "exec_tb_cr3 cr3:0x0 tb:0x7f9fe4000d80 pc:0xfec4f size:2"
if [ ! -f "${TRACE_FILE}" ]; then
    echo "Trace file not found"
    exit 1
fi
if grep -vE "^exec_tb_cr3 cr3:0x[0-9a-fA-F]+ tb:0x[0-9a-fA-F]+ pc:0x[0-9a-fA-F]+ size:[0-9]+$" "${TRACE_FILE}"; then
    echo "Trace file has unexpected logs"
    exit 1
fi

echo "Test passed"
