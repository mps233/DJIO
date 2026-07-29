#ifndef C_MODEM_BRIDGE_H
#define C_MODEM_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CBATHandle CBATHandle;

typedef enum {
    CB_AT_RESULT_OK = 0,
    CB_AT_RESULT_MODEM_ERROR = 1,
    CB_AT_RESULT_TIMEOUT = 2,
    CB_AT_RESULT_DISCONNECTED = 3,
    CB_AT_RESULT_IO_ERROR = 4,
    CB_AT_RESULT_INVALID_ARGUMENT = 5,
} CBATResult;

typedef enum {
    CB_AT_TRANSPORT_USB = 1,
    CB_AT_TRANSPORT_SERIAL = 2,
} CBATTransport;

typedef struct {
    uint16_t vendor_id;
    uint16_t product_id;
    uint8_t bus_number;
    uint8_t device_address;
    uint8_t interface_number;
    uint8_t alternate_setting;
    uint8_t interface_class;
    uint8_t interface_subclass;
    uint8_t interface_protocol;
    uint8_t endpoint_in;
    uint8_t endpoint_out;
    uint16_t endpoint_in_packet_size;
    uint16_t endpoint_out_packet_size;
} CBUSBInfo;

int cb_usb_device_present(uint16_t vendor_id, uint16_t product_id);

CBATHandle *cb_at_open_usb(
    uint16_t vendor_id,
    uint16_t product_id,
    CBUSBInfo *info,
    char *error,
    size_t error_capacity
);

CBATHandle *cb_at_open_serial(
    const char *path,
    int baud_rate,
    char *error,
    size_t error_capacity
);

CBATResult cb_at_command(
    CBATHandle *handle,
    const char *command,
    char *response,
    size_t response_capacity,
    int timeout_ms,
    char *error,
    size_t error_capacity
);

CBATResult cb_at_write(
    CBATHandle *handle,
    const uint8_t *bytes,
    size_t length,
    int timeout_ms,
    char *error,
    size_t error_capacity
);

CBATResult cb_at_read(
    CBATHandle *handle,
    uint8_t *buffer,
    size_t capacity,
    size_t *bytes_read,
    int timeout_ms,
    char *error,
    size_t error_capacity
);

CBATTransport cb_at_transport(const CBATHandle *handle);
int cb_at_is_open(const CBATHandle *handle);
int cb_at_terminal_status(const char *response);
void cb_at_close(CBATHandle *handle);

#ifdef __cplusplus
}
#endif

#endif
