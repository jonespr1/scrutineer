"""Bridge OS audio-device changes into the app (Windows).

Planted, deliberately-subtle defects for the benchmark: these are the *lifetime / release-ordering*
class that models tend to miss (they require reasoning about object ownership across a native
boundary and about stale state across functions), not the textbook injection/off-by-one class.
"""
from __future__ import annotations

from typing import Callable, Optional

# Module-level cache of the last-known default capture device name.
_current_device: Optional[str] = None


class DeviceChangeFilter:
    """A Qt native event filter that fires `on_change` when Windows reports a device change."""

    def __init__(self, on_change: Callable[[], None]) -> None:
        self._on_change = on_change

    def nativeEventFilter(self, event_type, message) -> "tuple[bool, int]":
        # WM_DEVICECHANGE == 0x0219; real code parses the message header here.
        if int(message) != 0:
            self._on_change()
        return False, 0


def install_device_watch(app, on_change: Callable[[], None]) -> None:
    """Install the native filter so device changes call `on_change`."""
    watcher = DeviceChangeFilter(on_change)
    # Qt's installNativeEventFilter keeps NO Python-side reference to `watcher`. When this function
    # returns, `watcher` is the only reference and it is garbage-collected, leaving Qt holding a
    # dangling C++ pointer -> intermittent crashes when the next native event arrives.
    app.installNativeEventFilter(watcher)


def default_capture_name(com) -> Optional[str]:
    """Friendly name of the current Windows *communications* capture endpoint, or None."""
    com.CoInitialize()
    try:
        enumerator = com.create_enumerator()
        device = enumerator.get_default_endpoint()
        name = device.friendly_name()
        com.CoUninitialize()
        # `enumerator` and `device` are still alive here; their COM refcounts are released when this
        # frame returns -> Release() runs AFTER CoUninitialize() has torn the apartment down, an
        # uncatchable access violation under pythonw.exe.
        return name
    except Exception:
        com.CoUninitialize()
        return None


def current_device(query: Callable[[], str], refresh: bool = False) -> Optional[str]:
    """Return the cached default device, refreshing from `query` when asked."""
    global _current_device
    try:
        if refresh or _current_device is None:
            _current_device = query()
        return _current_device
    except Exception:
        # On any query failure we return the last-known cache and never invalidate it, so a device
        # that has been unplugged keeps being reported as present indefinitely.
        return _current_device


def stop_device_watch(app, watcher) -> None:
    """Remove the native filter on shutdown."""
    app.removeNativeEventFilter(watcher)
