/*
 * TouchBridge Digitizer - nRF52840 USB multitouch bridge (Pro Micro nRF52840 / nice!nano v2).
 *
 * USB composite device 2fe3:0010 "TouchBridge Digitizer" (Zephyr device_next stack):
 *   - CDC ACM: TouchBridge on the Mac sends contact frames (PROTOCOL.md)
 *   - HID touch screen (Digitizer 0x0D / Touch Screen 0x04, 10 contacts):
 *     every frame is re-emitted as HID input report 1, so macOS sees a real
 *     USB digitizer instead of synthetic events.
 *
 * Safety: all contacts are lifted when no frame arrives for 200 ms while a
 * finger is down, when the host closes the port (DTR 0) and on TB_MSG_RELEASE_ALL.
 * "1200 baud touch" or TB_MSG_BOOTLOADER reboots into the UF2 bootloader.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/linker/linker-defs.h>
#include <zephyr/sys/ring_buffer.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/usb/usbd.h>
#include <zephyr/usb/class/usbd_hid.h>

#include <soc.h>
#include <app_version.h>

#include "tb_proto.h"
#include "tb_report.h"

#define TB_VID 0x2FE3
#define TB_PID 0x0010

#define RELEASE_TIMEOUT_MS 200
#define TOUCH_BAUD         1200U
#define UF2_RESET_MAGIC    0x57 /* DFU_MAGIC_UF2_RESET (Adafruit nRF52 bootloader) */

/* hello reply flags */
#define HELLO_FLAG_BOOTLOADER_CMD BIT(0)
#define HELLO_FLAG_TOUCH_1200     BIT(1)

static const uint8_t hid_report_desc[] = {
#include "hid_report_desc.inc"
};

static const struct device *const cdc_dev = DEVICE_DT_GET(DT_NODELABEL(board_cdc_acm_uart));
static const struct device *const hid_dev = DEVICE_DT_GET(DT_NODELABEL(touch_hid));

/* ------------------------------------------------------------------ USB device */

USBD_DEVICE_DEFINE(tb_usbd, DEVICE_DT_GET(DT_NODELABEL(zephyr_udc0)), TB_VID, TB_PID);
USBD_DESC_LANG_DEFINE(tb_lang);
USBD_DESC_MANUFACTURER_DEFINE(tb_mfr, "TouchBridge");
USBD_DESC_PRODUCT_DEFINE(tb_product, "TouchBridge Digitizer");
USBD_DESC_SERIAL_NUMBER_DEFINE(tb_sn);
USBD_DESC_CONFIG_DEFINE(tb_fs_cfg_desc, "FS Configuration");
/* bus powered, 100 mA */
USBD_CONFIGURATION_DEFINE(tb_fs_config, 0, 50, &tb_fs_cfg_desc);

static int usb_setup(void)
{
	int err;

	err = usbd_add_descriptor(&tb_usbd, &tb_lang);
	err = err ? err : usbd_add_descriptor(&tb_usbd, &tb_mfr);
	err = err ? err : usbd_add_descriptor(&tb_usbd, &tb_product);
	err = err ? err : usbd_add_descriptor(&tb_usbd, &tb_sn);
	err = err ? err : usbd_add_configuration(&tb_usbd, USBD_SPEED_FS, &tb_fs_config);
	err = err ? err : usbd_register_all_classes(&tb_usbd, USBD_SPEED_FS, 1, NULL);
	if (err) {
		return err;
	}
	/* CDC ACM has an Interface Association Descriptor */
	usbd_device_set_code_triple(&tb_usbd, USBD_SPEED_FS, USB_BCC_MISCELLANEOUS, 0x02, 0x01);
	usbd_self_powered(&tb_usbd, false);
	err = usbd_init(&tb_usbd);
	return err ? err : usbd_enable(&tb_usbd);
}

/* ------------------------------------------------------------------ status LED */

enum led_mode { LED_NO_USB, LED_WAITING, LED_CONNECTED, LED_TOUCHING };
static atomic_t led_mode = ATOMIC_INIT(LED_NO_USB);

#if DT_NODE_EXISTS(DT_ALIAS(led0))
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

/*   no USB host      : short blip every 2 s
 *   USB, port closed : slow blink (1 Hz)
 *   TouchBridge open : steady on
 *   finger(s) down   : fast blink (5 Hz)
 */
static void led_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
	uint32_t tick = 0;

	if (!gpio_is_ready_dt(&led) || gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE)) {
		return;
	}
	while (true) {
		bool on;

		switch (atomic_get(&led_mode)) {
		case LED_TOUCHING:  on = (tick & 1U) == 0U; break;
		case LED_CONNECTED: on = true; break;
		case LED_WAITING:   on = (tick % 10U) < 5U; break;
		default:            on = (tick % 20U) == 0U; break;
		}
		gpio_pin_set_dt(&led, on);
		tick++;
		k_msleep(100);
	}
}
K_THREAD_DEFINE(led_tid, 512, led_thread, NULL, NULL, NULL, K_LOWEST_APPLICATION_THREAD_PRIO, 0, 0);
#endif

