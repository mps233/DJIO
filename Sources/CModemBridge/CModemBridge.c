#include "CModemBridge.h"

#include <libusb.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

struct CBATHandle {
    CBATTransport transport;
    libusb_context *usb_context;
    libusb_device_handle *usb_handle;
    int usb_interface;
    unsigned char endpoint_in;
    unsigned char endpoint_out;
    int serial_fd;
};

static void set_error(char *buffer, size_t capacity, const char *format, ...) {
    if (buffer == NULL || capacity == 0) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(buffer, capacity, format, arguments);
    va_end(arguments);
    buffer[capacity - 1] = '\0';
}

static int64_t monotonic_milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int append_bytes(char *buffer, size_t capacity, size_t *length, const unsigned char *data, size_t count) {
    if (buffer == NULL || capacity == 0 || length == NULL) {
        return 0;
    }
    size_t available = capacity - 1 - *length;
    size_t copied = count < available ? count : available;
    if (copied > 0) {
        memcpy(buffer + *length, data, copied);
        *length += copied;
        buffer[*length] = '\0';
    }
    return copied == count;
}

// Returns 1 for OK, -1 for a modem error, and 0 while more input is needed.
int cb_at_terminal_status(const char *response) {
    if (response == NULL) {
        return 0;
    }
    const char *cursor = response;
    while (*cursor != '\0') {
        while (*cursor == '\r' || *cursor == '\n' || isspace((unsigned char)*cursor)) {
            cursor++;
        }
        const char *line_start = cursor;
        while (*cursor != '\0' && *cursor != '\r' && *cursor != '\n') {
            cursor++;
        }
        const char *line_end = cursor;
        while (line_end > line_start && isspace((unsigned char)line_end[-1])) {
            line_end--;
        }
        size_t length = (size_t)(line_end - line_start);
        if (length == 2 && strncasecmp(line_start, "OK", 2) == 0) {
            return 1;
        }
        if ((length == 5 && strncasecmp(line_start, "ERROR", 5) == 0) ||
            (length >= 10 && strncasecmp(line_start, "+CME ERROR", 10) == 0) ||
            (length >= 10 && strncasecmp(line_start, "+CMS ERROR", 10) == 0)) {
            return -1;
        }
    }
    return 0;
}

static int usb_read_once(CBATHandle *handle, unsigned char *buffer, int capacity, int timeout_ms, int *transferred) {
    return libusb_bulk_transfer(
        handle->usb_handle,
        handle->endpoint_in,
        buffer,
        capacity,
        transferred,
        (unsigned int)timeout_ms
    );
}

