/*
 * Builds HID input report 1 of the TouchBridge Digitizer (hid_report_desc.inc)
 * from protocol frames. Pure C, also compiled by the CI host test.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef TB_REPORT_H_
#define TB_REPORT_H_

#include <stdbool.h>
#include <stdint.h>

#include "tb_proto.h"

#define TB_REPORT_ID_INPUT      1
#define TB_REPORT_ID_MAX_COUNT  2
#define TB_REPORT_SIZE          64 /* incl. report ID */
#define TB_CONTACT_BYTES        6

struct tb_report_state {
	uint8_t down[16]; /* bitmap: contact ids reported with tip = 1 last time */
	uint16_t last_x[128]; /* last position per id (used for the lift report) */
	uint16_t last_y[128];
};

void tb_report_init(struct tb_report_state *s);
bool tb_report_any_down(const struct tb_report_state *s);

/*
 * Fill out[TB_REPORT_SIZE] from a frame. Contacts that were down before and
 * are missing from the frame are added once with tip = 0, so the OS always
 * sees a lift. Returns the number of contacts in the report.
 * A frame with count 0 lifts every contact that is down.
 */
uint8_t tb_report_build(struct tb_report_state *s, const struct tb_touch_frame *f,
			uint16_t scan_time, uint8_t out[TB_REPORT_SIZE]);

/*
 * Copy the lift entries (tip = 0) of an unsent report `older` into `report`
 * when their id is not in `report` yet and a slot is free.
 */
void tb_report_merge_lifts(uint8_t report[TB_REPORT_SIZE], const uint8_t older[TB_REPORT_SIZE]);

#endif /* TB_REPORT_H_ */
