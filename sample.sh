#!/usr/bin/bash
# One sample: print one TSV line to stdout and append it to this month's file.
# Called by Service.qml every 60 seconds as
#   /usr/bin/bash --noprofile --norc sample.sh
# with a cleared environment (PATH=/usr/bin, LC_ALL=C and TZ only).
#
#   wall  jiffies  boot  pct  state  ac  energy_wh  power_w
#
# jiffies is the global tick count from the second line of /proc/schedstat. It
# only advances while the machine is awake and freezes during suspend. Stored
# raw; the reader derives HZ from adjacent samples.
#
# Trust boundary: everything is bash builtins reading /sys and /proc. The only
# external programs are /usr/bin/mkdir (first run) and /usr/bin/rm (monthly
# retention), both by absolute path. The data directory is derived from the
# password database (~ with HOME unset), never from environment strings, and
# every directory and file is verified to be owned by us, not a symlink, and a
# regular file before it is created, appended to, or deleted.
#
# Exit codes read by Service.qml: 3 no battery, 4 clock not synced yet,
# 5 data directory or file failed verification.
set -u
umask 077
export PATH=/usr/bin LC_ALL=C
unset -v HOME CDPATH IFS
shopt -s nullglob

ps=/sys/class/power_supply
keep_months=12

# ---- locate the system battery (skip mouse/keyboard batteries) ----
bat=""
for d in "$ps"/*; do
  [[ -r $d/type ]] && read -r t < "$d/type" || continue
  [[ $t == Battery ]] || continue
  if [[ -r $d/scope ]]; then read -r s < "$d/scope"; [[ $s == System ]] || continue; fi
  bat=$d; break
done
[[ -n $bat ]] || exit 3

printf -v wall '%(%s)T' -1
(( wall > 1500000000 )) || exit 4   # Asahi boots at 1970 until timesyncd catches up

# ---- awake-only tick counter ----
{ read -r _; read -r _ jiffies _; } < /proc/schedstat
[[ $jiffies =~ ^[0-9]{1,20}$ ]] || exit 4

read -r bootid < /proc/sys/kernel/random/boot_id
boot=${bootid:0:8}

# Reads a sysfs integer into the named variable; empty if missing or malformed.
rdint() {
  local -n out=$1; out=""
  local v
  [[ -r $2 ]] && read -r v < "$2" || return 0
  [[ $v =~ ^-?[0-9]{1,18}$ ]] && out=$v
}
# Fixed-point: value / 10^scale with two decimals, sign kept, integers only.
fix2() {  # fix2 <int> <scale>
  local v=$1 s="" div=1 i
  (( v < 0 )) && { s=-; v=$(( -v )); }
  for (( i = 0; i < $2; i++ )); do div=$(( div * 10 )); done
  printf '%s%d.%02d' "$s" $(( v / div )) $(( v % div / (div / 100) ))
}

rdint pct "$bat/capacity"
read -r state < "$bat/status" 2>/dev/null || state=""
state_re='^[A-Za-z ]{1,20}$'
[[ $state =~ $state_re ]] || state=Unknown

# Mains power. Ignore per-port USB-C source supplies such as tps6598x.
ac=""
for d in "$ps"/*; do
  [[ ${d##*/} == tps* ]] && continue
  [[ -r $d/type && -r $d/online ]] && read -r t < "$d/type" || continue
  [[ $t == Mains ]] || continue
  rdint ac "$d/online"; break
done

# µWh/µW → Wh/W. Devices exposing only charge_now use µAh × µV = 1e-12 Wh.
wh=""; pw=""
rdint e "$bat/energy_now";  rdint p "$bat/power_now"
rdint q "$bat/charge_now";  rdint i "$bat/current_now"; rdint v "$bat/voltage_now"
if   [[ -n $e ]];            then wh=$(fix2 "$e" 6)
elif [[ -n $q && -n $v ]];   then wh=$(fix2 $(( q * v )) 12); fi
if   [[ -n $p ]];            then pw=$(fix2 "$p" 6)
elif [[ -n $i && -n $v ]];   then pw=$(fix2 $(( i * v )) 12); fi

printf -v line '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$wall" "$jiffies" "$boot" "$pct" "$state" "$ac" "$wh" "$pw"

# ---- data directory: ~/.local/share/battery-session, verified at every level ----
# HOME is unset above, so ~ comes from the password database.
home=~
[[ $home == /* && -d $home && ! -L $home && -O $home ]] || exit 5
owned_dir() { [[ -d $1 && ! -L $1 && -O $1 ]]; }
owned_dir "$home/.local" || exit 5
owned_dir "$home/.local/share" || exit 5
dir=$home/.local/share/battery-session
if [[ ! -e $dir ]]; then /usr/bin/mkdir -m 700 -- "$dir" || exit 5; fi
owned_dir "$dir" || exit 5

printf -v month '%(%Y-%m)T' -1
f=$dir/$month.tsv
if [[ -e $f ]]; then
  [[ -f $f && ! -L $f && -O $f ]] || exit 5
else
  printf 'wall\tjiffies\tboot\tpct\tstate\tac\tenergy_wh\tpower_w\n' > "$f" || exit 5
fi
printf '%s\n' "$line" >> "$f" || exit 5

# ---- keep only the last N month files (glob is sorted, LC_ALL=C) ----
files=("$dir"/[0-9][0-9][0-9][0-9]-[0-9][0-9].tsv)
if (( ${#files[@]} > keep_months )); then
  for old in "${files[@]:0:${#files[@]}-keep_months}"; do
    [[ -f $old && ! -L $old && -O $old ]] && /usr/bin/rm -f -- "$old"
  done
fi

printf '%s\n' "$line"