/* ------------------------------------------------------------------ CDC ACM */

RING_BUF_DECLARE(rx_ring, 1024);
RING_BUF_DECLARE(tx_ring, 256);
static K_SEM_DEFINE(wake_sem, 0, 1);

static void cdc_irq(const struct device *dev, void *user_data)
{
	ARG_UNUSED(user_data);

	while (uart_irq_update(dev) && uart_irq_is_pending(dev)) {
		if (uart_irq_rx_ready(dev)) {
			uint8_t buf[64];
			int n = uart_fifo_read(dev, buf, sizeof(buf));

			if (n > 0) {
				(void)ring_buf_put(&rx_ring, buf, n); /* overflow: bytes dropped, CRC catches it */
				k_sem_give(&wake_sem);
			}
		}
		if (uart_irq_tx_ready(dev)) {
			uint8_t buf[64];
			uint32_t n = ring_buf_peek(&tx_ring, buf, sizeof(buf));

			if (n == 0) {
				uart_irq_tx_disable(dev);
			} else {
				int sent = uart_fifo_fill(dev, buf, n);

				if (sent > 0) {
					ring_buf_get(&tx_ring, NULL, sent);
				}
			}
		}
	}
}

static void send_msg(const uint8_t *payload, uint8_t len)
{
	uint8_t frame[TB_MAX_PAYLOAD + 3];
	size_t n = tb_encode_frame(payload, len, frame, sizeof(frame));

	if (n == 0) {
		return;
	}
	unsigned int key = irq_lock();

	if (ring_buf_space_get(&tx_ring) >= n) {
		ring_buf_put(&tx_ring, frame, n);
	}
	irq_unlock(key);
	uart_irq_tx_enable(cdc_dev);
}

/* ------------------------------------------------------------------ firmware identity */

static uint8_t fw_variant(void)
{
	switch ((uint32_t)(uintptr_t)_vector_start) {
	case 0x26000: return 1; /* s140v6 */
	case 0x27000: return 2; /* s140v7 */
	case 0x1000:  return 3; /* nosd   */
	default:      return 0;
	}
}

static void send_hello_reply(void)
{
	uint32_t load = (uint32_t)(uintptr_t)_vector_start;
	uint8_t p[] = {
		TB_MSG_HELLO_REPLY, TB_PROTO_VERSION,
		APP_VERSION_MAJOR, APP_VERSION_MINOR, APP_PATCHLEVEL,
		TB_MAX_CONTACTS, fw_variant(), HELLO_FLAG_BOOTLOADER_CMD | HELLO_FLAG_TOUCH_1200,
		(uint8_t)load, (uint8_t)(load >> 8), (uint8_t)(load >> 16), (uint8_t)(load >> 24),
		'T', 'B', 'D', 'G',
	};

	send_msg(p, sizeof(p));
}

static void send_error(uint8_t code)
{
	uint8_t p[] = { TB_MSG_ERROR, code };

	send_msg(p, sizeof(p));
}

static FUNC_NORETURN void enter_uf2_bootloader(void)
{
	(void)irq_lock();
	/* read and cleared by the Adafruit nRF52 bootloader after reset */
	NRF_POWER->GPREGRET = UF2_RESET_MAGIC;
	NVIC_SystemReset();
	CODE_UNREACHABLE;
}

/* ------------------------------------------------------------------ HID */

static atomic_t hid_ready;
static atomic_t hid_busy;
static struct tb_report_state rstate;
/* latest report waiting for the IN endpoint (coalesced while one is in flight) */
static uint8_t pending_report[TB_REPORT_SIZE];
static bool have_pending;
UDC_STATIC_BUF_DEFINE(tx_report, TB_REPORT_SIZE);

static void hid_iface_ready(const struct device *dev, const bool ready)
{
	ARG_UNUSED(dev);
	atomic_set(&hid_ready, ready);
	if (!ready) {
		atomic_set(&hid_busy, 0);
	}
	k_sem_give(&wake_sem);
}

static int hid_get_report(const struct device *dev, const uint8_t type, const uint8_t id,
			  const uint16_t len, uint8_t *const buf)
{
	ARG_UNUSED(dev);
	if (type == HID_REPORT_TYPE_FEATURE && id == TB_REPORT_ID_MAX_COUNT && len >= 2) {
		buf[0] = TB_REPORT_ID_MAX_COUNT;
		buf[1] = TB_MAX_CONTACTS;
		return 2;
	}
	if (type == HID_REPORT_TYPE_INPUT && id == TB_REPORT_ID_INPUT && len >= TB_REPORT_SIZE) {
		/* current state: nothing down after a GET_REPORT is acceptable */
		memset(buf, 0, TB_REPORT_SIZE);
		buf[0] = TB_REPORT_ID_INPUT;
		return TB_REPORT_SIZE;
	}
	return -ENOTSUP;
}

static int hid_set_report(const struct device *dev, const uint8_t type, const uint8_t id,
			  const uint16_t len, const uint8_t *const buf)
{
	ARG_UNUSED(dev); ARG_UNUSED(type); ARG_UNUSED(id); ARG_UNUSED(len); ARG_UNUSED(buf);
	return 0; /* nothing configurable; accept so hosts do not stall */
}

