# Battery Session

An [Omarchy](https://omarchy.org) bar widget that tells you how long this battery
charge has **actually** been in use.

Omarchy's power panel shows the current draw and charge level, but not how long
you have been running on this charge. Simple wall-clock time is wrong: it counts
the hours the lid was closed. This plugin counts only the time the machine was
awake, so lock screen and idle time count (the machine is still drawing power),
while suspend and shutdown do not.

## What it shows

On the bar: a battery glyph and one number. Right-click to cycle between:

| Mode | Meaning |
|---|---|
| Time left (all-time avg) | Remaining charge ÷ your average awake power draw across all recorded discharges. Default. |
| Time left (session avg) | Same, using only this discharge's average. |
| Time in use | Awake time since unplugging. |

Click to open the details:

```
Battery life
  Unplugged at           09-03 16:11  100%
  Now                    09-03 23:46   71%
  Time since unplugged   7h 35m
  Suspended / off        5h 27m
  Time in use            2h 08m
  Discharging            now 5.0W · session avg 4.7W
  Time left              6h 04m (session avg 4.7W)
                         4h 10m (all-time avg 6.9W)
```

plus a list of your last eight discharges.

Averages use awake power only. Suspend still draws roughly 1 W on many laptops;
that energy is reported separately as "Used while asleep" so it does not
inflate your estimate.

Languages: English, Traditional Chinese and Simplified Chinese, following the
system locale (`zh_TW` / `zh_HK` / `zh_MO` → Traditional, other `zh` → Simplified).

## How it works

Every 60 seconds a small bash script records the battery state together with
the kernel's scheduler tick count (`/proc/schedstat`). That counter only
advances while the machine is awake, so the awake time between any two samples
is just the difference. Nothing needs to observe suspend or resume events, and
a missed sample, a shell restart, or a reboot self-corrects on the next sample.

Samples go to `~/.local/share/battery-session/YYYY-MM.tsv`, one file per month,
last 12 months kept. Roughly 2 MB per year.

Sampling runs inside the Omarchy shell. When the shell is not running (before
login, or after `omarchy restart shell`) no samples are taken. Awake time is
unaffected; a charge that happened entirely during such a gap is detected from
the jump in stored energy.

## Install

```bash
omarchy plugin add https://github.com/hungmi/omarchy-battery-session
```

The widget appears on the right side of the bar next to the power indicator.
It needs two samples (about a minute) before showing numbers.

Settings, via `omarchy bar set hungmi.battery-session <key> <value>`:

| Key | Values | Default |
|---|---|---|
| `barLabel` | `remainHist` `remainCur` `awake` | `remainHist` |
| `lang` | `auto` `en` `zh-Hant` `zh-Hans` | `auto` |

## Remove

```bash
omarchy plugin remove hungmi.battery-session
```

Removal does not delete the recorded data. To remove that too:

```bash
rm -rf ~/.local/share/battery-session
```

## Requirements

- Omarchy 4.x shell (Quickshell based)
- A laptop battery exposed under `/sys/class/power_supply/` with either
  `energy_now` or `charge_now` + `voltage_now`
- bash and awk (part of any Arch base install). No Python, no extra packages.

## Development

`Model.js` holds the algorithm and is plain JavaScript, so it can be tested
outside the shell:

```bash
node tests/cases.js
```

After editing QML or JS, `omarchy restart shell`. If the widget disappears from
the bar, check `journalctl --user -o cat | grep 'Plugin widget'` for the error.

## License

MIT. No external dependencies.