static CBATResult write_all(
    CBATHandle *handle,
    const unsigned char *bytes,
    size_t length,
    int timeout_ms,
    char *error,
    size_t error_capacity
) {
    if (handle->transport == CB_AT_TRANSPORT_USB) {
        size_t offset = 0;
        int64_t deadline = monotonic_milliseconds() + timeout_ms;
        while (offset < length) {
            int remaining = (int)(deadline - monotonic_milliseconds());
            if (remaining <= 0) {
                set_error(error, error_capacity, "USB write timed out (%zu/%zu bytes)", offset, length);
                return CB_AT_RESULT_TIMEOUT;
            }
            size_t requested = length - offset;
            if (requested > (size_t)INT_MAX) {
                requested = (size_t)INT_MAX;
            }
            int transferred = 0;
            int result = libusb_bulk_transfer(
                handle->usb_handle,
                handle->endpoint_out,
                (unsigned char *)bytes + offset,
                (int)requested,
                &transferred,
                (unsigned int)remaining
            );
            if (transferred > 0) {
                offset += (size_t)transferred;
            }
            if (offset == length && (result == 0 || result == LIBUSB_ERROR_TIMEOUT)) {
                return CB_AT_RESULT_OK;
            }
            if (result == LIBUSB_ERROR_NO_DEVICE) {
                set_error(error, error_capacity, "USB modem disconnected");
                return CB_AT_RESULT_DISCONNECTED;
            }
            if (result == LIBUSB_ERROR_TIMEOUT) {
                continue;
            }
            if (result != 0) {
                set_error(error, error_capacity, "USB write failed: %s (%zu/%zu bytes)", libusb_error_name(result), offset, length);
                return CB_AT_RESULT_IO_ERROR;
            }
            if (transferred == 0) {
                set_error(error, error_capacity, "USB write made no progress (%zu/%zu bytes)", offset, length);
                return CB_AT_RESULT_IO_ERROR;
            }
        }
        return CB_AT_RESULT_OK;
    }

    size_t offset = 0;
    int64_t deadline = monotonic_milliseconds() + timeout_ms;
    while (offset < length) {
        int remaining = (int)(deadline - monotonic_milliseconds());
        if (remaining <= 0) {
            set_error(error, error_capacity, "Serial write timed out");
            return CB_AT_RESULT_TIMEOUT;
        }
        struct pollfd descriptor = {.fd = handle->serial_fd, .events = POLLOUT, .revents = 0};
        int poll_result = poll(&descriptor, 1, remaining);
        if (poll_result < 0 && errno == EINTR) {
            continue;
        }
        if (poll_result <= 0) {
            set_error(error, error_capacity, "Serial write timed out");
            return CB_AT_RESULT_TIMEOUT;
        }
        ssize_t written = write(handle->serial_fd, bytes + offset, length - offset);
        if (written < 0 && (errno == EAGAIN || errno == EINTR)) {
            continue;
        }
        if (written <= 0) {
            set_error(error, error_capacity, "Serial write failed: %s", strerror(errno));
            return errno == ENXIO ? CB_AT_RESULT_DISCONNECTED : CB_AT_RESULT_IO_ERROR;
        }
        offset += (size_t)written;
    }
    return CB_AT_RESULT_OK;
}

CBATResult cb_at_write(
    CBATHandle *handle,
    const uint8_t *bytes,
    size_t length,
    int timeout_ms,
    char *error,
    size_t error_capacity
) {
    if (handle == NULL || bytes == NULL || length == 0 || timeout_ms <= 0) {
        set_error(error, error_capacity, "Invalid AT write arguments");
        return CB_AT_RESULT_INVALID_ARGUMENT;
    }
    return write_all(handle, bytes, length, timeout_ms, error, error_capacity);
}

CBATResult cb_at_read(
    CBATHandle *handle,
    uint8_t *buffer,
    size_t capacity,
    size_t *bytes_read,
    int timeout_ms,
    char *error,
    size_t error_capacity
) {
    if (handle == NULL || buffer == NULL || capacity == 0 || bytes_read == NULL || timeout_ms <= 0) {
        set_error(error, error_capacity, "Invalid AT read arguments");
        return CB_AT_RESULT_INVALID_ARGUMENT;
    }
    *bytes_read = 0;

    if (handle->transport == CB_AT_TRANSPORT_USB) {
        int transferred = 0;
        int result = usb_read_once(
            handle,
            buffer,
            capacity > (size_t)INT_MAX ? INT_MAX : (int)capacity,
            timeout_ms,
            &transferred
        );
        if (transferred > 0) {
            *bytes_read = (size_t)transferred;
        }
        if (result == 0 || (result == LIBUSB_ERROR_TIMEOUT && transferred > 0)) {
            return CB_AT_RESULT_OK;
        }
        if (result == LIBUSB_ERROR_TIMEOUT) {
            return CB_AT_RESULT_TIMEOUT;
        }
        if (result == LIBUSB_ERROR_NO_DEVICE) {
            set_error(error, error_capacity, "USB modem disconnected");
            return CB_AT_RESULT_DISCONNECTED;
        }
        set_error(error, error_capacity, "USB read failed: %s", libusb_error_name(result));
        return CB_AT_RESULT_IO_ERROR;
    }

    struct pollfd descriptor = {.fd = handle->serial_fd, .events = POLLIN, .revents = 0};
    int poll_result;
    do {
        poll_result = poll(&descriptor, 1, timeout_ms);
    } while (poll_result < 0 && errno == EINTR);
    if (poll_result == 0) {
        return CB_AT_RESULT_TIMEOUT;
    }
    if (poll_result < 0) {
        int poll_error = errno;
        set_error(error, error_capacity, "Serial poll failed: %s", strerror(poll_error));
        return poll_error == EBADF || poll_error == ENXIO ? CB_AT_RESULT_DISCONNECTED : CB_AT_RESULT_IO_ERROR;
    }
    if ((descriptor.revents & POLLIN) == 0 && (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
        set_error(error, error_capacity, "Serial modem disconnected");
        return CB_AT_RESULT_DISCONNECTED;
    }

    ssize_t count;
    do {
        count = read(handle->serial_fd, buffer, capacity);
    } while (count < 0 && errno == EINTR);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        return CB_AT_RESULT_TIMEOUT;
    }
    if (count == 0) {
        set_error(error, error_capacity, "Serial modem disconnected");
        return CB_AT_RESULT_DISCONNECTED;
    }
    if (count < 0) {
        int read_error = errno;
        set_error(error, error_capacity, "Serial read failed: %s", strerror(read_error));
        return read_error == ENXIO || read_error == EBADF ? CB_AT_RESULT_DISCONNECTED : CB_AT_RESULT_IO_ERROR;
    }
    *bytes_read = (size_t)count;
    return CB_AT_RESULT_OK;
}

