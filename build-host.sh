#!/bin/bash
# build-host.sh runs build-inside-vm.sh in a qemu VM running the latest Arch installer iso
#
# nounset: "Treat unset variables and parameters [...] as an error when performing parameter expansion."
# errexit: "Exit immediately if [...] command exits with a non-zero status."
set -o nounset -o errexit
readonly MIRROR="https://mirror.pkgbuild.com"
readonly ISO_URL="https://download.manjaro.org/gnome/21.2.5/manjaro-gnome-21.2.5-minimal-220314-linux510.iso"

function init() {
  readonly ORIG_PWD="${PWD}"
  readonly OUTPUT="${PWD}/output"
  local tmpdir
  tmpdir="$(mktemp --dry-run --directory --tmpdir="${PWD}/tmp")"
  readonly TMPDIR="${tmpdir}"
  mkdir -p "${OUTPUT}" "${TMPDIR}"

  cd "${TMPDIR}"
}

# Do some cleanup when the script exits
function cleanup() {
  rm -rf "${TMPDIR}"
  jobs -p | xargs --no-run-if-empty kill
}
trap cleanup EXIT

# Use local Arch iso or download the latest iso and extract the relevant files
function prepare_boot() {
   # https://download.manjaro.org/gnome/21.2.5/manjaro-gnome-21.2.5-minimal-220314-linux510.iso

  if LOCAL_ISO="$(ls "${ORIG_PWD}/"manjaro-gnome-*.iso 2>/dev/null)"; then
    echo "Using local iso: ${LOCAL_ISO}"
    ISO="${LOCAL_ISO}"
  fi

  if [ -z "${LOCAL_ISO}" ]; then
    curl -fO ${ISO_URL}
    ISO="$(ls "${ORIG_PWD}/"manjaro-gnome-*.iso 2>/dev/null)"
  fi

  # We need to extract the kernel and initrd so we can set a custom cmdline:
  # console=ttyS0, so the kernel and systemd sends output to the serial.
  xorriso -osirrox on -indev "${ISO}" -extract boot .
  ISO_VOLUME_ID="$(xorriso -indev "${ISO}" |& awk -F : '$1 ~ "Volume id" {print $2}' | tr -d "' ")"
}

function start_qemu() {
  # Used to communicate with qemu
  mkfifo guest.out guest.in
  # We could use a sparse file but we want to fail early
  fallocate -l 4G scratch-disk.img

  { qemu-system-x86_64 \
    -machine accel=kvm:tcg \
    -smp 4 \
    -m 2048 \
    -net nic \
    -net user \
    -kernel vmlinuz-x86_64 \
    -append "x86_64 lang=en_US keytable=us tz=UTC quiet systemd.show_status=1 misobasedir=manjaro misolable=${ISO_VOLUME_ID} driver=free 3"
    -initrd initramfs-x86_64.img \
    -append "cow_spacesize=2G ip=dhcp net.ifnames=0 console=ttyS0 mirror=${MIRROR}" \
    -drive file=scratch-disk.img,format=raw,if=virtio \
    -drive file="${ISO}",format=raw,if=virtio,media=cdrom,read-only \
    -virtfs "local,path=${ORIG_PWD},mount_tag=host,security_model=none" \
    -monitor none \
    -serial pipe:guest \
    -nographic || kill "${$}"; } &

  # We want to send the output to both stdout (fd1) and a new file descriptor (used by the expect function)
  exec 3>&1 {fd}< <(tee /dev/fd/3 <guest.out)
}

# Wait for a specific string from qemu
function expect() {
  local length="${#1}"
  local i=0
  local timeout="${2:-30}"
  # We can't use ex: grep as we could end blocking forever, if the string isn't followed by a newline
  while true; do
    # read should never exit with a non-zero exit code,
    # but it can happen if the fd is EOF or it times out
    IFS= read -r -u ${fd} -n 1 -t "${timeout}" c
    if [ "${1:${i}:1}" = "${c}" ]; then
      i="$((i + 1))"
      if [ "${length}" -eq "${i}" ]; then
        break
      fi
    else
      i=0
    fi
  done
}

# Send string to qemu
function send() {
  echo -en "${1}" >guest.in
}

function main() {
  init
  prepare_boot
  start_qemu

  # Login
  expect "manjaro-gnome login:"
  send "root\n"
  expect "Password:"
  send "manjaro\n"
  expect "[manjaro-gnome ~]# "

  # Switch to bash and shutdown on error
  send "bash\n"
  expect "[manjaro-gnome ~]# "
  send "trap \"shutdown now\" ERR\n"
  expect "[manjaro-gnome ~]# "

  # Prepare environment
  send "mkdir /mnt/arch-boxes && mount -t 9p -o trans=virtio host /mnt/arch-boxes -oversion=9p2000.L\n"
  expect "[manjaro-gnome ~]# "
  send "mkfs.ext4 /dev/vda && mkdir /mnt/scratch-disk/ && mount /dev/vda /mnt/scratch-disk && cd /mnt/scratch-disk\n"
  expect "[manjaro-gnome ~]# "
  send "cp -a /mnt/arch-boxes/{box.ovf,build-inside-vm.sh,images} .\n"
  expect "[manjaro-gnome ~]# "
  send "mkdir pkg && mount --bind pkg /var/cache/pacman/pkg\n"
  expect "[manjaro-gnome ~]# "

  # Wait for pacman-init
  send "until systemctl is-active pacman-init; do sleep 1; done\n"
  expect "[manjaro-gnome ~]# "

  # Install required packages
  send "pacman -Syu --ignore linux --noconfirm qemu-headless jq\n"
  expect "[manjaro-gnome ~]# " 120 # (10/14) Updating module dependencies...

  ## Start build and copy output to local disk
  send "bash -x ./build-inside-vm.sh ${BUILD_VERSION:-}\n"
  expect "[manjaro-gnome ~]# " 240 # qemu-img convert can take a long time
  send "cp -vr --preserve=mode,timestamps output /mnt/arch-boxes/tmp/$(basename "${TMPDIR}")/\n"
  expect "[manjaro-gnome ~]# " 60
  mv output/* "${OUTPUT}/"

  # Shutdown the VM
  send "shutdown now\n"
  wait
}
main
