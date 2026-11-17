#ifndef BARTTERY_WATCHLOG_H
#define BARTTERY_WATCHLOG_H

#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* Only stream syslog if not explicitly known that no watch is paired.
 * In background mode (once == 0), also stream to catch live charger transitions;
 * in one-shot mode (once == 1), stream only as a fallback when registry query failed.
 * Return code -2 indicates the iPhone explicitly reported 0 paired watches. */
static int watchlog_should_stream(int registry_result, int once) {
    if (registry_result == -2) return 0;
    return registry_result != 0 || !once;
}

/* Parse level and charging state in a single pass without duplicate scanning */
static int watchlog_parse(const char *line, int *out_level, int *out_charging) {
    if (!line) return -1;
    if (!strstr(line, "bluetoothd(CoreUtils)") ||
        !strstr(line, "Power source updated CBPowerSource ") ||
        !strstr(line, "AcCa Watch,") || !strstr(line, "Present yes,")) return -1;
    const char *p = strstr(line, "Battery ");
    if (!p) return -1;
    p += strlen("Battery ");
    int chg = -1;
    if (*p == '+') { chg = 1; p++; }
    else if (*p == '-') { chg = 0; p++; }
    if (!isdigit((unsigned char)*p)) return -1;
    char *end = NULL;
    long level = strtol(p, &end, 10);
    if (*end != '%' || level < 0 || level > 100) return -1;
    if (chg < 0) {
        if (strstr(line, "AC yes") || strstr(line, "Chg yes") || strstr(line, "Charging yes"))
            chg = 1;
        else if (strstr(line, "AC no") || strstr(line, "Chg no") || strstr(line, "Charging no"))
            chg = 0;
    }
    if (out_level) *out_level = (int)level;
    if (out_charging) *out_charging = chg;
    return (int)level;
}

/* Only accept a present Watch power-source update, never phone/AirPods data. */
static int watchlog_level(const char *line) {
    int lvl = -1;
    return watchlog_parse(line, &lvl, NULL) >= 0 ? lvl : -1;
}

/* Observed Watch power events use Battery +N% on the charger and -N% off it.
 * An unsigned value has an unknown charging state, not "not charging". */
static int watchlog_charging(const char *line) {
    int chg = -1;
    return watchlog_parse(line, NULL, &chg) >= 0 ? chg : -1;
}
#endif
