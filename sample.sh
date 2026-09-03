#!/bin/bash
# One sample: print one TSV line to stdout and append it to this month's file.
# Called by Service.qml every 60 seconds.
#
#   wall  jiffies  boot  pct  state  ac  energy_wh  power_w
#
# jiffies is the global tick count from the second line of /proc/schedstat. It
# only advances while the machine is awake and freezes during suspend. Stored
# raw; the reader derives HZ from adjacent samples.
# Exit codes read by Service.qml: 3 no battery, 4 clock not synced yet.
set -u

ps=/sys/class/power_supply
dir="${XDG_DATA_HOME:-$HOME/.local/share}/battery-session"
keep_months=12

bat=""
for d in "$ps"/*; do
  [[ -r $d/type && $(<"$d/type") == Battery ]] || continue
  [[ -r $d/scope && $(<"$d/scope") != System ]] && continue   # skip mouse/keyboard batteries
  bat=$d; break
done
[[ -n $bat ]] || exit 3

wall=$(printf '%(%s)T' -1)
(( wall > 1500000000 )) || exit 4   # Asahi boots at 1970 until timesyncd catches up

jiffies=$(awk 'NR==2 {print $2}' /proc/schedstat)
boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id)
pct=$(<"$bat/capacity")
state=$(<"$bat/status")

# Mains power. Ignore per-port USB-C source supplies such as tps6598x.
ac=""
for d in "$ps"/*; do
  [[ -r $d/type && $(<"$d/type") == Mains && -r $d/online ]] || continue
  [[ $(basename "$d") == tps* ]] && continue
  ac=$(<"$d/online"); break
done

# µWh/µW → Wh/W, sign preserved. Devices exposing only charge_now use Ah×V.
uw()  { awk -v v="$(<"$1")" 'BEGIN { printf "%.2f", v / 1e6 }'; }
ahv() { awk -v a="$(<"$1")" -v v="$(<"$2")" 'BEGIN { printf "%.2f", a * v / 1e12 }'; }
wh=""; pw=""
if   [[ -r $bat/energy_now ]]; then wh=$(uw "$bat/energy_now")
elif [[ -r $bat/charge_now && -r $bat/voltage_now ]]; then wh=$(ahv "$bat/charge_now" "$bat/voltage_now"); fi
if   [[ -r $bat/power_now ]]; then pw=$(uw "$bat/power_now")
elif [[ -r $bat/current_now && -r $bat/voltage_now ]]; then pw=$(ahv "$bat/current_now" "$bat/voltage_now"); fi

line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$wall" "$jiffies" "$boot" "$pct" "$state" "$ac" "$wh" "$pw")

mkdir -p "$dir"
f="$dir/$(printf '%(%Y-%m)T' -1).tsv"
[[ -s $f ]] || printf 'wall\tjiffies\tboot\tpct\tstate\tac\tenergy_wh\tpower_w\n' > "$f"
printf '%s\n' "$line" >> "$f"

# Keep only the last N months so the data does not grow forever
ls -1 "$dir"/*.tsv 2>/dev/null | sort | head -n -"$keep_months" | xargs -r rm -f

printf '%s\n' "$line"
