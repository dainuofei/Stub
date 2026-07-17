# Paperang P1 BLE driver

Minimal experimental driver for the original 384-dot Paperang P1.

## 逆向协议摘要

这不是官方 SDK，而是根据官方 iOS App 的 BLE 日志和 P1 真机行为复现的
最小驱动。协议分为三层，必须同时满足：

1. **协议帧**：`02 command sequence payload_length payload crc32 03`。
   长度、CRC 和走纸数值均为 little-endian；CRC 计算时要使用当前 session key。
2. **FF02 字节流**：完整协议流不是一帧一写，而是切成打印机协商出的块大小。
   P1 抓包得到的块大小是 100 字节。
3. **FF03 流控**：`01 count` 表示新增可写 credit，`02 uint16LE` 表示块大小。
   每次 FF02 无响应写入前都必须消耗一个 credit，否则控制命令可能成功而图像数据丢失。

官方 App 先发送一段固定的认证前导包，再用随机 session key 注册 CRC；这段前导
不是账号信息，也不是绑定某一台机器的用户指纹，而是当前 P1 固件需要的协议前置数据。
驱动随后订阅 FF01（响应）、FF03（流控）和辅助通知特征，并按序号等待每条初始化命令的响应。

图像使用 384 dots/行、48 bytes/行的 1 bit 黑白栅格。每个图像协议帧最多携带
21 行（1008 bytes），发送前要按 P1 打印头方向反转行内像素，避免镜像打印。

It follows the transport captured from the official iOS app:

- GATT write: FF02
- GATT notify: FF01
- raster width: 384 dots / 48 bytes per row
- print payload: 1008 bytes / 21 complete rows
- BLE fragmentation: FF03-negotiated 100-byte writes with credit flow control

The default test bar is one complete 21-row image packet: 384 dots wide and
about 2.6 mm high at the P1's approximately 203 dpi. After printing, the
driver feeds a 5 mm tear margin, matching the official app's captured
`0x1A`/`280` final-feed command.

Dry-run the 2–3 mm black test bar:

```sh
python p1_driver.py --dry-run --black-rows 21 --feed-lines 280
```

Run one physical test only after reviewing the dry run:

```sh
python p1_driver.py \
  --address B83D6D59-C50C-BB2F-40A7-A18EFCDB93AE \
  --black-rows 21 \
  --feed-lines 280 \
  --allow-paper-use
```
