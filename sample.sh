#!/bin/bash
# 一次取樣：印一行 TSV 到 stdout，並 append 到月檔。由 Service.qml 每 60 秒呼叫。
#
#   wall  jiffies  boot  pct  state  ac  energy_wh  power_w
#
# jiffies 是 /proc/schedstat 第二行的全域 tick 數，只在機器醒著時前進，
# suspend 時凍結。存原始值不換算——HZ 由讀取端從相鄰兩筆推。
# 三個 exit code 給 Service 判讀：3 沒電池、4 時鐘還沒同步。
set -u

ps=/sys/class/power_supply
dir="${XDG_DATA_HOME:-$HOME/.local/share}/battery-session"
keep_months=12

bat=""
for d in "$ps"/*; do
  [[ -r $d/type && $(<"$d/type") == Battery ]] || continue
  [[ -r $d/scope && $(<"$d/scope") != System ]] && continue   # 滑鼠鍵盤的電池不算
  bat=$d; break
done
[[ -n $bat ]] || exit 3

wall=$(printf '%(%s)T' -1)
(( wall > 1500000000 )) || exit 4   # Asahi 開機時是 1970，等 timesyncd 同步

jiffies=$(awk 'NR==2 {print $2}' /proc/schedstat)
boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id)
pct=$(<"$bat/capacity")
state=$(<"$bat/status")

# 主電源。忽略 tps6598x 那類 USB-C port 的 source-psy。
ac=""
for d in "$ps"/*; do
  [[ -r $d/type && $(<"$d/type") == Mains && -r $d/online ]] || continue
  [[ $(basename "$d") == tps* ]] && continue
  ac=$(<"$d/online"); break
done

# µWh/µW → Wh/W，保留符號。只有 charge_now 的裝置用 Ah×V 換算。
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

# 只留最近 N 個月，別在別人機器上無限長
ls -1 "$dir"/*.tsv 2>/dev/null | sort | head -n -"$keep_months" | xargs -r rm -f

printf '%s\n' "$line"
