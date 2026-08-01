# 第三方软件声明

DJIO 动态链接并随应用打包 libusb 1.0.30。

- 项目：https://libusb.info/
- 许可证：GNU Lesser General Public License v2.1 或更高版本
- 源代码：https://github.com/libusb/libusb

打包后的应用会将 libusb 许可证文本放在
`Contents/Resources/Licenses/libusb-LGPL-2.1.txt`。

DJIO 还随应用打包经过最小补丁的 lpac 2.3.0 辅助程序，以及其依赖的 libeuicc
和 cJSON。lpac 作为独立进程运行，通过换行分隔的 JSON 与 DJIO 通信。

- lpac：https://github.com/estkme-group/lpac
  - 许可证：GNU Affero General Public License v3
- libeuicc：https://github.com/estkme-group/libeuicc
  - 许可证：GNU Lesser General Public License v2.1
- cJSON：https://github.com/DaveGamble/cJSON
  - 许可证：MIT

固定源码版本、构建补丁和校验信息记录在
`Packaging/Helpers/lpac/SOURCE.txt`。打包后的应用会把相应许可证、源码记录和补丁
放在 `Contents/Resources/Licenses/`。
