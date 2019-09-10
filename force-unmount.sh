#!/bin/bash

# force-unmount.sh 1.2
# (C) 2016-2019 Matvey Soloviev (blackhole89@gmail.com)
#
# Usage: sudo ./force-unmount.sh <mount point>
#
# Use gdb to pull open file handles to a volume from under a process's
# feet and move its working directory off as necessary, then attempts a
# genuine forced unmounting of the volume.
#
# This may result in processes crashing left and right and otherwise
# exhibiting undefined behaviour, so use at your own risk.

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

if [[ ( -z "$1" ) || ( "$1" == /dev* ) ]]
then
    echo "Usage: sudo force-unmount.sh <mount point>"
    echo ""
    echo "Note that <mount point> must be the point in the file system"
    echo "at which the volume is mounted, not the device."
    exit
fi

if [[ "$(id -u)" != "0" ]]
then
    echo "WARNING: Must probably be root to do this!"
fi

# Find file handles pointing to subfolders of $2 owned by PID $1
proc_files_in_prefix() {
    local files=$(cd /proc/$1/fd;ls)
    if [[ $files ]]; then
        # Readlinking the whole list at once is faster than doing it one-by-one.
        # Need to be careful to strip occasional (deleted) spam.
        local links=$(cd /proc/$1/fd;readlink $files|sed -e 's/(deleted)//g')
        local files=($files)
        # Links may contain spaces. Make sure we tokenise linewise.
        IFS=$'\r\n' GLOBIGNORE='*' command eval 'local links=($links)'
        for num in `seq 0 $((${#files[@]}-1))`; do
            if [[ "${links[$num]}" == "$2"* ]]
            then
                echo ${files[$num]}
            fi
        done
    fi
}

# Build GDB commands for PID $1 to chdir out of volume $2 and close file handles listed in stdin
build_gdb_commands() {
    # Move out of working directory on target if needed.
    if [[ `readlink /proc/$1/cwd` == "$2"* ]]
    then
        echo "call (int)chdir(\"/\")"
    fi
    # Repoint all file handles passed in at /dev/null.
    sed -e 's/^/call (int)dup2($devnull,/' - | sed -e 's/$/)/'
}

# Disentangle PID $1 from volume $2
handle_pid() {
    local cmds=$(proc_files_in_prefix $1 "$2" 2>/dev/null | build_gdb_commands $1 "$2")
    if [[ $cmds ]]; then
        (cat <<PREAMBLE
set auto-solib-add off
attach $1
sharedlibrary libc
set \$devnull = (int)open("/dev/null",2,0)
$cmds
call (int)close(\$devnull)
PREAMBLE
        ) | gdb >/dev/null 2>/dev/null
        #echo $1
    fi
}

for proc in `ps -A -o pid | tail -n +2`; do
    handle_pid $proc "$1"
done

umount "$1"

