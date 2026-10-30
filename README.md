Test utils for QC modems (qmi pref) 
Works only on WH3000pro with my FW, for other - not tested

Description https://t.me/lint_electronics/47 

ow 24 
opkg update && opkg install luci-compat luci-lib-jsonc modemmanager libqmi libmbim kmod-usb-net-cdc-mbim kmod-usb-net-qmi-wwan kmod-usb-serial-option kmod-usb-serial-qualcomm ca-certificates lpac

ow 25 
apk update && apk add luci-compat luci-lib-jsonc modemmanager libqmi libmbim kmod-usb-net-cdc-mbim kmod-usb-net-qmi-wwan kmod-usb-serial-option kmod-usb-serial-qualcomm ca-certificates lpac
