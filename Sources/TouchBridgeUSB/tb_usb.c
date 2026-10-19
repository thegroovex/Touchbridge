#include "tb_usb.h"
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

struct tb_usb_session {
    IOUSBDeviceInterface320 **dev;
    IOUSBInterfaceInterface300 **intf;
    int opened;
};

static CFMutableDictionaryRef matching(const char *cls, uint16_t vid, uint16_t pid, int ifnum) {
    CFMutableDictionaryRef m = IOServiceMatching(cls);
    if (!m) return NULL;
    int v = vid, p = pid;
    CFNumberRef nv = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);
    CFNumberRef np = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR("idVendor"), nv);
    CFDictionarySetValue(m, CFSTR("idProduct"), np);
    CFRelease(nv); CFRelease(np);
    if (ifnum >= 0) {
        CFNumberRef ni = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &ifnum);
        CFDictionarySetValue(m, CFSTR("bInterfaceNumber"), ni);
        CFRelease(ni);
    }
    return m;
}

static io_service_t find_service(const char *cls, const char *legacy, uint16_t vid, uint16_t pid, int ifnum) {
    io_service_t s = IOServiceGetMatchingService(MACH_PORT_NULL, matching(cls, vid, pid, ifnum));
    if (!s && legacy) s = IOServiceGetMatchingService(MACH_PORT_NULL, matching(legacy, vid, pid, ifnum));
    return s;
}

int tb_usb_device_count(uint16_t vid, uint16_t pid) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL, matching("IOUSBHostDevice", vid, pid, -1), &it) != KERN_SUCCESS) return 0;
    int n = 0;
    io_service_t s;
    while ((s = IOIteratorNext(it))) { n++; IOObjectRelease(s); }
    IOObjectRelease(it);
    return n;
}

static IOCFPlugInInterface **plugin(io_service_t s, CFUUIDRef type, int32_t *rc) {
    IOCFPlugInInterface **p = NULL;
    SInt32 score = 0;
    kern_return_t k = IOCreatePlugInInterfaceForService(s, type, kIOCFPlugInInterfaceID, &p, &score);
    if (rc) *rc = k;
    return k == KERN_SUCCESS ? p : NULL;
}

tb_usb_session *tb_usb_open_device(uint16_t vid, uint16_t pid, int try_open, int32_t *create_rc, int32_t *open_rc) {
    if (open_rc) *open_rc = -1;
    io_service_t s = find_service("IOUSBHostDevice", "IOUSBDevice", vid, pid, -1);
    if (!s) { if (create_rc) *create_rc = (int32_t)kIOReturnNoDevice; return NULL; }
    IOCFPlugInInterface **p = plugin(s, kIOUSBDeviceUserClientTypeID, create_rc);
    IOObjectRelease(s);
    if (!p) return NULL;
    IOUSBDeviceInterface320 **dev = NULL;
    HRESULT h = (*p)->QueryInterface(p, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID *)&dev);
    IODestroyPlugInInterface(p);
    if (h != S_OK || !dev) { if (create_rc) *create_rc = (int32_t)kIOReturnUnsupported; return NULL; }
    tb_usb_session *ss = calloc(1, sizeof(*ss));
    ss->dev = dev;
    if (try_open) {
        IOReturn r = (*dev)->USBDeviceOpen(dev);
        if (open_rc) *open_rc = r;
        ss->opened = (r == kIOReturnSuccess);
    }
    return ss;
}

tb_usb_session *tb_usb_open_interface(uint16_t vid, uint16_t pid, uint8_t interface_number, int32_t *create_rc) {
    io_service_t s = find_service("IOUSBHostInterface", "IOUSBInterface", vid, pid, interface_number);
    if (!s) { if (create_rc) *create_rc = (int32_t)kIOReturnNoDevice; return NULL; }
    IOCFPlugInInterface **p = plugin(s, kIOUSBInterfaceUserClientTypeID, create_rc);
    IOObjectRelease(s);
    if (!p) return NULL;
    IOUSBInterfaceInterface300 **intf = NULL;
    HRESULT h = (*p)->QueryInterface(p, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300), (LPVOID *)&intf);
    IODestroyPlugInInterface(p);
    if (h != S_OK || !intf) { if (create_rc) *create_rc = (int32_t)kIOReturnUnsupported; return NULL; }
    tb_usb_session *ss = calloc(1, sizeof(*ss));
    ss->intf = intf;
    return ss;
}

int32_t tb_usb_request(tb_usb_session *s, uint8_t bm_request_type, uint8_t b_request, uint16_t w_value,
                       uint16_t w_index, uint8_t *data, uint16_t w_length, uint32_t timeout_ms, uint32_t *transferred) {
    if (transferred) *transferred = 0;
    if (!s) return (int32_t)kIOReturnNoDevice;
    IOUSBDevRequestTO r;
    r.bmRequestType = bm_request_type;
    r.bRequest = b_request;
    r.wValue = w_value;
    r.wIndex = w_index;
    r.wLength = w_length;
    r.pData = w_length ? data : NULL;
    r.wLenDone = 0;
    r.noDataTimeout = timeout_ms;
    r.completionTimeout = timeout_ms;
    IOReturn rc;
    if (s->dev) rc = (*s->dev)->DeviceRequestTO(s->dev, &r);
    else rc = (*s->intf)->ControlRequestTO(s->intf, 0, &r);
    if (transferred) *transferred = r.wLenDone;
    return rc;
}

int32_t tb_usb_reenumerate(tb_usb_session *s) {
    if (!s || !s->dev) return (int32_t)kIOReturnBadArgument;
    return (*s->dev)->USBDeviceReEnumerate(s->dev, 0);
}

int tb_usb_is_open(tb_usb_session *s) { return s && s->opened; }

void tb_usb_close(tb_usb_session *s) {
    if (!s) return;
    if (s->dev) {
        if (s->opened) (*s->dev)->USBDeviceClose(s->dev);
        (*s->dev)->Release(s->dev);
    }
    if (s->intf) (*s->intf)->Release(s->intf);
    free(s);
}