static CBATResult read_response(
    CBATHandle *handle,
    char *response,
    size_t response_capacity,
    int timeout_ms,
    char *error,
    size_t error_capacity
) {
    size_t response_length = 0;
    response[0] = '\0';
    int64_t deadline = monotonic_milliseconds() + timeout_ms;
    unsigned char chunk[1024];

    while (monotonic_milliseconds() < deadline) {
        int remaining = (int)(deadline - monotonic_milliseconds());
        int slice = remaining > 250 ? 250 : remaining;
        int count = 0;

        if (handle->transport == CB_AT_TRANSPORT_USB) {
            int result = usb_read_once(handle, chunk, (int)sizeof(chunk), slice, &count);
            if (result == LIBUSB_ERROR_TIMEOUT && count == 0) {
                continue;
            }
            if (result == LIBUSB_ERROR_NO_DEVICE) {
                set_error(error, error_capacity, "USB modem disconnected");
                return CB_AT_RESULT_DISCONNECTED;
            }
            if (result != 0 && result != LIBUSB_ERROR_TIMEOUT) {
                set_error(error, error_capacity, "USB read failed: %s", libusb_error_name(result));
                return CB_AT_RESULT_IO_ERROR;
            }
        } else {
            struct pollfd descriptor = {.fd = handle->serial_fd, .events = POLLIN, .revents = 0};
            int poll_result = poll(&descriptor, 1, slice);
            if (poll_result < 0 && errno == EINTR) {
                continue;
            }
            if (poll_result == 0) {
                continue;
            }
            if (poll_result < 0 || (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                set_error(error, error_capacity, "Serial modem disconnected");
                return CB_AT_RESULT_DISCONNECTED;
            }
            ssize_t read_count = read(handle->serial_fd, chunk, sizeof(chunk));
            if (read_count < 0 && (errno == EAGAIN || errno == EINTR)) {
                continue;
            }
            if (read_count <= 0) {
                set_error(error, error_capacity, "Serial read failed: %s", strerror(errno));
                return CB_AT_RESULT_IO_ERROR;
            }
            count = (int)read_count;
        }

        if (count == 0) {
            continue;
        }
        if (!append_bytes(response, response_capacity, &response_length, chunk, (size_t)count)) {
            set_error(error, error_capacity, "AT response exceeded %zu bytes", response_capacity - 1);
            return CB_AT_RESULT_IO_ERROR;
        }
        int terminal = cb_at_terminal_status(response);
        if (terminal > 0) {
            return CB_AT_RESULT_OK;
        }
        if (terminal < 0) {
            set_error(error, error_capacity, "Modem rejected the AT command");
            return CB_AT_RESULT_MODEM_ERROR;
        }
    }

    set_error(error, error_capacity, "AT command timed out before a final response");
    return CB_AT_RESULT_TIMEOUT;
}

CBATResult cb_at_command(
    CBATHandle *handle,
    const char *command,
    char *response,
    size_t response_capacity,
    int timeout_ms,
    char *error,
    size_t error_capacity
) {
    if (handle == NULL || command == NULL || response == NULL || response_capacity < 2 || timeout_ms <= 0) {
        set_error(error, error_capacity, "Invalid AT command arguments");
        return CB_AT_RESULT_INVALID_ARGUMENT;
    }
    if (strncasecmp(command, "AT", 2) != 0) {
        set_error(error, error_capacity, "AT command must start with AT");
        return CB_AT_RESULT_INVALID_ARGUMENT;
    }

    size_t command_length = strlen(command);
    unsigned char *payload = malloc(command_length + 2);
    if (payload == NULL) {
        set_error(error, error_capacity, "Unable to allocate AT command buffer");
        return CB_AT_RESULT_IO_ERROR;
    }
    memcpy(payload, command, command_length);
    payload[command_length] = '\r';
    payload[command_length + 1] = '\0';

    CBATResult write_result = write_all(handle, payload, command_length + 1, timeout_ms, error, error_capacity);
    free(payload);
    if (write_result != CB_AT_RESULT_OK) {
        return write_result;
    }
    return read_response(handle, response, response_capacity, timeout_ms, error, error_capacity);
}

int cb_usb_device_present(uint16_t vendor_id, uint16_t product_id) {
    libusb_context *context = NULL;
    if (libusb_init(&context) != 0) {
        return 0;
    }
    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(context, &devices);
    int present = 0;
    for (ssize_t index = 0; index < count; index++) {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(devices[index], &descriptor) == 0 &&
            descriptor.idVendor == vendor_id && descriptor.idProduct == product_id) {
            present = 1;
            break;
        }
    }
    if (devices != NULL) {
        libusb_free_device_list(devices, 1);
    }
    libusb_exit(context);
    return present;
}

