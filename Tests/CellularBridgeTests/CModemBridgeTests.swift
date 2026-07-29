import CModemBridge
import Testing

struct CModemBridgeTests {
  @Test func recognizesOnlyFinalATResults() {
    #expect(cb_at_terminal_status("\r\nOK\r\n") == 1)
    #expect(cb_at_terminal_status("\r\nERROR\r\n") == -1)
    #expect(cb_at_terminal_status("\r\n+CME ERROR: 30\r\n") == -1)
    #expect(cb_at_terminal_status("\r\n+CMS ERROR: 500\r\n") == -1)
    #expect(cb_at_terminal_status("\r\n+CSQ: 20,99\r\n") == 0)
  }

  @Test func missingUSBDeviceIsNotReportedPresent() {
    #expect(cb_usb_device_present(0xFFFF, 0xFFFF) == 0)
  }
}
