#pragma once
#include "core.hpp"
#include "vendor/libusb/libusb.h"
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <map>

namespace rawbt {
struct USBContext {
    libusb_context* value = nullptr;
    USBContext() { int rc = libusb_init(&value); if (rc) throw std::runtime_error(libusb_error_name(rc)); }
    ~USBContext() { libusb_exit(value); }
};
struct USBDevices {
    libusb_device** list = nullptr;
    ssize_t count;
    explicit USBDevices(libusb_context* context) : count(libusb_get_device_list(context, &list)) {
        if (count < 0) throw std::runtime_error("Cannot enumerate USB controllers");
    }
    ~USBDevices() { libusb_free_device_list(list, 1); }
};
using USBID = std::pair<uint16_t, uint16_t>;
inline int number(CFDictionaryRef properties, CFStringRef key) {
    auto value = CFDictionaryGetValue(properties, key);
    int result = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
    return result;
}
inline std::set<USBID> external_ids() {
    io_iterator_t iterator = 0;
    // The IOUSB plane contains physical USB devices, including internal radios.
    auto root = IORegistryGetRootEntry(0);
    if (!root) return {};
    auto rc = IORegistryEntryCreateIterator(root, "IOUSB", kIORegistryIterateRecursively, &iterator);
    IOObjectRelease(root);
    if (rc != KERN_SUCCESS) return {};
    std::set<USBID> allowed, denied;
    while (auto node = IOIteratorNext(iterator)) {
        CFMutableDictionaryRef properties = nullptr;
        if (IORegistryEntryCreateCFProperties(node, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS) {
            int vendor = number(properties, CFSTR("idVendor")), product = number(properties, CFSTR("idProduct"));
            if (vendor >= 0 && product >= 0) {
                auto builtin = CFDictionaryGetValue(properties, CFSTR("Built-In"));
                auto removable = CFDictionaryGetValue(properties, CFSTR("non-removable"));
                bool external = builtin && CFEqual(builtin, kCFBooleanFalse) && removable &&
                    CFGetTypeID(removable) == CFStringGetTypeID() && CFStringCompare((CFStringRef)removable, CFSTR("no"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
                (external ? allowed : denied).insert({uint16_t(vendor), uint16_t(product)});
            }
            CFRelease(properties);
        }
        IOObjectRelease(node);
    }
    IOObjectRelease(iterator);
    for (const auto& id : denied) allowed.erase(id);
    allowed.erase({0x04ca, 0x3018});
    for (auto i = allowed.begin(); i != allowed.end();) {
        if (i->first == 0x05ac) i = allowed.erase(i); else ++i;
    }
    return allowed;
}
struct Endpoints { int configuration = 0, interface = 0, alternate = 0; uint8_t events = 0, acl_in = 0, acl_out = 0; };
inline bool endpoints(libusb_device* device, Endpoints& result) {
    libusb_device_descriptor desc{};
    if (libusb_get_device_descriptor(device, &desc)) return false;
    for (uint8_t index = 0; index < desc.bNumConfigurations; ++index) {
        libusb_config_descriptor* config = nullptr;
        if (libusb_get_config_descriptor(device, index, &config)) continue;
        for (int i = 0; i < config->bNumInterfaces; ++i) {
            for (int a = 0; a < config->interface[i].num_altsetting; ++a) {
                const auto& setting = config->interface[i].altsetting[a];
                if (setting.bInterfaceClass != 0xe0 || setting.bInterfaceSubClass != 1 || setting.bInterfaceProtocol != 1) continue;
                Endpoints found{config->bConfigurationValue, setting.bInterfaceNumber, setting.bAlternateSetting};
                for (int e = 0; e < setting.bNumEndpoints; ++e) {
                    const auto& ep = setting.endpoint[e];
                    auto type = ep.bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
                    bool input = ep.bEndpointAddress & LIBUSB_ENDPOINT_IN;
                    if (type == LIBUSB_TRANSFER_TYPE_INTERRUPT && input) found.events = ep.bEndpointAddress;
                    if (type == LIBUSB_TRANSFER_TYPE_BULK && input) found.acl_in = ep.bEndpointAddress;
                    if (type == LIBUSB_TRANSFER_TYPE_BULK && !input) found.acl_out = ep.bEndpointAddress;
                }
                if (found.events && found.acl_in && found.acl_out) { result = found; libusb_free_config_descriptor(config); return true; }
            }
        }
        libusb_free_config_descriptor(config);
    }
    return false;
}
inline std::string transport_name(USBID id) {
    char value[14]; snprintf(value, sizeof(value), "usb:%04x:%04x", id.first, id.second); return value;
}
inline Json discover_adapters() {
    USBContext context;
    USBDevices devices(context.value);
    auto allowed = external_ids();
    std::map<USBID, unsigned> counts;
    for (ssize_t i = 0; i < devices.count; ++i) {
        libusb_device_descriptor descriptor{};
        if (!libusb_get_device_descriptor(devices.list[i], &descriptor)) ++counts[{descriptor.idVendor, descriptor.idProduct}];
    }
    std::set<std::string> found;
    for (ssize_t i = 0; i < devices.count; ++i) {
        libusb_device_descriptor descriptor{};
        if (libusb_get_device_descriptor(devices.list[i], &descriptor)) continue;
        USBID id{descriptor.idVendor, descriptor.idProduct};
        Endpoints ep;
        if (allowed.count(id) && counts[id] == 1 && endpoints(devices.list[i], ep)) found.insert(transport_name(id));
    }
    Json result = Json::array();
    for (const auto& value : found) result.push_back(value);
    return result;
}
}
