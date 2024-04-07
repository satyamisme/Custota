# SPDX-FileCopyrightText: 2023-2024 Andrew Gunnerson
# SPDX-License-Identifier: GPL-3.0-only

source "${0%/*}/boot_common.sh" /data/local/tmp/custota_selinux.log

# We don't want to give any arbitrary system app permissions to update_engine.
# Thus, we create a new context for custota and only give access to that
# specific type. Magisk currently has no builtin way to modify seapp_contexts,
# so we'll do it manually.

header Creating custota_app domain

"${mod_dir}"/custota_selinux -ST

header Updating seapp_contexts

seapp_dir=/system/etc/selinux
seapp_file=${seapp_dir}/plat_seapp_contexts
mod_seapp_dir=${mod_dir}${seapp_dir}
mod_seapp_file=${mod_dir}${seapp_file}

rm -rf "${mod_seapp_dir}"
mkdir -p "${mod_seapp_dir}"

# If, for whatever reason, we couldn't wipe the directory, mount a blank tmpfs
# on top. An outdated file can cause the system to boot loop due to system apps
# running under the wrong SELinux context.
if [[ -e "${mod_seapp_file}" ]]; then
    mount -t tmpfs tmpfs "${mod_seapp_dir}"
fi

# Full path because Magisk runs this script in busybox's standalone ash mode and
# we need Android's toybox version of cp.
/system/bin/cp --preserve=a "${seapp_file}" "${mod_seapp_file}"

cat >> "${mod_seapp_file}" << EOF
user=_app isPrivApp=true name=${app_id} domain=custota_app type=app_data_file levelFrom=all
EOF

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

rm -rf "${mod_dir}"/system/etc/security

if [[ "${standard_store}" != "${update_engine_store}" ]]; then
    mkdir -p "${mod_dir}"/system/etc/security
    ln -sfn "${standard_store}" "${mod_dir}${update_engine_store}"
fi
