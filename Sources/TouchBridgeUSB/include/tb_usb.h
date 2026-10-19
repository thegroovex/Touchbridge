#ifndef TB_USB_H
#define TB_USB_H
// Direkte USB-Control-Requests über die (alte, weiter vorhandene) IOUSBLib – ohne Entitlement, ohne Root.
// Für die Multitouch-Experimente (SET_IDLE / GET_REPORT / SET_REPORT an HID-Interfaces, Neu-Enumeration).
#include <stdint.h>
#include <IOKit/IOKitLib.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tb_usb_session tb_usb_session;

/// Anzahl USB-Geräte (IOUSBHostDevice) mit VID/PID in der Registry
int tb_usb_device_count(uint16_t vid, uint16_t pid);

/// Geräte-User-Client öffnen. try_open=1: zusätzlich USBDeviceOpen (exklusiv); Ergebnis in *open_rc
/// (0 = offen, sonst IOReturn, z. B. 0xE00002C5 belegt). *create_rc: Ergebnis des Plug-ins (0 = ok).
/// Rückgabe NULL, wenn kein Gerät/kein Plug-in.
tb_usb_session *tb_usb_open_device(uint16_t vid, uint16_t pid, int try_open, int32_t *create_rc, int32_t *open_rc);

/// Interface-User-Client für bInterfaceNumber öffnen (ohne USBInterfaceOpen – das hält der HID-Treiber).
tb_usb_session *tb_usb_open_interface(uint16_t vid, uint16_t pid, uint8_t interface_number, int32_t *create_rc);

/// Control-Request (Default-Pipe). data: Puffer mit w_length Bytes (OUT: Daten, IN: Antwort).
/// *transferred: tatsächlich übertragene Bytes. Rückgabe IOReturn.
int32_t tb_usb_request(tb_usb_session *s, uint8_t bm_request_type, uint8_t b_request, uint16_t w_value,
                       uint16_t w_index, uint8_t *data, uint16_t w_length, uint32_t timeout_ms, uint32_t *transferred);

/// USBDeviceReEnumerate (nur Geräte-Session; braucht USBDeviceOpen)
int32_t tb_usb_reenumerate(tb_usb_session *s);

/// Ist die Session geöffnet (USBDeviceOpen erfolgreich)?
int tb_usb_is_open(tb_usb_session *s);

void tb_usb_close(tb_usb_session *s);

#ifdef __cplusplus
}
#endif
#endif
