# SPDX-FileCopyrightText: 2023-2024 Andrew Gunnerson
# SPDX-License-Identifier: GPL-3.0-only

source "${0%/*}/boot_common.sh" /data/local/tmp/custota.log

# toybox's `mountpoint` command only works for directories, but bind mounts can
# be files too.
has_mountpoint() {
    local mnt=${1}

    awk -v "mnt=${mnt}" \
        'BEGIN { ret=1 } $5 == mnt { ret=0; exit } END { exit ret }' \
        /proc/self/mountinfo
}

# We don't want to give any arbitrary system app permissions to update_engine.
# Thus, we create a new context for custota and only give access to that
# specific type. Magisk currently has no builtin way to modify seapp_contexts,
# so we'll do it manually.

header Creating custota_app domain

"${mod_dir}"/custota-selinux."$(getprop ro.product.cpu.abi)" -ST

header Updating seapp_contexts

seapp_file=/system/etc/selinux/plat_seapp_contexts
seapp_temp_dir=${mod_dir}/seapp_temp
seapp_temp_file=${mod_dir}/seapp_temp/plat_seapp_contexts

mkdir -p "${seapp_temp_dir}"

nsenter --mount=/proc/1/ns/mnt -- \
    mount -t tmpfs "${app_id}" "${seapp_temp_dir}"

# Full path because Magisk runs this script in busybox's standalone ash mode and
# we need Android's toybox version of cp.
/system/bin/cp --preserve=a "${seapp_file}" "${seapp_temp_file}"

cat >> "${seapp_temp_file}" << EOF
user=_app isPrivApp=true name=${app_id} domain=custota_app type=app_data_file levelFrom=all
EOF

while has_mountpoint "${seapp_file}"; do
    umount -l "${seapp_file}"
done

nsenter --mount=/proc/1/ns/mnt -- \
    mount -o ro,bind "${seapp_temp_file}" "${seapp_file}"

# On some devices, the system time is set too late in the boot process. This,
# for some reason, causes the package manager service to not update the package
# info cache entry despite the mtime of the apk being newer than the mtime of
# the cache entry [1]. This causes the sysconfig file's hidden-api-whitelist
# option to not take effect, among other issues. Work around this by forcibly
# deleting the relevant cache entries on every boot.
#
# [1] https://cs.android.com/android/platform/superproject/+/android-13.0.0_r42:frameworks/base/services/core/java/com/android/server/pm/parsing/PackageCacher.java;l=139

header Clear package manager caches

ls -ldZ "${cli_apk%/*}"
find /data/system/package_cache -name "${app_id}-*" -exec ls -ldZ {} \+

run_cli_apk com.chiller3.custota.standalone.ClearPackageManagerCachesKt

# Bind mount the appropriate CA stores so that update_engine will use the
# regular system CA store.

header Linking CA store

apex_store=/apex/com.android.conscrypt/cacerts
system_store=/system/etc/security/cacerts
google_store=${system_store}_google
standard_store=${system_store}
update_engine_store=${system_store}

if [[ -d "${apex_store}" ]]; then
    standard_store=${apex_store}
fi

if [[ -d "${google_store}" ]]; then
    update_engine_store=${google_store}
fi

echo "Standard trust store: ${standard_store}"
echo "update_engine trust store: ${update_engine_store}"

if [[ "${standard_store}" != "${update_engine_store}" ]]; then
    mnt_dir=${mod_dir}/mnt

    mkdir -p "${mnt_dir}"

    nsenter --mount=/proc/1/ns/mnt -- \
        mount -t tmpfs "${app_id}" "${mnt_dir}"

    cp -r "${standard_store}/." "${mnt_dir}"

    context=$(ls -Zd "${update_engine_store}" | awk '{print $1}')
    chcon -R "${context}" "${mnt_dir}"

    while has_mountpoint "${update_engine_store}"; do
        umount -l "${update_engine_store}"
    done

    nsenter --mount=/proc/1/ns/mnt -- \
        mount -o ro,bind "${mnt_dir}" "${update_engine_store}"
fi
