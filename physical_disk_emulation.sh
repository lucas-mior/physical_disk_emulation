#!/bin/sh

set -e

export LC_ALL=C

script_dir="$(dirname "$(which "$0")")"

DISK_MAIN_GPT_AND_EFI_IMAGE="${script_dir}/disk_main_gpt_and_efi.img"
DISK_MAIN_MAPPED_NAME="windows_main_mapped_disk"
DISK_MAIN_MAPPED_DEV="/dev/mapper/$DISK_MAIN_MAPPED_NAME"
DISK_MAIN_TABLE="/tmp/${DISK_MAIN_MAPPED_NAME}_dmsetup.txt"

DISK_AUX_GPT_IMAGE="${script_dir}/DISK_AUX_GPT_IMAGE.img"
DISK_AUX_MAPPED_NAME="windows_aux_mapped_disk"
DISK_AUX_MAPPED_DEV="/dev/mapper/$DISK_AUX_MAPPED_NAME"
DISK_AUX_TABLE="/tmp/${DISK_AUX_MAPPED_NAME}_dmsetup.txt"

BLOCK_SIZE=512

nmapped="$(sudo dmsetup ls | wc -l)"
nloops="$(sudo losetup -a | wc -l)"

if [ "$nloops" -gt 0 ] || [ "$nmapped" -gt 4 ]; then
    echo "Current mapped and loop devices:"
    set -x
    sudo dmsetup ls
    sudo losetup -a
    set +x
    exit 1
fi