static void hid_report_done(const struct device *dev, const uint8_t *const report)
{
	ARG_UNUSED(dev); ARG_UNUSED(report);
	atomic_set(&hid_busy, 0);
	k_sem_give(&wake_sem);
}

static const struct hid_device_ops hid_ops = {
	.iface_ready = hid_iface_ready,
	.get_report = hid_get_report,
	.set_report = hid_set_report,
	.input_report_done = hid_report_done,
};

static void hid_flush(void)
{
	if (!have_pending || !atomic_get(&hid_ready) || atomic_get(&hid_busy)) {
		return;
	}
	memcpy(tx_report, pending_report, TB_REPORT_SIZE);
	atomic_set(&hid_busy, 1);
	if (hid_device_submit_report(hid_dev, TB_REPORT_SIZE, tx_report) != 0) {
		atomic_set(&hid_busy, 0);
		return; /* keep it pending, retried on the next wake-up */
	}
	have_pending = false;
}

static uint16_t scan_time(void)
{
	/* 100 us units, wraps at 65535 */
	return (uint16_t)(k_ticks_to_us_floor64(k_uptime_ticks()) / 100U);
}

static void queue_frame(const struct tb_touch_frame *f)
{
	uint8_t old[TB_REPORT_SIZE];
	bool had_pending = have_pending;

	if (had_pending) {
		memcpy(old, pending_report, sizeof(old));
	}
	tb_report_build(&rstate, f, scan_time(), pending_report);
	if (had_pending) {
		/* the unsent report is replaced: keep its lifts (tip = 0 entries),
		 * otherwise the OS would never see those contacts go up */
		tb_report_merge_lifts(pending_report, old);
	}
	have_pending = true;
	hid_flush();
}

static void release_all(void)
{
	if (!tb_report_any_down(&rstate)) {
		return;
	}
	struct tb_touch_frame none = { .count = 0 };

	queue_frame(&none);
}

/* ------------------------------------------------------------------ main loop */

static void handle_payload(const uint8_t *p, int len, int64_t *last_frame)
{
	switch (p[0]) {
	case TB_MSG_TOUCH: {
		struct tb_touch_frame f;
		int err = tb_decode_touch(p, (size_t)len, &f);

		if (err) {
			send_error((uint8_t)err);
			return;
		}
		*last_frame = k_uptime_get();
		queue_frame(&f);
		break;
	}
	case TB_MSG_HELLO:
		send_hello_reply();
		break;
	case TB_MSG_RELEASE_ALL:
		release_all();
		break;
	case TB_MSG_BOOTLOADER:
		k_msleep(50);
		enter_uf2_bootloader();
	default:
		send_error(TB_ERR_TYPE);
		break;
	}
}

int main(void)
{
	static struct tb_parser parser;
	int64_t last_frame = 0;
	uint32_t last_dtr = 0;

	tb_parser_init(&parser);
	tb_report_init(&rstate);

	if (!device_is_ready(cdc_dev) || !device_is_ready(hid_dev)) {
		return 0;
	}
	if (hid_device_register(hid_dev, hid_report_desc, sizeof(hid_report_desc), &hid_ops)) {
		return 0;
	}
	if (usb_setup()) {
		return 0;
	}
	uart_irq_callback_set(cdc_dev, cdc_irq);
	uart_irq_rx_enable(cdc_dev);

	while (true) {
		(void)k_sem_take(&wake_sem, K_MSEC(20));

		uint8_t buf[64];
		uint32_t n;

		while ((n = ring_buf_get(&rx_ring, buf, sizeof(buf))) > 0) {
			for (uint32_t i = 0; i < n; i++) {
				int len = tb_parser_feed(&parser, buf[i]);

				if (len > 0) {
					handle_payload(parser.buf, len, &last_frame);
				}
			}
		}

		/* host port state: DTR drop releases everything; 1200 baud touch -> bootloader */
		uint32_t dtr = 0, baud = 0;

		(void)uart_line_ctrl_get(cdc_dev, UART_LINE_CTRL_DTR, &dtr);
		if (uart_line_ctrl_get(cdc_dev, UART_LINE_CTRL_BAUD_RATE, &baud) == 0 &&
		    baud == TOUCH_BAUD && dtr == 0U) {
			release_all();
			k_msleep(50);
			enter_uf2_bootloader();
		}
		if (last_dtr && !dtr) {
			release_all();
			tb_parser_init(&parser);
		}
		last_dtr = dtr;

		if (tb_report_any_down(&rstate) && k_uptime_get() - last_frame > RELEASE_TIMEOUT_MS) {
			release_all();
		}
		hid_flush();

		if (!atomic_get(&hid_ready)) {
			atomic_set(&led_mode, LED_NO_USB);
		} else if (!dtr) {
			atomic_set(&led_mode, LED_WAITING);
		} else {
			atomic_set(&led_mode, tb_report_any_down(&rstate) ? LED_TOUCHING : LED_CONNECTED);
		}
	}
	return 0;
}
