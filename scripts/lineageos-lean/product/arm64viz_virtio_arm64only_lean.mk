# SPDX-License-Identifier: Apache-2.0

# Set optional-device policy before inheriting the upstream VirtIO product.
# install-overlay.sh makes the corresponding upstream defaults overridable.
AB_OTA_UPDATER := false
PRODUCT_NO_CAMERA := true
TARGET_EXCLUDES_AUDIOFX := true
TARGET_AUDIO_HAL := none
TARGET_AUDIO_POLICY := none
TARGET_BLUETOOTH_HAL := none
TARGET_ENABLE_VIRT_WIFI := false
TARGET_SENSORS_HAL := none
TARGET_SUPPORTS_EXTERNAL_CAMERAS := false

# The Go product is AOSP's supported low-memory, 64-bit-only baseline. It still
# carries Binder, APEX, framework services, SurfaceFlinger, Settings, SystemUI,
# and the complete virtio_arm64only device definition.
$(call inherit-product, device/virt/virtio_arm64only/aosp_virtio_arm64only_go.mk)

# Keep the interactive UI contract explicit instead of relying on a transitive
# package inherited from handheld_product.mk.
PRODUCT_PACKAGES += \
    Launcher3QuickStepGo \
    Provision \
    Settings \
    SystemUI

# Spend build time on the processes visible during first boot. This avoids
# interpreting/JIT-compiling their hot Java paths on arm64viz's software CPU.
PRODUCT_DEXPREOPT_SPEED_APPS += \
    Launcher3QuickStepGo \
    Settings \
    SystemUI

PRODUCT_ART_TARGET_INCLUDE_DEBUG_BUILD := false
PRODUCT_MINIMIZE_JAVA_DEBUG_INFO := true

# There is no setup wizard in this product. Make the intended first screen the
# launcher and avoid waiting for provisioning components that are not shipped.
PRODUCT_SYSTEM_PROPERTIES += \
    debug.sf.nobootanimation=1 \
    ro.setupwizard.mode=DISABLED

PRODUCT_NAME := arm64viz_virtio_arm64only_lean
PRODUCT_DEVICE := virtio_arm64only_go
PRODUCT_BRAND := arm64viz
PRODUCT_MANUFACTURER := arm64viz
PRODUCT_MODEL := arm64viz AOSP Go VirtIO ARM64

PRODUCT_VENDOR_PROPERTIES += \
    ro.soc.manufacturer=$(PRODUCT_MANUFACTURER) \
    ro.soc.model=$(PRODUCT_DEVICE)