read -r efi_part disk_main <<EOF
$(fdisk -l | awk '
    /EFI System/ {
        part = $1
        disk_main = gensub("p[0-9]", "", "g", $1);
        print part, disk_main
    }')
EOF

read -r exfat_part disk_aux <<EOF
$(lsblk -r -o NAME,SIZE,FSTYPE,LABEL | awk '
    $3 == "exfat" {
        part = $1
        disk_aux = gensub("p[0-9]", "", "g", $1);
        printf("/dev/%s /dev/%s\n", part, disk_aux);
    }')
EOF

windows_c_part=$(fdisk -l "$disk_main" \
                 | awk '/Microsoft basic data/ { print $1 }')

check () {
    name="$1"
    var="$2"
    if [ -z "$var" ]; then
        echo "$name not defined"
        exit 1
    else
        echo "$name detected $var"
    fi
}
check "exfat_part"     "$exfat_part"
check "efi_part"       "$efi_part"
check "windows_c_part" "$windows_c_part"

main_block_size=$(blockdev --getss "$disk_main")
aux_block_size=$(blockdev --getss "$disk_aux")

if [ "$main_block_size" != 512 ]; then
    echo "main_block_size=$main_block_size != 512."
    echo "Only 512 byte sector size is supported."
    exit 1
fi
if [ "$aux_block_size" != 512 ]; then
    echo "aux_block_size=$aux_block_size != 512."
    echo "Only 512 byte sector size is supported."
    exit 1
fi

disk_main_size=$(blockdev --getsz "$disk_main")
windows_c_part_start=$(blockdev --report "$windows_c_part" | tail -1 | awk '{print $5}')
windows_c_part_size=$(blockdev --getsz "$windows_c_part")
windows_c_part_end=$((windows_c_part_start + windows_c_part_size))
disk_main_rest=$((disk_main_size - windows_c_part_start - windows_c_part_size))

disk_aux_size=$(blockdev --getsz "$disk_aux")
exfat_part_start=$(blockdev --report "$exfat_part" | tail -1 | awk '{print $5}')
exfat_part_size=$(blockdev --getsz "$exfat_part")
exfat_part_final=$((exfat_part_start + exfat_part_size))
disk_aux_rest=$((disk_aux_size - exfat_part_start - exfat_part_size))

for part in "$efi_part" "$windows_c_part" "$exfat_part"; do
    if mount | grep -q "^$part "; then
        echo "Error: partition $part is currently mounted."
        exit 1
    fi
done

if [ ! -e "$DISK_MAIN_GPT_AND_EFI_IMAGE" ]; then
    size=0
else
    size="$(du -a -B "$BLOCK_SIZE" "$DISK_MAIN_GPT_AND_EFI_IMAGE" \
            | awk '{print $1}')"
fi
if [ "$size" -ne "$windows_c_part_start" ]; then
    set -x
    dd if="$disk_main" of="$DISK_MAIN_GPT_AND_EFI_IMAGE" \
        bs="$BLOCK_SIZE" count="$windows_c_part_start" status=progress
    set +x
fi

if [ ! -e "$DISK_AUX_GPT_IMAGE" ]; then
    size=0
else
    size="$(du -a -B "$BLOCK_SIZE" "$DISK_AUX_GPT_IMAGE" | awk '{print $1}')"
fi
if [ "$size" -ne "$exfat_part_start" ]; then
    set -x
    dd if="$disk_aux" of="$DISK_AUX_GPT_IMAGE" \
        bs="$BLOCK_SIZE" count="$exfat_part_start" status=progress
    set +x
fi

# shellcheck disable=SC2329
cleanup() {
    if [ -n "$DISK_MAIN_MAPPED_NAME" ]; then
        sudo dmsetup remove "$DISK_MAIN_MAPPED_NAME"
    fi
    if [ -n "$DISK_AUX_MAPPED_NAME" ]; then
        sudo dmsetup remove "$DISK_AUX_MAPPED_NAME"
    fi
    if [ -n "$disk_main_gpt_and_efi_loop" ]; then
        sudo losetup -d "$disk_main_gpt_and_efi_loop"
    fi
    if [ -n "$disk_aux_gpt_loop" ]; then
        sudo losetup -d "$disk_aux_gpt_loop"
    fi
}

# trap cleanup EXIT

set -x
disk_main_gpt_and_efi_loop=$(losetup --show -f "$DISK_MAIN_GPT_AND_EFI_IMAGE")
disk_aux_gpt_loop=$(losetup --show -f "$DISK_AUX_GPT_IMAGE")
set +x

echo "Created loop for main disk beginning at $disk_main_gpt_and_efi_loop"
echo "Created loop for aux disk beginning at $disk_aux_gpt_loop"

{
echo "0                     $windows_c_part_start linear $disk_main_gpt_and_efi_loop 0"
echo "$windows_c_part_start $windows_c_part_size  linear $windows_c_part             0"
echo "$windows_c_part_end   $disk_main_rest       zero"
} |  sed -E 's/ +/,/g' | column -t -s ',' > "$DISK_MAIN_TABLE"
{
echo "0                 $exfat_part_start linear $disk_aux_gpt_loop 0"
echo "$exfat_part_start $exfat_part_size  linear $exfat_part        0"
echo "$exfat_part_final $disk_aux_rest    zero"
} | sed -E 's/ +/,/g' | column -t -s ',' > "$DISK_AUX_TABLE"

printf "\n==== main disk dmsetup table ====\n"
cat "$DISK_MAIN_TABLE"
printf "=================================\n"

printf "\n==== aux disk dmsetup table: ====\n"
cat "$DISK_AUX_TABLE"
printf "=================================\n\n"

set -x
# shellcheck disable=SC2024
sudo dmsetup create "$DISK_MAIN_MAPPED_NAME" < "$DISK_MAIN_TABLE"
# shellcheck disable=SC2024
sudo dmsetup create "$DISK_AUX_MAPPED_NAME" < "$DISK_AUX_TABLE"
set +x

printf "Main windows disk mapped at$RED $DISK_MAIN_MAPPED_DEV $RES\n"
printf "Aux exfat windows disk mapped at$RED $DISK_AUX_MAPPED_DEV $RES\n"

disk_main_physical_layout="disk_main_physical_layout.txt"
disk_main_virtual_layout="disk_main_virtual_layout.txt"
disk_aux_physical_layout="disk_aux_physical_layout.txt"
disk_aux_virtual_layout="disk_aux_virtual_layout.txt"

LC_ALL=C fdisk -l "$disk_main"            > "$disk_main_physical_layout"
LC_ALL=C fdisk -l "$DISK_MAIN_MAPPED_DEV" > "$disk_main_virtual_layout"
LC_ALL=C fdisk -l "$disk_aux"             > "$disk_aux_physical_layout"
LC_ALL=C fdisk -l "$DISK_AUX_MAPPED_DEV"  > "$disk_aux_virtual_layout"

normalize() {
    sed -E -i '
        /Disk model:/d;
        s|/dev/.+([0-9])\s|\1|g;
        s| +| |g;
        s| +$||g;
    ' "$1"
}
normalize "$disk_main_physical_layout"
normalize "$disk_main_virtual_layout"
normalize "$disk_aux_physical_layout"
normalize "$disk_aux_virtual_layout"

diff_main="$(diff $disk_main_physical_layout $disk_main_virtual_layout)"
diff_main_status=$?
diff_aux="$(diff $disk_aux_physical_layout $disk_aux_virtual_layout)"
diff_aux_status=$?

if [ $diff_main_status != 0 ]; then
    echo "Physical and virtual layout not matching for main disk:"
    echo "$diff_main"
    exit 1
fi
if [ $diff_aux_status != 0 ]; then
    echo "Physical and virtual layout not matching for aux disk."
    echo "$diff_aux"
    exit 1
fi