CBATHandle *cb_at_open_usb(
    uint16_t vendor_id,
    uint16_t product_id,
    CBUSBInfo *info,
    char *error,
    size_t error_capacity
) {
    libusb_context *context = NULL;
    int init_result = libusb_init(&context);
    if (init_result != 0) {
        set_error(error, error_capacity, "libusb initialization failed: %s", libusb_error_name(init_result));
        return NULL;
    }

    libusb_device **devices = NULL;
    ssize_t device_count = libusb_get_device_list(context, &devices);
    libusb_device *device = NULL;
    for (ssize_t index = 0; index < device_count; index++) {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(devices[index], &descriptor) == 0 &&
            descriptor.idVendor == vendor_id && descriptor.idProduct == product_id) {
            device = libusb_ref_device(devices[index]);
            break;
        }
    }
    if (devices != NULL) {
        libusb_free_device_list(devices, 1);
    }
    if (device == NULL) {
        set_error(error, error_capacity, "USB device %04x:%04x was not found", vendor_id, product_id);
        libusb_exit(context);
        return NULL;
    }

    libusb_device_handle *usb_handle = NULL;
    int open_result = libusb_open(device, &usb_handle);
    if (open_result != 0 || usb_handle == NULL) {
        set_error(error, error_capacity, "Unable to open USB device %04x:%04x: %s", vendor_id, product_id, libusb_error_name(open_result));
        libusb_unref_device(device);
        libusb_exit(context);
        return NULL;
    }

    struct libusb_config_descriptor *configuration = NULL;
    int descriptor_result = libusb_get_active_config_descriptor(device, &configuration);
    if (descriptor_result != 0) {
        set_error(error, error_capacity, "Unable to read USB configuration: %s", libusb_error_name(descriptor_result));
        libusb_close(usb_handle);
        libusb_unref_device(device);
        libusb_exit(context);
        return NULL;
    }

    char last_error[256] = "No vendor-specific bulk IN/OUT interface accepted AT commands";
    for (int interface_index = 0; interface_index < configuration->bNumInterfaces; interface_index++) {
        const struct libusb_interface *interface = &configuration->interface[interface_index];
        for (int alternate_index = 0; alternate_index < interface->num_altsetting; alternate_index++) {
            const struct libusb_interface_descriptor *alternate = &interface->altsetting[alternate_index];
            if (alternate->bInterfaceClass != LIBUSB_CLASS_VENDOR_SPEC) {
                continue;
            }

            unsigned char endpoint_in = 0;
            unsigned char endpoint_out = 0;
            uint16_t endpoint_in_packet_size = 0;
            uint16_t endpoint_out_packet_size = 0;
            int endpoint_in_count = 0;
            int endpoint_out_count = 0;
            for (int endpoint_index = 0; endpoint_index < alternate->bNumEndpoints; endpoint_index++) {
                const struct libusb_endpoint_descriptor *endpoint = &alternate->endpoint[endpoint_index];
                if ((endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) != LIBUSB_TRANSFER_TYPE_BULK) {
                    continue;
                }
                if ((endpoint->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN) {
                    endpoint_in = endpoint->bEndpointAddress;
                    endpoint_in_packet_size = endpoint->wMaxPacketSize;
                    endpoint_in_count++;
                } else {
                    endpoint_out = endpoint->bEndpointAddress;
                    endpoint_out_packet_size = endpoint->wMaxPacketSize;
                    endpoint_out_count++;
                }
            }
            if (endpoint_in_count != 1 || endpoint_out_count != 1) {
                continue;
            }

            int claim_result = libusb_claim_interface(usb_handle, alternate->bInterfaceNumber);
            if (claim_result != 0) {
                snprintf(last_error, sizeof(last_error), "Interface %u is unavailable: %s", alternate->bInterfaceNumber, libusb_error_name(claim_result));
                continue;
            }
            if (alternate->bAlternateSetting != 0) {
                int alternate_result = libusb_set_interface_alt_setting(usb_handle, alternate->bInterfaceNumber, alternate->bAlternateSetting);
                if (alternate_result != 0) {
                    snprintf(last_error, sizeof(last_error), "Interface %u alternate setting %u failed: %s", alternate->bInterfaceNumber, alternate->bAlternateSetting, libusb_error_name(alternate_result));
                    libusb_release_interface(usb_handle, alternate->bInterfaceNumber);
                    continue;
                }
            }

            CBATHandle *candidate = calloc(1, sizeof(CBATHandle));
            if (candidate == NULL) {
                libusb_release_interface(usb_handle, alternate->bInterfaceNumber);
                continue;
            }
            candidate->transport = CB_AT_TRANSPORT_USB;
            candidate->usb_context = context;
            candidate->usb_handle = usb_handle;
            candidate->usb_interface = alternate->bInterfaceNumber;
            candidate->endpoint_in = endpoint_in;
            candidate->endpoint_out = endpoint_out;
            candidate->serial_fd = -1;

            char probe_response[1024] = {0};
            char probe_error[256] = {0};
            CBATResult probe_result = cb_at_command(candidate, "AT", probe_response, sizeof(probe_response), 1200, probe_error, sizeof(probe_error));
            if (probe_result == CB_AT_RESULT_OK) {
                probe_result = cb_at_command(candidate, "AT+CMGF=?", probe_response, sizeof(probe_response), 1600, probe_error, sizeof(probe_error));
            }
            if (probe_result == CB_AT_RESULT_OK) {
                if (info != NULL) {
                    info->vendor_id = vendor_id;
                    info->product_id = product_id;
                    info->bus_number = libusb_get_bus_number(device);
                    info->device_address = libusb_get_device_address(device);
                    info->interface_number = alternate->bInterfaceNumber;
                    info->alternate_setting = alternate->bAlternateSetting;
                    info->interface_class = alternate->bInterfaceClass;
                    info->interface_subclass = alternate->bInterfaceSubClass;
                    info->interface_protocol = alternate->bInterfaceProtocol;
                    info->endpoint_in = endpoint_in;
                    info->endpoint_out = endpoint_out;
                    info->endpoint_in_packet_size = endpoint_in_packet_size;
                    info->endpoint_out_packet_size = endpoint_out_packet_size;
                }
                libusb_free_config_descriptor(configuration);
                libusb_unref_device(device);
                return candidate;
            }

            snprintf(last_error, sizeof(last_error), "Interface %u did not pass the SMS AT probe: %s", alternate->bInterfaceNumber, probe_error);
            libusb_release_interface(usb_handle, alternate->bInterfaceNumber);
            free(candidate);
        }
    }

    set_error(error, error_capacity, "%s", last_error);
    libusb_free_config_descriptor(configuration);
    libusb_close(usb_handle);
    libusb_unref_device(device);
    libusb_exit(context);
    return NULL;
}

