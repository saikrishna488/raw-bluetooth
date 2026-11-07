"""macOS pointer output, independent of CoreBluetooth and PyObjC."""
import ctypes as C


class Point(C.Structure):
    _fields_ = [('x', C.c_double), ('y', C.c_double)]


class Size(C.Structure):
    _fields_ = [('width', C.c_double), ('height', C.c_double)]


class Rect(C.Structure):
    _fields_ = [('origin', Point), ('size', Size)]


def clamp_pointer(x, y, displays):
    candidates = [(min(max(x, left), left + width - 1),
                   min(max(y, top), top + height - 1))
                  for left, top, width, height in displays if width >= 1 and height >= 1]
    return min(candidates, key=lambda point: (point[0] - x) ** 2 + (point[1] - y) ** 2,
               default=(x, y))


def request_accessibility():
    ax = C.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
    cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    key = C.c_void_p.in_dll(ax, 'kAXTrustedCheckOptionPrompt')
    value = C.c_void_p.in_dll(cf, 'kCFBooleanTrue')
    cf.CFDictionaryCreate.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p, C.c_long, C.c_void_p, C.c_void_p]
    cf.CFDictionaryCreate.restype = C.c_void_p
    options = cf.CFDictionaryCreate(None, C.byref(key), C.byref(value), 1, None, None)
    ax.AXIsProcessTrustedWithOptions.argtypes = [C.c_void_p]
    ax.AXIsProcessTrustedWithOptions.restype = C.c_bool
    try:
        return ax.AXIsProcessTrustedWithOptions(options)
    finally:
        cf.CFRelease.argtypes = [C.c_void_p]
        cf.CFRelease(options)


class Pointer:
    def __init__(self):
        self.cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        self.cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.ax = C.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
        self.ax.AXIsProcessTrusted.restype = C.c_bool
        if not self.ax.AXIsProcessTrusted():
            raise RuntimeError('Pointer output requires Accessibility permission for this Python executable. Use --dry-run to test Bluetooth without pointer access.')
        self.cg.CGEventCreate.argtypes = [C.c_void_p]
        self.cg.CGEventCreate.restype = C.c_void_p
        self.cg.CGEventGetLocation.argtypes = [C.c_void_p]
        self.cg.CGEventGetLocation.restype = Point
        self.cg.CGEventCreateMouseEvent.argtypes = [C.c_void_p, C.c_uint32, Point, C.c_uint32]
        self.cg.CGEventCreateMouseEvent.restype = C.c_void_p
        self.cg.CGEventSetIntegerValueField.argtypes = [C.c_void_p, C.c_uint32, C.c_int64]
        self.cg.CGEventPost.argtypes = [C.c_uint32, C.c_void_p]
        self.cf.CFRelease.argtypes = [C.c_void_p]
        self.cg.CGEventCreateScrollWheelEvent.argtypes = [C.c_void_p, C.c_uint32, C.c_uint32, C.c_int32, C.c_int32]
        self.cg.CGEventCreateScrollWheelEvent.restype = C.c_void_p
        self.cg.CGGetActiveDisplayList.argtypes = [C.c_uint32, C.POINTER(C.c_uint32), C.POINTER(C.c_uint32)]
        self.cg.CGGetActiveDisplayList.restype = C.c_int32
        self.cg.CGDisplayBounds.argtypes = [C.c_uint32]
        self.cg.CGDisplayBounds.restype = Rect
        self.buttons = [False] * 8

    def post(self, event):
        if not event:
            raise RuntimeError('CoreGraphics failed to create event')
        try:
            self.cg.CGEventPost(0, event)
        finally:
            self.cf.CFRelease(event)

    def displays(self):
        count = C.c_uint32()
        if self.cg.CGGetActiveDisplayList(0, None, C.byref(count)) or not count.value:
            return []
        ids = (C.c_uint32 * count.value)()
        if self.cg.CGGetActiveDisplayList(count.value, ids, C.byref(count)):
            return []
        bounds = [self.cg.CGDisplayBounds(display) for display in ids[:count.value]]
        return [(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height) for rect in bounds]

    def apply(self, report):
        current = self.cg.CGEventCreate(None)
        if not current:
            raise RuntimeError('Cannot read pointer position')
        try:
            pos = self.cg.CGEventGetLocation(current)
        finally:
            self.cf.CFRelease(current)
        dx, dy = report.get('x', 0), report.get('y', 0)
        displays = self.displays()
        origin_x, origin_y = clamp_pointer(pos.x, pos.y, displays)
        pos.x, pos.y = clamp_pointer(origin_x + dx, origin_y + dy, displays)
        actual_dx, actual_dy = round(pos.x - origin_x), round(pos.y - origin_y)
        if dx or dy:
            button = next((i for i, down in enumerate(self.buttons) if down), 0)
            event_type = (6 if button == 0 else 7 if button == 1 else 27) if any(self.buttons) else 5
            event = self.cg.CGEventCreateMouseEvent(None, event_type, pos, button)
            if event:
                self.cg.CGEventSetIntegerValueField(event, 4, actual_dx)
                self.cg.CGEventSetIntegerValueField(event, 5, actual_dy)
            self.post(event)
        for index in range(8):
            down = report.get(f'button{index + 1}', self.buttons[index])
            if down != self.buttons[index]:
                event_type = ((1, 2) if index == 0 else (3, 4) if index == 1 else (25, 26))[not down]
                self.post(self.cg.CGEventCreateMouseEvent(None, event_type, pos, index))
                self.buttons[index] = down
        wheel, pan = report.get('wheel', 0), report.get('pan', 0)
        if wheel or pan:
            self.post(self.cg.CGEventCreateScrollWheelEvent(None, 1, 2, wheel, pan))

    def release(self):
        self.apply({f'button{i + 1}': False for i in range(8)})
