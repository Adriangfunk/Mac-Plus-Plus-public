#!/usr/bin/python3
"""Return the live nearby Wi-Fi inventory through Apple's CoreWLAN API.

The shell calls this as a short-lived helper because CoreWLAN can redact the
SSID fields when the scan is performed inside the hardened SwiftUI process.
PyObjC is part of the system Python on the supported macOS installation, and
CoreWLAN is Apple's controller API rather than a remembered-network database.
"""

import json
import sys

import objc
from Foundation import NSBundle


def argument_value(name):
    try:
        index = sys.argv.index(name)
    except ValueError:
        return None
    if index + 1 >= len(sys.argv):
        return None
    value = sys.argv[index + 1].strip()
    return value or None


def emit(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    sys.stdout.write("\n")
    sys.stdout.flush()


def main():
    framework = NSBundle.bundleWithPath_("/System/Library/Frameworks/CoreWLAN.framework")
    if framework is None or not framework.load():
        emit({"ok": False, "error": "CoreWLAN unavailable", "networks": []})
        return 0

    try:
        client_class = objc.lookUpClass("CWWiFiClient")
        client = client_class.sharedWiFiClient()
        requested = argument_value("--interface")
        interface = client.interfaceWithName_(requested) if requested else None
        interface = interface or client.interface()
        if interface is None:
            emit({"ok": False, "error": "interface unavailable", "networks": []})
            return 0

        scanned, error = interface.scanForNetworksWithSSID_error_(None, None)
        if error is not None:
            emit({
                "ok": False,
                "error": str(error),
                "ssid": interface.ssid() or "",
                "networks": [],
            })
            return 0

        strongest = {}
        for network in scanned or ():
            name = network.ssid()
            if not name:
                data = network.ssidData()
                if data:
                    name = bytes(data).decode("utf-8", errors="replace")
            name = (name or "").strip()
            if not name:
                continue
            rssi = int(network.rssiValue())
            previous = strongest.get(name)
            if previous is None or rssi > previous:
                strongest[name] = rssi

        networks = [
            {"ssid": name, "rssi": rssi}
            for name, rssi in strongest.items()
        ]
        networks.sort(key=lambda item: (-item["rssi"], item["ssid"].casefold()))
        emit({
            "ok": True,
            "ssid": interface.ssid() or "",
            "networks": networks,
        })
        return 0
    except Exception as error:
        emit({"ok": False, "error": str(error), "networks": []})
        return 0


if __name__ == "__main__":
    sys.exit(main())