static speed_t serial_speed(int baud_rate) {
    switch (baud_rate) {
        case 9600: return B9600;
        case 19200: return B19200;
        case 38400: return B38400;
        case 57600: return B57600;
        case 115200: return B115200;
        case 230400: return B230400;
        default: return 0;
    }
}

CBATHandle *cb_at_open_serial(
    const char *path,
    int baud_rate,
    char *error,
    size_t error_capacity
) {
    if (path == NULL || path[0] == '\0') {
        set_error(error, error_capacity, "Serial path is empty");
        return NULL;
    }
    speed_t speed = serial_speed(baud_rate);
    if (speed == 0) {
        set_error(error, error_capacity, "Unsupported serial speed: %d", baud_rate);
        return NULL;
    }

    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        set_error(error, error_capacity, "Unable to open %s: %s", path, strerror(errno));
        return NULL;
    }

    struct termios options;
    if (tcgetattr(fd, &options) != 0) {
        set_error(error, error_capacity, "Unable to read serial settings: %s", strerror(errno));
        close(fd);
        return NULL;
    }
    cfmakeraw(&options);
    cfsetspeed(&options, speed);
    options.c_cflag |= CLOCAL | CREAD;
    options.c_cflag &= ~(PARENB | CSTOPB | CRTSCTS);
    options.c_cflag = (options.c_cflag & ~CSIZE) | CS8;
    if (tcsetattr(fd, TCSANOW, &options) != 0) {
        set_error(error, error_capacity, "Unable to configure serial port: %s", strerror(errno));
        close(fd);
        return NULL;
    }

    CBATHandle *handle = calloc(1, sizeof(CBATHandle));
    if (handle == NULL) {
        set_error(error, error_capacity, "Unable to allocate serial transport");
        close(fd);
        return NULL;
    }
    handle->transport = CB_AT_TRANSPORT_SERIAL;
    handle->serial_fd = fd;
    handle->usb_interface = -1;

    char probe_response[1024] = {0};
    char probe_error[256] = {0};
    CBATResult result = cb_at_command(handle, "AT", probe_response, sizeof(probe_response), 1200, probe_error, sizeof(probe_error));
    if (result != CB_AT_RESULT_OK) {
        set_error(error, error_capacity, "%s did not answer AT: %s", path, probe_error);
        close(fd);
        free(handle);
        return NULL;
    }
    return handle;
}

CBATTransport cb_at_transport(const CBATHandle *handle) {
    return handle == NULL ? 0 : handle->transport;
}

int cb_at_is_open(const CBATHandle *handle) {
    if (handle == NULL) {
        return 0;
    }
    if (handle->transport == CB_AT_TRANSPORT_USB) {
        return handle->usb_handle != NULL;
    }
    return handle->serial_fd >= 0;
}

void cb_at_close(CBATHandle *handle) {
    if (handle == NULL) {
        return;
    }
    if (handle->transport == CB_AT_TRANSPORT_USB && handle->usb_handle != NULL) {
        libusb_release_interface(handle->usb_handle, handle->usb_interface);
        libusb_close(handle->usb_handle);
        libusb_exit(handle->usb_context);
    } else if (handle->transport == CB_AT_TRANSPORT_SERIAL && handle->serial_fd >= 0) {
        close(handle->serial_fd);
    }
    free(handle);
}
