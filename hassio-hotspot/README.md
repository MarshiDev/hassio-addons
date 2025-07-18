# hassio-hotspot
This addon creates a plug-and-play hotspot with very little configuration needed.

## Installation

To use this repository with your own Hass.io installation please follow [the official instructions](https://www.home-assistant.io/hassio installing_third_party_addons/) on the Home Assistant website with the following URL:

```txt
https://github.com/marshidev/hassio-addons
```

### Configuration
The `internet_interface` option defines where you want to get the internet for your hotspot from.
This is usually `eth0` for ethernet, `wlan0` for wifi or if you use something like a usb dongle or lte hat,
you can find the interface name using `ifconfig` in the terminal.
