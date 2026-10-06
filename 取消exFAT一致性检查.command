#!/bin/zsh

case "${1:-}" in
  '') ;;
  --dry-run) ;;
  -h|--help) print -- '用法：取消exFAT一致性检查.command [--dry-run]'; exit 0 ;;
  *) print -u2 -- "未知参数：$1"; exit 2 ;;
esac
(( $# <= 1 )) || { print -u2 -- '参数过多。'; exit 2; }


# 双击运行：取消外接 exFAT 一致性检查，清除脏标记并强制读写挂载。
set -u
export PATH='/usr/bin:/bin:/usr/sbin:/sbin'

readonly FSKIT_EXFAT='/System/Library/ExtensionKit/Extensions/com.apple.fskit.exfat.appex/Contents/MacOS/com.apple.fskit.exfat'
readonly KEYCHAIN_SERVICE='local.exfat-force-mount.sudo'
readonly TOTAL_LIMIT=55
readonly DRY_RUN=${1:-}
typeset -i started_at=$SECONDS
typeset -i stopped_count=0
typeset -i mounted_count=0
typeset -i failed_count=0

notify() {
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

acquire_admin() {
  local saved_password=''

  # 优先使用尚未过期的 sudo 授权，不读取钥匙串。
  /usr/bin/sudo -n true >/dev/null 2>&1 && return 0

  # 从登录钥匙串读取；密码只在内存中短暂停留，不写入脚本或日志。
  saved_password=$(/usr/bin/security find-generic-password \
    -a "$USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) || saved_password=''

  if [[ -n "$saved_password" ]]; then
    if /usr/bin/printf '%s\n' "$saved_password" | \
      /usr/bin/sudo -S -p '' -v >/dev/null 2>&1; then
      saved_password=''
      unset saved_password
      return 0
    fi
  fi

  saved_password=''
  unset saved_password
  /usr/bin/sudo -k
  print '自动凭据不可用，改为人工输入密码。'
  /usr/bin/sudo -v
}

discover_checks() {
  /bin/ps -axo pid=,state=,command= 2>/dev/null | /usr/bin/awk -v fskit="$FSKIT_EXFAT" '
    $3 == fskit && $2 ~ /U/ { print $1, "FSKit", $2 }
    $3 ~ /(^|\/)fsck_exfat$/ { print $1, "fsck_exfat", $2 }
  '
}

cancel_checks() {
  local max_wait=${1:-15}
  typeset -A age
  typeset -A kind_by_pid
  local pid kind state
  local -i waited=0
  local -i stable=0
  local -i found=0
  local -i alive=0

  while (( waited < max_wait )); do
    found=0
    while read -r pid kind state; do
      [[ -n "${pid:-}" ]] || continue
      found=1
      if [[ -z "${age[$pid]-}" ]]; then
        age[$pid]=0
        kind_by_pid[$pid]="$kind"
        (( stopped_count++ ))
        print "  → 中断 $kind（PID $pid，状态 $state）"
        /usr/bin/sudo /bin/kill -INT "$pid" 2>/dev/null || true
      fi
    done < <(discover_checks)

    alive=0
    for pid in ${(k)age}; do
      if /usr/bin/sudo /bin/kill -0 "$pid" 2>/dev/null; then
        alive=1
        age[$pid]=$(( age[$pid] + 1 ))
        if (( age[$pid] == 3 )); then
          /usr/bin/sudo /bin/kill -TERM "$pid" 2>/dev/null || true
        elif (( age[$pid] == 6 )); then
          /usr/bin/sudo /bin/kill -KILL "$pid" 2>/dev/null || true
        fi
      else
        unset "age[$pid]"
        unset "kind_by_pid[$pid]"
      fi
    done

    if (( found == 0 && alive == 0 )); then
      (( stable++ ))
      (( stable >= 2 )) && return 0
    else
      stable=0
    fi
    sleep 1
    (( waited++ ))
  done
  return 0
}

discover_exfat_devices() {
  local device info fs protocol
  /usr/sbin/diskutil list external 2>/dev/null | \
    /usr/bin/awk '$NF ~ /^disk[0-9]+s[0-9]+$/ { print $NF }' | /usr/bin/sort -u | \
    while read -r device; do
      info=$(/usr/sbin/diskutil info "$device" 2>/dev/null) || continue
      fs=$(print -r -- "$info" | /usr/bin/awk -F: '/File System Personality/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
      protocol=$(print -r -- "$info" | /usr/bin/awk -F: '/Protocol/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
      [[ "${fs:l}" == 'exfat' ]] || continue
      [[ "${protocol:l}" == 'disk image' ]] && continue
      print -r -- "$device"
    done
}

device_info_value() {
  local info="$1"
  local key="$2"
  print -r -- "$info" | /usr/bin/awk -F: -v key="$key" '$1 ~ key {gsub(/^[[:space:]]+/, "", $2); print $2; exit}'
}

clear_dirty_flag() {
  local device="$1"
  local raw_device="/dev/r$device"
  /usr/bin/sudo /usr/bin/perl -e '
    use strict; use warnings;
    my $path = shift;
    sysopen(my $fh, $path, 2) or die "open $path: $!";
    sysseek($fh, 0, 0) == 0 or die "seek: $!";
    sysread($fh, my $head, 512) == 512 or die "read: $!";
    substr($head, 3, 8) eq "EXFAT   " or die "not exfat";
    my $shift = ord(substr($head, 108, 1));
    ($shift >= 9 && $shift <= 12) or die "invalid sector size";
    my $sector_size = 1 << $shift;
    my @flags;
    for my $offset (0, 12 * $sector_size) {
      sysseek($fh, $offset, 0) == $offset or die "seek: $!";
      sysread($fh, my $sector, $sector_size) == $sector_size or die "read: $!";
      substr($sector, 3, 8) eq "EXFAT   " or die "invalid boot sector";
      my $before = unpack("v", substr($sector, 106, 2));
      my $after = $before & ~2;
      if ($before != $after) {
        substr($sector, 106, 2) = pack("v", $after);
        sysseek($fh, $offset, 0) == $offset or die "seek: $!";
        syswrite($fh, $sector, $sector_size) == $sector_size or die "write: $!";
      }
      push @flags, "$before->$after";
    }
    close($fh) or die "close: $!";
    print join(",", @flags);
  ' "$raw_device"
}

mount_line_for() {
  local device="$1"
  /sbin/mount | /usr/bin/awk -v source="/dev/$device" '$1 == source { print; exit }'
}

run_mount_attempt() {
  local device="$1"
  local log_file
  local mount_pid
  local -i ticks=0
  log_file=$(/usr/bin/mktemp /private/tmp/exfat-force-mount.XXXXXX)

  /usr/sbin/diskutil mount -mountOptions rw,noowners "$device" > "$log_file" 2>&1 &
  mount_pid=$!

  while /bin/kill -0 "$mount_pid" 2>/dev/null; do
    while read -r pid kind state; do
      [[ -n "${pid:-}" ]] || continue
      /usr/bin/sudo /bin/kill -INT "$pid" 2>/dev/null || true
    done < <(discover_checks)

    if (( ticks >= 32 )); then
      /bin/kill -INT "$mount_pid" 2>/dev/null || true
      sleep 1
      /bin/kill -KILL "$mount_pid" 2>/dev/null || true
      break
    fi
    sleep 0.25
    (( ticks++ ))
  done

  wait "$mount_pid" 2>/dev/null || true
  /bin/cat "$log_file"
  /bin/rm -f "$log_file"
}

force_mount_device() {
  local device="$1"
  local info name mounted flags line
  local -i attempt=1

  info=$(/usr/sbin/diskutil info "$device" 2>/dev/null) || return 1
  name=$(device_info_value "$info" 'Volume Name')
  mounted=$(device_info_value "$info" 'Mounted')
  [[ -n "$name" ]] || name="$device"

  if [[ "$mounted" == 'Yes' ]]; then
    line=$(mount_line_for "$device")
    if [[ -n "$line" && "$line" != *'read-only'* ]]; then
      print "  ✓ $name 已经读写挂载"
      return 0
    fi
  fi

  while (( attempt <= 3 && SECONDS - started_at < TOTAL_LIMIT )); do
    print "  → $name：清除 exFAT 脏标记（第 $attempt 次）"
    cancel_checks 3
    flags=$(clear_dirty_flag "$device" 2>&1) || {
      print "    原始分区暂时被占用：$flags"
      (( attempt++ ))
      sleep 1
      continue
    }
    /bin/sync
    print "    标记：$flags；正在挂载 $device"
    run_mount_attempt "$device"

    line=$(mount_line_for "$device")
    if [[ -n "$line" && "$line" != *'read-only'* ]]; then
      print "  ✓ $name 已读写挂载：${line%% \(*}"
      return 0
    fi

    cancel_checks 3
    (( attempt++ ))
  done
  print "  ✗ $name 挂载失败"
  return 1
}

print '⚡ exFAT 检查取消 + 强制挂载器'
print '----------------------------------'

if [[ "$DRY_RUN" == '--dry-run' ]]; then
  print '活跃检查进程：'
  checks=$(discover_checks)
  [[ -n "$checks" ]] && print -r -- "$checks" || print '无'
  print '检测到的外接 exFAT 分区：'
  devices=$(discover_exfat_devices)
  [[ -n "$devices" ]] && print -r -- "$devices" || print '无'
  exit 0
fi

print '正在自动取得管理员权限；失败时会提示人工输入。'
if ! acquire_admin; then
  print '✗ 未取得管理员权限。'
  notify 'exFAT 强制挂载失败' '未取得管理员权限'
  sleep 4
  exit 1
fi

print '1/3 取消全部 exFAT 一致性检查……'
cancel_checks 15

print '2/3 扫描外接 exFAT 分区……'
typeset -a devices
devices=(${(f)"$(discover_exfat_devices)"})
if (( ${#devices} == 0 )); then
  print '✗ 没有检测到外接 exFAT 分区，请检查数据线和设备模式。'
  notify 'exFAT 强制挂载失败' '没有检测到外接 exFAT 分区'
  sleep 5
  exit 2
fi

print "3/3 强制读写挂载 ${#devices} 个 exFAT 分区……"
for device in $devices; do
  if force_mount_device "$device"; then
    (( mounted_count++ ))
  else
    (( failed_count++ ))
  fi
  (( SECONDS - started_at >= TOTAL_LIMIT )) && break
done

if (( mounted_count == ${#devices} && failed_count == 0 )); then
  print "✓ 完成：${#devices} 个 exFAT 分区均已读写挂载。"
  notify 'exFAT 已强制挂载' "${#devices} 个分区均已读写挂载"
  result=0
else
  print "✗ 已挂载 $mounted_count 个，失败 $failed_count 个。"
  notify 'exFAT 未完全挂载' "成功 $mounted_count 个，失败 $failed_count 个"
  result=3
fi

print '窗口将在 5 秒后关闭。'
sleep 5
exit "$result"
