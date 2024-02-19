#!/bin/bash
# Script to do a fairly thorough check of a MariaDB or MySQL database
# 2024-01-30 / Peter Möller
# Department of Computer Science, Lund University

# Comment strings comes from https://patorjk.com/software/taag/#p=display&f=Doom&t=Comment


# Read nessesary settings file. Exit if it’s not found
# The following variables *must* be set
# - SQLCommand              Command to get to access the database                      (example: 'docker exec db_docker /usr/bin/mysql')
# - DBCheckCommand          What command to use for doing a database integrity check   (example: 'docker exec -it db_docker mariadb-check -c --all-databases')
# - SQLUser                 What user to log in as                                     (example: 'root')
# - DATABASE_PASSWORD       Password for the database for the above user (obviously)
# - DB_ROOT                 Root directory for the database                            (example: /data/moodle_mariadb)
# - ServerName              Must not be a true DNS name!                               (example: 'my database server')
# - Recipient               Email address to recipient                                 (example: 'john.doe@example.org')
# - ReportHead              HTML-head to use for the report                            (example: 'https://fileadmin.cs.lth.se/intern/backup/custom_report_head.html')
# - jobe_th_bgc             Color for the table header background                      (example: '00838F')
# - jobe_th_c               Color for the table head text color                        (example: 'white')
# - box_h_bgc               Color for the box head background color                    (example: '3E6E93')
# - box_h_c                 Color for the box head text color                          (example: 'white')
# - SCP                     Should the result be copied to a remote server?            (example: 'true')
# - SCP_HOST                DNS-name for the intended server                           (example: 'server.org.se')
# - SCP_DIR                 Directory to put the file in                               (example: '/var/www/html/sql')
# - SCP_USER                User to copy as. Must be able to write in the dir!         (example: 'scp_user')

# Must set SCP ahead of reading the settings file in order to be correct
SCP=false

if [ -r ~/.sql_info.settings ]; then
    source ~/.sql_info.settings
else
    echo "Settings file not found. Will exit!"
    exit 1
fi

# Default to *not* do verify
Verify=false
echo "$1"
while getopts ":hv" opt; do
  case $opt in
    v ) Verify=true;;
    h ) HELP=true;;
    \?) echo "Invalid option: -$OPTARG" >&2;;
  esac
done


# Do a color fix (for convenience sake):
CSS_colorfix="s/jobe_th_bgc/$jobe_th_bgc/g;s/jobe_th_c/$jobe_th_c/g;s/box_h_bgc/$box_h_bgc/g;s/box_h_c/$box_h_c/g"
NL=$'\n'
SepatarorStr="&nbsp;&nbsp;&nbsp;&diams;&nbsp;&nbsp;&nbsp;"
export LC_ALL=en_US.UTF-8
LastRunFile=~/.sql-info_last_run
LinkReferer='target="_blank" rel="noopener noreferrer"'
Version="2024-02-12.3"


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#   _____   _____    ___   ______   _____       _____  ______     ______   _   _   _   _   _____   _____   _____   _____   _   _   _____ 
#  /  ___| |_   _|  / _ \  | ___ \ |_   _|     |  _  | |  ___|    |  ___| | | | | | \ | | /  __ \ |_   _| |_   _| |  _  | | \ | | /  ___|
#  \ `--.    | |   / /_\ \ | |_/ /   | |       | | | | | |_       | |_    | | | | |  \| | | /  \/   | |     | |   | | | | |  \| | \ `--. 
#   `--. \   | |   |  _  | |    /    | |       | | | | |  _|      |  _|   | | | | | . ` | | |       | |     | |   | | | | | . ` |  `--. \
#  /\__/ /   | |   | | | | | |\ \    | |       \ \_/ / | |        | |     | |_| | | |\  | | \__/\   | |    _| |_  \ \_/ / | |\  | /\__/ /
#  \____/    \_/   \_| |_/ \_| \_|   \_/        \___/  \_|        \_|      \___/  \_| \_/  \____/   \_/    \___/   \___/  \_| \_/ \____/ 


# Find where the script is located
script_location() {
    # Find where the script resides (correct version)
    # Get the DirName and ScriptName
    if [ -L "${BASH_SOURCE[0]}" ]; then
        # Get the *real* directory of the script
        ScriptDirName="$(dirname "$(readlink "${BASH_SOURCE[0]}")")"   # ScriptDirName='/usr/local/bin'
        # Get the *real* name of the script
        ScriptName="$(basename "$(readlink "${BASH_SOURCE[0]}")")"     # ScriptName='sql_report.sh'
    else
        ScriptDirName="$(dirname "${BASH_SOURCE[0]}")"
        # What is the name of the script?
        ScriptName="$(basename "${BASH_SOURCE[0]}")"
    fi
    ScriptFullName="${ScriptDirName}/${ScriptName}"
}


# Find how the script is launched. Replace newlines with ' & '
script_launcher() {
    # Start by looking at /etc/cron.d
    ScriptLauncher="$(grep "$ScriptName" /etc/cron.d/* 2>/dev/null | grep -Ev "#" | cut -d: -f1 | sed ':a;N;$!ba;s/\n/ \& /g')"                # Ex: ScriptLauncher=/etc/cron.d/postgres
    # Also, look at the crontabs:
    if [ -z "$ScriptLauncher" ]; then
        ScriptLauncher="$(grep "$ScriptName" /var/spool/cron/crontabs/* 2>/dev/null | grep -Ev "#" | cut -d: -f1 | sed ':a;N;$!ba;s/\n/ \& /g')"
    fi
    ScriptLaunchWhenStr="$(grep "$ScriptName" "$ScriptLauncher" 2>/dev/null | grep -Ev "#" | awk '{print $1" "$2" "$3" "$4" "$5}')"            # Ex: ScriptLaunchWhenStr='55 3 * * *'
    ScriptLaunchByUser="<code>$(grep "$ScriptName" "$ScriptLauncher" 2>/dev/null | grep -Ev "#" | awk '{print $6}')</code>"                    # Ex: ScriptLaunchByUser='<code>root</code>'
    ScriptLaunchDay="$(echo "$ScriptLaunchWhenStr" | awk '{print $5}' | sed 's/*/day/; s/0/Sunday/; s/1/Monday/; s/2/Tuesday/; s/3/Wednesday/; s/4/Thursday/; s/5/Friday/; s/6/Saturday/')"
    ScriptLaunchHour="$(echo "$ScriptLaunchWhenStr" | awk '{print $2}')"                                                           # Ex: ScriptLaunchHour=3
    ScriptLaunchMinute="$(echo "$ScriptLaunchWhenStr" | awk '{print $1}')"                                                         # Ex: ScriptLaunchMinute=55
    ScriptLaunchText="as $ScriptLaunchByUser every $ScriptLaunchDay at $(printf "%02d:%02d" "${ScriptLaunchHour#0}" "${ScriptLaunchMinute#0}")"  # Ex: ScriptLaunchText='by <code>root</code> every day at 03:55'
}


# Send a notification to the CS Monitoring System (if present)
notify() {
    Object=$1
    Message=$2
    Level=$3
    Details=$4
    if [ -z "$Details" ]; then
        Details="{}"
    fi
    if [ -x /opt/monitoring/bin/notify ]; then
        /opt/monitoring/bin/notify "$Object" "$Message" "${Level:-INFO}" "$Details"
    fi
}


# Convert a number of seconds to a human readable string in the form of '[n hour] [m min] p secs'
time_convert() {
    local Secs=$1
    local TimeRaw="$((Secs/86400)) days $((Secs/3600%24)) hours $((Secs%3600/60)) min $((Secs%60)) sec"
    echo "$(echo "$TimeRaw" | sed 's/^0 days//;s/ 0 hours//;s/ 0 min//;s/ 0 sec//;s/^ //')"
}
# Ex: time_convert 285366 -> 3 days 7 hour 16 min 6 sec



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#  ______   _           _      __                                 _            __         
#  | ___ \ | |         | |    / _|                               (_)          / _|        
#  | |_/ / | |   __ _  | |_  | |_    ___    _ __   _ __ ___       _   _ __   | |_    ___  
#  |  __/  | |  / _` | | __| |  _|  / _ \  | '__| | '_ ` _ \     | | | '_ \  |  _|  / _ \ 
#  | |     | | | (_| | | |_  | |   | (_) | | |    | | | | | |    | | | | | | | |   | (_) |
#  \_|     |_|  \__,_|  \__| |_|    \___/  |_|    |_| |_| |_|    |_| |_| |_| |_|    \___/ 

platform_info() {
    export OS="$(head -1q /etc/mageia-release /etc/centos-release /etc/redhat-release /etc/gentoo-release /etc/fedora-release 2>/dev/null | sort -u)"
    # If no such file, look for /etc/os-release
    if [ -z "$OS" ]; then
        [[ -f /etc/os-release ]] && export OS="$(grep PRETTY_NAME /etc/os-release | cut -d\" -f2)"
    fi
    # If no such file, look for /etc/lsb-release
    if [ -z "$OS" ]; then
        [[ -f /etc/lsb-release ]] && export OS="$(grep DISTRIB_DESCRIPTION /etc/lsb-release | cut -d\" -f2)"
    fi
    # If no such file, look for /proc/version
    if [ -z "$OS" ]; then
        [[ -f /proc/version ]] && export OS="$(less /proc/version | cut -d\( -f1)"
    fi
    # OK, so it an unknown system
    if [ -z "$OS" ]; then
        export OS="Unknown Linux-distro"
    fi

    # Are we in a Virtual environment? This one is a bit tricky since there are many ways to cover this.
    # Read this for more info: http://unix.stackexchange.com/questions/89714/easy-way-to-determine-virtualization-technology
    if type -p dmesg >/dev/null; then
        VMenv="$(sudo dmesg 2>/dev/null | grep -i " Hypervisor detected: " 2>/dev/null | cut -d: -f2 | sed 's/^ *//')"      # Ex: VMenv='VMware'
    else
        VMenv=""
    fi

    # Get a bit more information if VMenv has a value
    if [ -n "$VMenv" ]; then
        if [ -x /usr/sbin/dmidecode ]; then
            VMenv="$(sudo /usr/sbin/dmidecode -s system-product-name 2>/dev/null)"                                          # Ex: VMenv='VMware Virtual Platform'
        else
            VMenv=""
        fi
    fi

    # It may still be a VM environment
    if [ -z "$VMenv" ]; then
        VMenv="$(virt-what 2>/dev/null)"
        # Ex: VMenv='vmware'
    fi
    if [ -z "$VMenv" ]; then
        if [ -n "$(grep "^flags.*\ hypervisor\ " /proc/cpuinfo)" ]; then
            VMenv="VM environment detected"
        fi
        # Ex: VMenv='VM environment detected'
    fi

    # Get more platform data
    if [ -x /usr/sbin/dmidecode ]; then
        PlatformType="$(sudo /usr/sbin/dmidecode -t 2 2>/dev/null | grep -E "^\s*Type:" | cut -d: -f2 | cut -c2-)"          # Ex: PlatformType=Motherboard
    else
        PlatformType=""
    fi

    # Assemble the substring
    if [ -n "$VMenv" ]; then
        PlatformStr="virtualized <i>($VMenv)</i>"
    else
        PlatformStr="physical <i>($PlatformType)</i>"
    fi

    # Get RAM
    RAM="$(free -gh | grep -Ei "^mem:" | awk '{print $2}' | sed 's/Gi/ GiB/')"                                              # Ex: RAM='15 GiB'
    #RAM=$(grep -E -i "^MemTotal" /proc/meminfo | awk '{print $2}')                                                          # Ex: RAM=16349556
    RAMAvailable="$(echo "scale=1; ($(egrep "MemAvailable:" /proc/meminfo | awk '{print $2}')) / 1048576" | bc)"            # Ex: RAMAvailable=14.3

    # Get disk details:
    DFStr="$(df -k --output=source,fstype,size,used,avail,pcent "$DB_ROOT" | awk 'NR>1')"                                   # Ex: DFStr='/dev/mapper/vg1-data xfs  314517508 201063872 113453636  64%'
    DiskreePercent="$((100-$(echo "$DFStr" | awk '{print $6}' | cut -d% -f1)))%"                                            # Ex: DiskreePercent=36%
    DiskFS="$(echo "$DFStr" | awk '{print $1}')"                                                                            # Ex: DiskFS=/dev/mapper/vg1-data
    DiskFreeKiB="$(echo "$DFStr" | awk '{print $5}')"                                                                       # Ex: DiskFreeKiB=113453636
    DiskFreeGiB="$(numfmt --to=iec-i --suffix=B --format="%9.1f" $((DiskFreeKiB*1024)) 2>/dev/null | sed 's/^ *//;s/GiB/ GiB/')"      # Ex: DiskFreeGiB='108.2 GiB'
    if [ -z "$DiskFreeGiB" ]; then
        DiskFreeGiB="$(numfmt --to=iec-i --suffix=B --format="%9f" $((DiskFreeKiB*1024)) 2>/dev/null | sed 's/^ *//;s/GiB/ GiB/')"    # Ex: DiskFreeGiB='108 GiB'
    fi
    DiskFStype="$(echo "$DFStr" | awk '{print $2}')"                                                                        # Ex: DiskFStype=xfs
    DBDirVolume="$(du -skh "$DB_ROOT" | awk '{print $1}' | sed 's/G/ GiB/;s/M/ MiB/;s/K/ KiB/')"                            # Ex: DBDirVolume='58 GB'
    DiskInfoString="        <tr><td>Disk info:</td><td>Database directory <code>$DB_ROOT</code> occupies $DBDirVolume.<br><i>$DiskreePercent ($DiskFreeGiB) is free on <code>$DiskFS</code> and uses <code>$DiskFStype</code> file system.</i></td></tr>"

    # CPU:
    NbrCPUs=$(grep -Ec "^processor" /proc/cpuinfo)                                                                          # Ex: NbrCPUs=4

    # Assemble environment string:
    EnvironmentStr="        <tr><td>Operating system:</td><td>$OS$SepatarorStr$PlatformStr$SepatarorStr$NbrCPUs logical processors$SepatarorStr$RAM of RAM</td></tr>"
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#   _____          _            _                                                 _            __         
#  /  __ \        | |          | |                                               (_)          / _|        
#  | |  \/   ___  | |_       __| |   __ _    ___   _ __ ___     ___    _ __       _   _ __   | |_    ___  
#  | | __   / _ \ | __|     / _` |  / _` |  / _ \ | '_ ` _ \   / _ \  | '_ \     | | | '_ \  |  _|  / _ \ 
#  | |_\ \ |  __/ | |_     | (_| | | (_| | |  __/ | | | | | | | (_) | | | | |    | | | | | | | |   | (_) |
#   \____/  \___|  \__|     \__,_|  \__,_|  \___| |_| |_| |_|  \___/  |_| |_|    |_| |_| |_| |_|    \___/ 

get_daemon_info() {
    #RunningDaemonLine="$(ps -ef n | grep -Ei "\b[m]ysqld\b|\b[m]ariadbd\b")"                                      # Ex: RunningDaemonLine='     999    2635    2594 33 04:46 ?        Ssl  126:15 mariadbd'
    #                                                                                                                                           UID     PID    PPID  C STIME TTY      STAT   TIME CMD
    RunningDaemonLine="$(ps -eo uid,pid,ppid,cmd | grep -Ei "\b[m]ysqld\b|\b[m]ariadbd\b" | awk '{print $1" "$2" "$3" "$4}')"   # Ex:  RunningDaemonLine='27 1601 1276 /usr/libexec/mysqld'
    # Only do the following if we find a running database daemon
    if [ -n "$RunningDaemonLine" ]; then
        RunningDaemonPID="$(echo "$RunningDaemonLine" | awk '{print $2}')"                                             # Ex: RunningDaemonPID=58310
        RunningDaemonMemRSS="$(ps --no-headers -o rss:8 $RunningDaemonPID | awk '{print $1/1024}' | cut -d\. -f1)"     # Ex: RunningDaemonMemRSS=398
        RunningDaemonMemVSZ="$(ps --no-headers -o vsz:8 $RunningDaemonPID | awk '{print $1/1024}' | cut -d\. -f1)"     # Ex: RunningDaemonMemVSZ=1920
        RunningDaemonPPID="$(echo "$RunningDaemonLine" | awk '{print $3}')"                                            # Ex: RunningDaemonPPID=58288
        RunningDaemonPPIDCommand="$(ps -p $RunningDaemonPPID -o cmd= 2>/dev/null | awk '{print $1}')"                  # Ex: RunningDaemonPPIDCommand=/usr/bin/containerd-shim-runc-v2
        if [ -n "$(echo "$RunningDaemonPPIDCommand" | grep -Eo "containerd")" ]; then
            Dockers="$(docker ps | grep -Ev "^CONTAINER" | awk '{print $NF}')"
            # Ex: Dockers='moodledb
            #              moodleweb'
            while read DOCKER
            do
                if [ -n "$(docker top $DOCKER | grep -E "\b$RunningDaemonPID\b")" ]; then
                    RunningDocker="$DOCKER"                                                                            # Ex: RunningDocker=moodledb
                    RunningDockerStr="&nbsp;<i>(running inside docker <code>$RunningDocker</code>)</i>"
                    break
                fi
            done <<< "$Dockers"
            # Deal with docker internal only network:
            if [ -n "$RunningDocker" ]; then
                RunningContainerID=$(docker ps | grep $RunningDocker | awk '{print $1}')                               # Ex: RunningContainerID=0f552df2da7f
                RunningContainerPID=$(docker inspect --format '{{.State.Pid}}' $RunningContainerID)                    # Ex: RunningContainerPID=2567
                RunningContainerInternalNetwork="$(nsenter -t $RunningContainerPID -n ss -ltn | grep "$Port")"
                # Ex: RunningContainerInternalNetwork='LISTEN  0        80               0.0.0.0:3306           0.0.0.0:*
                #                                      LISTEN  0        80                  [::]:3306              [::]:*              '
            fi
        fi
        RunningDaemonUID="$(echo "$RunningDaemonLine" | awk '{print $1}')"                                             # Ex: RunningDaemonUID=999
        RunningDaemonUser="$(/bin/getent passwd "$RunningDaemonUID" | cut -d: -f1)"                                    # Ex: RunningDaemonUser=systemd-coredump
        RunningDaemonName="$(/bin/getent passwd "$RunningDaemonUID" | cut -d: -f5)"                                    # Ex: RunningDaemonName='systemd Core Dumper'
        RunningDaemon="$(echo "$RunningDaemonLine" | awk '{print $NF}')"                                               # Ex: RunningDaemon=mariadbd
        RunningDaemonSecs="$(ps -p $RunningDaemonPID -o etimes= 2>/dev/null)"                                          # Ex: RunningDaemonSecs=' 112408'
        RunningDaemonTimeH="$(time_convert $RunningDaemonSecs | sed 's/ [0-9]* sec$//')"                               # Ex: RunningDaemonTimeH='1 days 9 hours 19 min'
        #RunningDaemonStartTime="$(ps -p $RunningDaemonPID -o lstart=)"                                                # Ex: RunningDaemonStartTime='Mon Jan 29 07:43:45 2024'
        RunningDaemonStartTime="$(date +%F" "%T -d @"$(($(date +%s) - $(ps -p $RunningDaemonPID -o etimes=)))")"       # Ex: RunningDaemonStartTime='2024-01-29 07:43:45'
    fi
    UptimeSince="$(uptime -s)"                                                                                         # Ex: UptimeSince='2024-01-29 04:06:33'

    # Get the port info:
    Port=$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SHOW VARIABLES LIKE 'port';" | awk '{print $2}')        # Ex: Port=3306
    # Get open ports:
    # lsof -i:3306 +c15
    # COMMAND       PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    # docker-proxy 1629 root    4u  IPv4  38869      0t0  TCP *:mysql (LISTEN)
    # docker-proxy 1639 root    4u  IPv6  38877      0t0  TCP *:mysql (LISTEN)
    # ^^^1^^^       ^2^ ^^3^        ^^5^                 ^^8^ ^^9^
    if [ -x /bin/lsof ]; then
        OpenSQLPorts="$(/bin/lsof -i:$Port +c15 | sed '1d' | awk '{print $1" "$2" "$3" "$5" "$8" "$9" "$10}')"
    elif [ -x /sbin/lsof ]; then
        OpenSQLPorts="$(/sbin/lsof -i:$Port +c15 | sed '1d' | awk '{print $1" "$2" "$3" "$5" "$8" "$9" "$10}')"
    fi
    # Ex: OpenSQLPorts='docker-proxy 1629 root IPv4 TCP *:mysql (LISTEN)
    #                   docker-proxy 1639 root IPv6 TCP *:mysql (LISTEN)'

    # Create the table part:
    if [ -n "$OpenSQLPorts" ]; then
        OpenConnectionTblPart="        <tr><td>Network port:</td><td><code>$Port</code>:
            <table>
                <tr><td><b>Command</b></td><td><b>PID</b></td><td><b>User</b></td><td><b>Type</b></td><td><b>Node</b></td><td><b>Name</b></td></tr>"
        while read -r Command PID User Type Node Name
        do
            OpenConnectionTblPart+="            <tr><td>$Command</td><td>$PID</td><td>$User</td><td>$Type</td><td>$Node</td><td>$Name</td></tr>$NL"
        done <<< "$OpenSQLPorts"
        # Ex: OpenConnectionTblPart='<tr><td>docker-proxy</td><td>1629</td><td>root</td><td>IPv4</td><td>TCP</td><td>*:mysql (LISTEN)</td></tr>
        #                            <tr><td>docker-proxy</td><td>1639</td><td>root</td><td>IPv6</td><td>TCP</td><td>*:mysql (LISTEN)</td></tr>'
        OpenConnectionTblPart+="        </table></td></tr>"
    elif [ -n "$RunningContainerInternalNetwork" ]; then
        OpenConnectionTblPart="        <tr><td>Network port:</td><td><code>$Port</code>: <i>network is docker internal only!</i></td></tr>"
    else
        OpenConnectionTblPart="        <tr><td>Network port:</td><td><i>No information about network port found!</i></td></tr>"
    fi


    # Assemble the DaemonInfoStr
    DaemonInfoStr="        <tr><th align=\"right\" colspan=\"2\">Daemon info</th></tr>$NL"
    DaemonInfoStr+="$EnvironmentStr"
    if [ -n "$RunningDaemonLine" ]; then
        DaemonInfoStr+="        <tr><td>Daemon:</td><td><code>$RunningDaemon</code>$RunningDockerStr</td></tr>$NL"
        DaemonInfoStr+="        <tr><td>PID:</td><td><code>$(echo "$RunningDaemonPID" | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/<\/code><br><code>/g')</code></td></tr>$NL"
        DaemonInfoStr+="        <tr><td>Memory, PID &amp; OS:</td><td>Real (RSS): $(printf "%'d" "$RunningDaemonMemRSS") MB${SepatarorStr}Virtual (VSZ): $(printf "%'d" "$RunningDaemonMemVSZ") MB${SepatarorStr}RAM available: $RAMAvailable GB</td></tr>$NL"
        DaemonInfoStr+="        <tr><td>User:</td><td><pre>$RunningDaemonUID ($RunningDaemonUser; &#8220;$RunningDaemonName&#8221;)</pre></td></tr>$NL"
        DaemonInfoStr+="        <tr><td>Parent command:</td><td><pre>$RunningDaemonPPIDCommand (PID: $RunningDaemonPPID)</pre></td></tr>$NL"
        DaemonInfoStr+="        <tr><td>Daemon started:</td><td>$RunningDaemonStartTime<em> ($RunningDaemonTimeH ago)</em></td></tr>$NL"
        DaemonInfoStr+="        <tr><td>Computer boot time:</td><td>$UptimeSince</td></tr>$NL"
        DaemonInfoStr+="$OpenConnectionTblPart$NL"
        DaemonInfoStr+="$DiskInfoString"
    else
        DaemonInfoStr+="        <tr><td>Daemon:</td><td>No <code>mysqld</code> or <code>mariadbd</code> detected.</td></tr>$NL"
        SystemctlStatus="$(systemctl status mysql 2>/dev/null)"
        if [ -z "$SystemctlStatus" ]; then
            SystemctlStatus="$(systemctl status mariadb 2>/dev/null)"
        fi
        if [ -n "$SystemctlStatus" ]; then
            DaemonInfoStr+="        <tr><td><code>systemctl&nbsp;</code>:</td><td><pre>$SystemctlStatus</pre></td></tr>"
        fi
    fi
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
#                              _               _   _                       _                     _    
#                             (_)             | | | |                     | |                   | |   
#   _ __ ___     __ _   _ __   _    __ _    __| | | |__    ______    ___  | |__     ___    ___  | | __
#  | '_ ` _ \   / _` | | '__| | |  / _` |  / _` | | '_ \  |______|  / __| | '_ \   / _ \  / __| | |/ /
#  | | | | | | | (_| | | |    | | | (_| | | (_| | | |_) |          | (__  | | | | |  __/ | (__  |   < 
#  |_| |_| |_|  \__,_| |_|    |_|  \__,_|  \__,_| |_.__/            \___| |_| |_|  \___|  \___| |_|\_\
#  

do_mariadb_check() {
    if $Verify; then
        DBCheckStartTime=$(date +%s)
        MariaCheckOutput="$(${DBCheckCommand/-it/} -u$SQLUser -p"$DATABASE_PASSWORD")"
        # Ex: MariaCheckOutput='hbg01.Courses                                      OK
        #                       hbg01.Students                                     OK
        #                       mysql.db                                           OK
        #                       mysql.event                                        OK
        #                       moodle.mdl_user_devices                            OK
        #                       moodle.mdl_user_enrolments
        #                       Warning  : InnoDB: Index 'mdl_userenro_mod_ix' contains 33251 entries, should be 33920.
        #                       error    : Corrupt
        #                       moodle.mdl_user_info_category                      OK
        #                       mysql.innodb_table_stats                           OK
        #                       mysql.plugin                                       OK'
        # ALL rows should end in 'OK'!
        ES_mariadb_check=$?
        DBCheckTime="$(time_convert $(($(date +%s) - DBCheckStartTime)))"                              # Ex: DBCheckTime='24 sec'
        MariaCheckErrors="$(echo "$MariaCheckOutput" | grep -Ev "\bOK")"
        # Ex: MariaCheckErrors='moodle.mdl_user_enrolments
        #                       Warning  : InnoDB: Index '\''mdl_userenro_mod_ix'\'' contains 33251 entries, should be 33920.
        #                       error    : Corrupt'

        # Assemble the string
        DBCheckString="        <tr><th align=\"right\" colspan=\"2\">Database verification</th></tr>$NL"
        DBCheckString+="        <tr><td>Method:</td><td><code>$DBCheckCommand</code></td></tr>$NL"
        if [ -z "$MariaCheckErrors" ]; then
            DBCheckString+="        <tr><td>Status:</td><td style=\"color: green;\">All OK</td></tr>$NL"
        else
            DBCheckString+="        <tr><td>Status:</td><td style=\"color: red;\">Corruption detected</td></tr>$NL"
            DBCheckString+="        <tr><td colspan=\"2\">Details:<br><pre style=\"color: red;\">$MariaCheckErrors</pre></td></tr>$NL"
        fi
        DBCheckString+="        <tr><td>Time taken:</td><td>${DBCheckTime:-0 sec}</td></tr>$NL"
    else
        DBCheckString=""
    fi
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#  _____            _             _                                                                     _                   
#  |  _ \          | |           | |                                                                   (_)                  
#  | | | |   __ _  | |_    __ _  | |__     __ _   ___    ___       ___   __   __   ___   _ __  __   __  _    ___  __      __
#  | | | |  / _` | | __|  / _` | | '_ \   / _` | / __|  / _ \     / _ \  \ \ / /  / _ \ | '__| \ \ / / | |  / _ \ \ \ /\ / /
#  | |/ /  | (_| | | |_  | (_| | | |_) | | (_| | \__ \ |  __/    | (_) |  \ V /  |  __/ | |     \ V /  | | |  __/  \ V  V / 
#  |___/    \__,_|  \__|  \__,_| |_.__/   \__,_| |___/  \___|     \___/    \_/    \___| |_|      \_/   |_|  \___|   \_/\_/  

get_database_overview() {
    DatabasesToHide="information_schema|performance_schema|mysql"
    InconsistentSizeWarningString=""
    #DatabaseOverviewSQL="SELECT TABLE_SCHEMA,COUNT(TABLE_NAME),FORMAT(SUM(TABLE_ROWS),0),FORMAT(SUM(DATA_LENGTH),0),FORMAT(SUM(INDEX_LENGTH),0),DATA_FREE,TABLE_COLLATION,CREATE_TIME,UPDATE_TIME,ENGINE FROM information_schema.tables GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA ASC;"
    DatabaseOverviewSQL="SELECT TABLE_SCHEMA,COUNT(TABLE_NAME) AS Num_tables, FORMAT(SUM(TABLE_ROWS),0) AS sum_rows, FORMAT(SUM(DATA_LENGTH),0) AS sum_data, FORMAT(SUM(INDEX_LENGTH),0) AS sum_index, DATA_FREE,TABLE_COLLATION,CREATE_TIME,UPDATE_TIME,ENGINE FROM information_schema.tables GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA ASC;"
    DatabaseOverview="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "$DatabaseOverviewSQL" | tr -d '\r')"
    # Ex: DatabaseOverview='information_schema     79          NULL         106,496         106,496        0    utf8mb3_general_ci  2024-02-06 19:38:39  2024-02-06 19:38:39  Aria
    #                       moodle                510   100,056,805  36,599,554,048  11,567,128,576        0    utf8mb4_unicode_ci  2024-01-18 13:15:42  NULL                 InnoDB
    #                       mysql                  31       145,369       9,912,320       2,727,936        0    utf8mb3_general_ci  2024-01-18 14:31:27  2024-01-18 14:31:27  Aria
    #                       performance_schema     81           535               0               0        0    utf8mb3_general_ci  NULL                 NULL                 PERFORMANCE_SCHEMA
    #                       sys                   101             6          16,384          16,384      NULL   NULL                NULL                 NULL                 NULL'
    #                       Database           #table          ∑row    ∑data_length   ∑index_length  DataFree   Collation           Created              Updated              Storage Engine
    #                         1                     2             3               4               5         6   7                   8                    9                      10

    NumDB=$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SHOW DATABASES;" | wc -l)        # Ex: NumDB=5

    # Create the table part:
    DatabaseTblString="        <tr><th align=\"right\" colspan=\"2\">Databases &amp; tables</th></tr>$NL
        <tr><td colspan=\"2\">The following $NumDB databases exists:</td></tr>$NL
        <tr><td colspan=\"2\">
        <table>
            <tr><td><b>Database</b>&nbsp;&#8595;</td><td align=\"right\"><b>Num. tables</b></td><td align=\"right\"><b>&sum; rows</b></td><td align=\"right\"><b>&sum; table data [B]</b></td><td align=\"right\"><b>&sum; index data [B]</b></td><td><b>Data on disk</b></td><td><b>Table collation</b></td><td><b>Created</b></td><td><b>Storage engine</b></td></tr>$NL"
    while read DB NumTables SumRows SumDataLength SumIndexLength DataFree Collation CreateTime UpdateTime Engine
    do
        DatabaseDiskVolume="$(du -skh $DB_ROOT/$DB 2>/dev/null | awk '{print $1}' | sed 's/K/ KiB/;s/M/ MiB/;s/G/ GiB/')"                            # Ex: DatabaseDiskVolume='48 GiB'
        DataLength="$(numfmt --to=iec-i --suffix=B --format="%9.1f" ${SumDataLength//,/} 2>/dev/null | sed 's/K/ K/;s/M/ M/;s/G/ G/;s/^ *//')"             # Ex: DataLength='34.1 GiB'
        # Determine if the unit differ and if so, set flag to display infromation about this
        if [ ! "$(echo "$DatabaseDiskVolume" | awk '{print $NF}')" = "$(echo "$DataLength" | awk '{print $NF}')" ]; then
            InconsistentSizeWarningString="<br><i><code><b>*</b></code> the size of &#8220;&sum; table data [B]&#8221; (according to 'information_schema') and &#8220;Data on disk&#8221; differs! That is due to how the tables were created.</i><br>"
            DatabaseTblString+="            <tr><td><code>$DB</code></td><td align=\"right\">$NumTables</td><td align=\"right\">$SumRows</td><td align=\"right\">$SumDataLength</td><td align=\"right\">$SumIndexLength</td><td align=\"right\">${DatabaseDiskVolume:-0 KiB}</td><td>$Collation</td><td>${CreateTime/_/ }</td><td>$Engine</td><td><code> *</code></td></tr>$NL"
        else
            DatabaseTblString+="            <tr><td><code>$DB</code></td><td align=\"right\">$NumTables</td><td align=\"right\">$SumRows</td><td align=\"right\">$SumDataLength</td><td align=\"right\">$SumIndexLength</td><td align=\"right\">${DatabaseDiskVolume:-0 KiB}</td><td>$Collation</td><td>${CreateTime/_/ }</td><td>$Engine</td></tr>$NL"
        fi
        #DatabaseTblString+="            <tr><td><code>$DB</code></td><td align=\"right\">$NumTables</td><td align=\"right\">$SumRows</td><td align=\"right\">$SumDataLength</td><td align=\"right\">$SumIndexLength</td><td align=\"right\">${DatabaseDiskVolume:-0 KiB}</td><td>$Collation</td><td>${CreateTime/_/ }</td><td>$Engine</td></tr>$NL"
    done <<< "$(echo "$DatabaseOverview" | sed 's/ /_/g')"
    DatabaseTblString+="        </table>$InconsistentSizeWarningString<br></td></tr>$NL"

    # Get data for the 5 largest tables
    FiveLargestTablesSQL="SELECT TABLE_SCHEMA,TABLE_NAME,FORMAT(TABLE_ROWS,0) AS Num_rows,FORMAT((DATA_LENGTH+INDEX_LENGTH),0) AS sum_size,ENGINE,CREATE_TIME,UPDATE_TIME,TABLE_COLLATION,ROUND((DATA_FREE/DATA_LENGTH)*100.0,1) AS Fragm FROM information_schema.TABLES ORDER BY TABLE_ROWS DESC LIMIT 5;"
    # Ex: FiveLargestTables='moodle  mdl_question_attempt_step_data  54,278,475  26,836,205,568  InnoDB  2024-01-18 13:50:02  2024-02-06 19:50:35    utf8mb4_unicode_ci  0.0
    #                        moodle  mdl_logstore_standard_log       23,341,868  11,951,456,256  InnoDB  2024-01-18 13:20:30  2024-02-06 19:50:37    utf8mb4_unicode_ci  0.1
    #                        moodle  mdl_question_attempt_steps      11,207,358   2,299,527,168  InnoDB  2024-01-18 14:20:36  2024-02-06 19:50:35    utf8mb4_unicode_ci  0.6
    #                        moodle  mdl_grade_grades_history         3,002,327   1,545,175,040  InnoDB  2024-01-18 13:16:57  2024-02-06 19:49:13    utf8mb4_unicode_ci  0.8
    #                        moodle  mdl_question_attempts            1,653,458   3,970,580,480  InnoDB  2024-01-18 14:25:51  2024-02-06 19:50:35    utf8mb4_unicode_ci  0.2'
    #                        Schema  table_name                    ∑_table_rows          ∑_size  Engine  Created              Updated                Collation           Fragmentation

    FiveLargestTables="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NB -e "$FiveLargestTablesSQL")"
    # Create the table part:
    DatabaseTblString+="        <tr><td colspan=\"2\">The five largest tables:
        <table>
            <tr><td><b>Database</b></td><td><b>Table Name</b></td><td><b>Nbr. of rows</b>&nbsp;&#8595;</td><td align=\"right\"><b>&sum; size [B]</b></td><td><b>Disk use</b></td><td><b>Fragm.</b></td><td><b>Collation</b></td><td><b>Created</b></td><td><b>Updated</b></td><td><b>Storage engine</b></td></tr>$NL"
    while read TableSchema TableName SumRows SumSize StorageEngine Created Updated Collation Fragmentation
    do
        TableDiskVolumeB="$(ls -ls $DB_ROOT/$TableSchema/${TableName}* | awk '{sum+=$6} END {print sum}')"               # Ex: TableDiskVolumeB=27816625772
        TableDiskVolume="$(numfmt --to=iec-i --suffix=B --format="%9.1f" $TableDiskVolumeB 2>/dev/null | sed 's/K/ K/;s/M/ M/;s/G/ G/;s/^ *//')"     # Ex: TableDiskVolume='26.0 GiB'
        if [ -z "$TableDiskVolume" ]; then
            TableDiskVolume="$(numfmt --to=iec-i --suffix=B --format="%9f" $TableDiskVolumeB 2>/dev/null | sed 's/K/ K/;s/M/ M/;s/G/ G/;s/^ *//')"   # Ex: TableDiskVolume='26 GiB'
        fi
        DatabaseTblString+="            <tr><td><code>$TableSchema</code></td><td><code>$TableName</code></td><td align=\"right\">$SumRows</td><td align=\"right\">$SumSize</td><td align=\"right\">$TableDiskVolume</td><td align=\"right\">$(printf "%'.1f" ${Fragmentation/NULL/0})%</td><td>$Collation</td><td>${Created/_/ }</td><td>${Updated/_/ }</td><td>$StorageEngine</td></tr>$NL"
    done <<< "$(echo "$FiveLargestTables" | sed 's/ /_/g')"
    DatabaseTblString+="        </table><br><i>Table size = DATA_LENGTH + INDEX_LENGTH,&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Fragmentation = DATA_FREE / DATA_LENGTH</i><br>
        <i>NOTE: the information above comes from <code>information_schema</code> and is not entirely accurate!</i></td></tr>"

    # MASTER / SLAVE
    MasterStatus="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SHOW MASTER STATUS;")"   # Ex: MasterStatus=  || MasterStatus='mariadb-bin.000599 542526335'
    if [ -z "$MasterStatus" ]; then
        MasterStatus="<i>None detected</i>"
    fi
    ReplicaStatus="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SHOW SLAVE STATUS;")"   # Ex: ReplicaStatus=
    if [ "$ReplicaStatus" ]; then
        ReplicaStatus="<i>None detected</i>"
    fi
    MainReplicaString="        <tr><th align=\"right\" colspan=\"2\">Main / replica</th></tr>
        <tr><td>Main status</td><td>$MasterStatus</td></tr>
        <tr><td>Replica status</td><td>$ReplicaStatus</td></tr>"

}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #   
#   _____   _____   _          _   _                           
#  /  ___| |  _  | | |        | | | |                          
#  \ `--.  | | | | | |        | | | |  ___    ___   _ __   ___ 
#   `--. \ | | | | | |        | | | | / __|  / _ \ | '__| / __|
#  /\__/ / \ \/' / | |____    | |_| | \__ \ |  __/ | |    \__ \
#  \____/   \_/\_\ \_____/     \___/  |___/  \___| |_|    |___/

get_sql_users() {
    # Users:
    # SQL:
    # MariaDB [(none)]> SELECT user,host from mysql.user;
    # +------------------+-----------+
    # | User             | Host      |
    # +------------------+-----------+
    # | replication_user | %         |
    # | root             | %         |
    # | mariadb.sys      | localhost |
    # | root             | localhost |
    # +------------------+-----------+
    
    UserList="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SELECT user,host FROM mysql.user" | tr -d '\r')"
    # Ex: UserList='replication_user    %
    #               root    %
    #               mariadb.sys localhost
    #               root    localhost'
    ##UserQString="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "select distinct concat('SHOW GRANTS FOR ', QUOTE(user), '@', QUOTE(host), ';') as query from mysql.user;" | grep -Ev "^query$")"
    # Ex: UserQString='SHOW GRANTS FOR '\''replication_user'\''@'\''%'\'';
    #                  SHOW GRANTS FOR '\''root'\''@'\''%'\'';
    #                  SHOW GRANTS FOR '\''mariadb.sys'\''@'\''localhost'\'';
    #                  SHOW GRANTS FOR '\''root'\''@'\''localhost'\'';'
    # READ MORE: https://dev.mysql.com/doc/refman/8.0/en/show-grants.html
    
    # Get the number of users
    NumUsersinDB=$(echo "$UserList" | wc -l)                                                       # Ex: NumUsersinDB=49

    # Produce a list of users and their rights:
    while read -r USER HOST
    do
        Host=$(echo "$HOST" | tr -d '\n')
        GRANTS="$(${SQLCommand/-it/} -u$SQLUser -p"$DATABASE_PASSWORD" -NBe  'SHOW GRANTS FOR '\'''$USER''\''@'\'''$Host''\'';' | sed "s/PASSWORD '[^']*'/PASSWORD 'XXX'/" | fold -w100 -s)"
        UserTblString+="            <tr><td><pre>$USER</pre></td><td><pre>$Host</pre></td><td><pre>$GRANTS</pre></td></tr>$NL"
    done <<< "$UserList"

    # Create the table part:
    SQLUsersTablePart="        <tr><th align=\"right\" colspan=\"2\">SQL Users</th></tr>
        <tr><td colspan=\"2\">$NumUsersinDB users exist. They have the following details:<br>
        <table>
            <tr><td><b>User</b></td><td><b>Host</b></td><td><b>Grants</b></td></tr>
$UserTblString
        </table></td></tr>$NL"
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #   
#   _____   _                                              _____                   _                      
#  /  ___| | |                                            |  ___|                 (_)                     
#  \ `--.  | |_    ___    _ __    __ _    __ _    ___     | |__    _ __     __ _   _   _ __     ___   ___ 
#   `--. \ | __|  / _ \  | '__|  / _` |  / _` |  / _ \    |  __|  | '_ \   / _` | | | | '_ \   / _ \ / __|
#  /\__/ / | |_  | (_) | | |    | (_| | | (_| | |  __/    | |___  | | | | | (_| | | | | | | | |  __/ \__ \
#  \____/   \__|  \___/  |_|     \__,_|  \__, |  \___|    \____/  |_| |_|  \__, | |_| |_| |_|  \___| |___/
#                                         __/ |                             __/ |                         
#                                        |___/                             |___/                          

get_storage_engines() {
    # Storage Engines
    StorageEngines="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SELECT Engine, Support FROM INFORMATION_SCHEMA.ENGINES ORDER BY engine;")"
    #  Ex: StorageEngines='Aria YES
    #                      CSV YES
    #                      InnoDB  DEFAULT
    #                      MEMORY  YES
    #                      MRG_MyISAM  YES
    #                      MyISAM  YES
    #                      PERFORMANCE_SCHEMA  YES
    #                      SEQUENCE    YES'
    # Readable:
    # SHOW ENGINES;
    # +--------------------+---------+-------------------------------------------------------------------------------------------------+--------------+------+------------+
    # | Engine             | Support | Comment                                                                                         | Transactions | XA   | Savepoints |
    # +--------------------+---------+-------------------------------------------------------------------------------------------------+--------------+------+------------+
    # | CSV                | YES     | Stores tables as CSV files                                                                      | NO           | NO   | NO         |
    # | MRG_MyISAM         | YES     | Collection of identical MyISAM tables                                                           | NO           | NO   | NO         |
    # | MEMORY             | YES     | Hash based, stored in memory, useful for temporary tables                                       | NO           | NO   | NO         |
    # | Aria               | YES     | Crash-safe tables with MyISAM heritage. Used for internal temporary tables and privilege tables | NO           | NO   | NO         |
    # | MyISAM             | YES     | Non-transactional engine with good performance and small data footprint                         | NO           | NO   | NO         |
    # | SEQUENCE           | YES     | Generated tables filled with sequential values                                                  | YES          | NO   | YES        |
    # | InnoDB             | DEFAULT | Supports transactions, row-level locking, foreign keys and encryption for tables                | YES          | YES  | YES        |
    # | PERFORMANCE_SCHEMA | YES     | Performance Schema                                                                              | NO           | NO   | NO         |
    # +--------------------+---------+-------------------------------------------------------------------------------------------------+--------------+------+------------+
    

    # Storage Engine Use:
    StorageEngineCommand="SELECT engine, count(*) AS tables, concat(round (sum(table_rows)/(1000000), 2), 'M') AS num_rows, concat(round(sum(data_length)/(1024*1024*1024),2), 'GB') AS data, concat(round (sum(index_length)/(1024*1024*1024),2), 'GB') AS idx, concat(round (sum(data_length+index_length)/ (1024*1024*1024), 2), 'GB') AS total_size FROM information_schema.TABLES GROUP BY engine ORDER BY engine ASC"
    # +--------------------+--------+----------+---------+---------+------------+
    # | engine             | tables | num_rows | data    | idx     | total_size |
    # +--------------------+--------+----------+---------+---------+------------+
    # | NULL               |    101 | NULL     | NULL    | NULL    | NULL       |
    # | Aria               |     38 | 0.14M    | 0.01GB  | 0.00GB  | 0.01GB     |
    # | CSV                |      2 | 0.00M    | 0.00GB  | 0.00GB  | 0.00GB     |
    # | InnoDB             |    514 | 99.85M   | 34.07GB | 10.77GB | 44.84GB    |
    # | MEMORY             |     66 | NULL     | 0.00GB  | 0.00GB  | 0.00GB     |
    # | PERFORMANCE_SCHEMA |     81 | 0.00M    | 0.00GB  | 0.00GB  | 0.00GB     |
    # +--------------------+--------+----------+---------+---------+------------+
    # 6 rows in set (0.043 sec)

    StorageEngineUse="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "$StorageEngineCommand;")"
    # Ex: StorageEngineUse='NULL                  101      NULL    NULL    NULL        NULL
    #                       Aria                   38     0.14M   0.01GB  0.00GB      0.01GB
    #                       CSV                     2     0.00M   0.00GB  0.00GB      0.00GB
    #                       InnoDB                514    99.85M  34.07GB 10.77GB     44.84GB
    #                       MEMORY                 66      NULL   0.00GB  0.00GB      0.00GB
    #                       PERFORMANCE_SCHEMA     81     0.00M   0.00GB  0.00GB      0.00GB'
    #                       ENGINE             TABLES  NUM_ROWS     DATA     IDX  TOTAL_SIZE
    #                       1                      2       3          4       5       6

    StorageEngineStr="        <tr><th align=\"right\" colspan=\"2\">Storage engines</th></tr>
        <tr><td colspan=\"2\">
            <table>
                <tr><td><b>engine</b></td><td><b>Support</b></td><td align=\"right\"><b>tables</b></td><td align=\"right\"><b>num_rows</b></td><td align=\"right\"><b>data</b></td><td align=\"right\"><b>idx</b></td><td align=\"right\"><b>total_size</b></td></tr>$NL"
    # Go through the supported engines and construct the table we need
    while read ENGINE SUPPORT
    do
        if [ "$SUPPORT" = "DEFAULT" ]; then
            COLOR=' style="color: green;"'
        else
            COLOR=""
        fi
        NumTables="$(echo "$StorageEngineUse" | grep "$ENGINE" | awk '{print $2}')"
        NumRows="$(echo "$StorageEngineUse" | grep "$ENGINE" | awk '{print $3}' | sed 's/M/ M/')"
        DATA="$(echo "$StorageEngineUse" | grep "$ENGINE" | awk '{print $4}' | sed 's/GB/ GB/')"
        IDX="$(echo "$StorageEngineUse" | grep "$ENGINE" | awk '{print $5}' | sed 's/GB/ GB/')"
        TOTAL_SIZE="$(echo "$StorageEngineUse" | grep "$ENGINE" | awk '{print $6}' | sed 's/GB/ GB/')"
        StorageEngineStr+="                <tr><td$COLOR>$ENGINE</td><td$COLOR>$SUPPORT</td><td align=\"right\"$COLOR>$NumTables</td><td align=\"right\"$COLOR>$NumRows</td><td align=\"right\"$COLOR>$DATA</td><td align=\"right\"$COLOR>$IDX</td><td align=\"right\"$COLOR>$TOTAL_SIZE</td></tr>$NL"
    done <<< "$StorageEngines"
    StorageEngineStr+="            </table><br>
        <p><i>Read an overview of <a href=\"https://dev.mysql.com/doc/refman/8.0/en/pluggable-storage-overview.html\" $LinkReferer>storage engines</a> <span class="glyphicon">&#xe164;</span></i></p></td></tr>"
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #   
#   _____   _____   _          _    _                  _           _       _              
#  /  ___| |  _  | | |        | |  | |                (_)         | |     | |             
#  \ `--.  | | | | | |        | |  | |   __ _   _ __   _    __ _  | |__   | |   ___   ___ 
#   `--. \ | | | | | |        | |  | |  / _` | | '__| | |  / _` | | '_ \  | |  / _ \ / __|
#  /\__/ / \ \/' / | |____     \ \/ /  | (_| | | |    | | | (_| | | |_) | | | |  __/ \__ \
#  \____/   \_/\_\ \_____/      \__/    \__,_| |_|    |_|  \__,_| |_.__/  |_|  \___| |___/

get_sql_variables() {
    InterestingVariables="binlog_expire_logs_seconds;The binary log expiration period in seconds;https://mariadb.com/kb/en/replication-and-binary-log-system-variables/#binlog_expire_logs_seconds
binlog_file_cache_size;Size of in-memory cache that is allocated when reading binary log and relay log files;https://mariadb.com/kb/en/replication-and-binary-log-system-variables/#binlog_file_cache_size
collation_connection;Collation used for the connection character set;https://mariadb.com/kb/en/server-system-variables/#collation_connection
collation_database;The collation used by the default database;https://mariadb.com/kb/en/server-system-variables/#collation_database
collation_server;The server's default collation;https://mariadb.com/kb/en/server-system-variables/#collation_server
datadir;The path to the MySQL server data directory;https://mariadb.com/kb/en/server-system-variables/#datadir
default_storage_engine;The default storage engine for tables;https://mariadb.com/kb/en/server-system-variables/#default_storage_engine
general_log_file;The name of the general query log file;https://mariadb.com/kb/en/server-system-variables/#general_log_file
have_ssl;YES if <code>mysqld</code> supports SSL connections. DISABLED if server is compiled with SSL support, but not started with appropriate connection-encryption options;https://mariadb.com/kb/en/ssltls-system-variables/#have_ssl
hostname;The server sets this variable to the server host name at startup;https://mariadb.com/kb/en/server-system-variables/#hostname
innodb_file_per_table;ON = new InnoDB tables are created with their own InnoDB file-per-table tablespaces<br>OFF = new tables are created in the InnoDB system tablespace instead<br>Deprecated in MariaDB 11.0 as there's no benefit to setting to OFF, the original InnoDB default;https://mariadb.com/kb/en/innodb-system-variables/#innodb_file_per_table
join_buffer_size;Minimum size in bytes of the buffer used for queries that cannot use an index, and instead perform a full table scan;https://mariadb.com/kb/en/server-system-variables/#join_buffer_size
log_slow_query;<code>0</code>=disable, <code>1</code>=enable;https://mariadb.com/kb/en/server-system-variables/#log_slow_query
log_slow_query_file;Name of the slow query log file;https://mariadb.com/kb/en/server-system-variables/#log_slow_query_file
log_slow_query_time;If a query takes longer than this many seconds to execute (microseconds can be specified too), the query is logged to the slow query log.<br>Should be 1-5 seconds (if enabled);https://mariadb.com/kb/en/server-system-variables/#log_slow_query_time
performance_schema;<code>0</code>=disable, <code>1</code>=enable;https://mariadb.com/kb/en/performance-schema-system-variables/#performance_schema
pid_file;Full path of the process ID file;https://mariadb.com/kb/en/server-system-variables/#pid_file
plugin_dir;Path to the plugin directory;https://mariadb.com/kb/en/server-system-variables/#plugin_dir
port;Port to listen for TCP/IP connections (default <code>3306</code>);https://mariadb.com/kb/en/server-system-variables/#port
socket;On Unix platforms, this variable is the name of the socket file that is used for local client connections. The default is <code>/tmp/mysql.sock</code>;https://mariadb.com/kb/en/server-system-variables/#socket
tls_version;Which protocols the server permits for encrypted connections;https://mariadb.com/kb/en/ssltls-system-variables/#tls_version
version;The version number for the server;https://mariadb.com/kb/en/server-system-variables/#version
version_ssl_library;The version of the TLS library that is being used;https://mariadb.com/kb/en/ssltls-system-variables/#version_ssl_library"

    SQLVariableStr="        <tr><th align=\"right\" colspan=\"2\">SQL Variables</th></tr>
        <tr><td colspan=\"2\">
            <table>
                <tr><td><b>Variable</b></td><td><b>Value</b></td><td><b>Explanation</b></td><td><b>Read more</b></td></tr>$NL"
    while IFS=";" read VAR EXPLANATION READMORE
    do
        VALUE="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SHOW VARIABLES LIKE '$VAR';" | awk '{print $2}')"
        # If VALUE is only numbers, present it with thousand separator (unless we are looking ar 'port' in which thousands separator is silly)
        if [ -z "${VALUE//[0-9]/}" ] && [ ! "$VAR" = "port" ]; then
            VALUE="$(printf "%'d" $VALUE)"
        fi
        if [ "$VAR" = "binlog_expire_logs_seconds" ] && [ -n "$VALUE" ]; then
            SQLVariableStr+="                <tr><td><pre>$VAR</pre></td><td><code>$VALUE</code> <i>(=$(time_convert $VALUE))</i></td><td><i>$EXPLANATION</i></td><td><a href=\"$READMORE\" $LinkReferer>&#128214;</a> <span class="glyphicon">&#xe164;</span></td></tr>$NL"
        else
            SQLVariableStr+="                <tr><td><pre>$VAR</pre></td><td><code>$VALUE</code></td><td><i>$EXPLANATION</i></td><td><a href=\"$READMORE\" $LinkReferer>&#128214;</a> <span class="glyphicon">&#xe164;</span></td></tr>$NL"
        fi
    done <<< "$InterestingVariables"
    SQLVariablesReadMoreStr='<br><p><i>Read about <a href="https://mariadb.com/kb/en/server-system-variables/" '$LinkReferer'>Server System Variables</a> <span class="glyphicon">&#xe164;</span>.</i></p>'
    SQLVariableStr+="        </table>$SQLVariablesReadMoreStr</td></tr>$NL"

#    # Print it:
#    while IFS=$'\t' read VAR VALUE
#    do 
#       echo "Var: $VAR ||  Value: $VALUE"
#    done <<< "$SQLVariables"
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #   
#   _____   _____   _          _____   _             _                 
#  /  ___| |  _  | | |        /  ___| | |           | |                
#  \ `--.  | | | | | |        \ `--.  | |_    __ _  | |_   _   _   ___ 
#   `--. \ | | | | | |         `--. \ | __|  / _` | | __| | | | | / __|
#  /\__/ / \ \/' / | |____    /\__/ / | |_  | (_| | | |_  | |_| | \__ \
#  \____/   \_/\_\ \_____/    \____/   \__|  \__,_|  \__|  \__,_| |___/
get_sql_status() {
    InterestingStatus="Aborted_clients%The number of connections that were aborted because the client died without closing the connection properly%https://mariadb.com/kb/en/server-status-variables/#aborted_clients
Aborted_connects%The number of failed attempts to connect to the MySQL server%https://mariadb.com/kb/en/server-status-variables/#aborted_connects
Compression%Whether the client connection uses compression in the client/server protocol.%https://mariadb.com/kb/en/server-status-variables/#compression
Connections%The number of connection attempts (successful or not) to the MySQL server.%https://mariadb.com/kb/en/server-status-variables/#connections
Connection_errors_accept%The number of errors that occurred during calls to <code>accept()</code> on the listening port%https://mariadb.com/kb/en/server-status-variables/#connection_errors_accept
Connection_errors_internal%Number of refused connections due to internal server errors, for example out of memory errors, or failed thread starts%https://mariadb.com/kb/en/server-status-variables/#connection_errors_internal
Handler_read_first%Number of requests to read the first row from an index<br>&#9888;&nbsp;&nbsp;A high value indicates many full index scans%https://mariadb.com/kb/en/server-status-variables/#handler_read_first
Handler_read_key%Number of row read requests based on an index value.<br>A high value indicates indexes are regularly being used, which is usually positive%https://mariadb.com/kb/en/server-status-variables/#handler_read_key
Handler_read_rnd%Number of requests to read a row based on its position<br>&#9888;&nbsp;&nbsp;If this value is high, you may not be using joins that don't use indexes properly, or be doing many full table scans%https://mariadb.com/kb/en/server-status-variables/#handler_read_rnd
Max_statement_time_exceeded%Number of queries that exceeded the execution time specified by <code>max_statement_time</code>.%https://mariadb.com/kb/en/server-status-variables/#max_statement_time_exceeded
Max_used_connections%The maximum number of connections that have been in use simultaneously since the server started%https://mariadb.com/kb/en/server-status-variables/#max_used_connections
Open_files%Number of files that are open, including regular files opened by the server but not sockets or pipes%https://mariadb.com/kb/en/server-status-variables/#open_files
Open_tables%The number of tables that are open%https://mariadb.com/kb/en/server-status-variables/#open_tables
Opened_tables%Number of tables the server has opened.%https://mariadb.com/kb/en/server-status-variables/#opened_tables
Queries%The number of statements executed by the server%https://mariadb.com/kb/en/server-status-variables/#queries
Rpl_semi_sync_slave_status%Shows whether semisynchronous replication is currently operational on the replica%https://mariadb.com/kb/en/semisynchronous-replication-plugin-status-variables/#rpl_semi_sync_slave_status
Select_full_join%Number of joins which did not use an index<br>&#9888;&nbsp;&nbsp;If not <code>0</code>, you may need to check table indexes%https://mariadb.com/kb/en/server-status-variables/#select_full_join
Select_range%Number of joins which used a range on the first table.%https://mariadb.com/kb/en/server-status-variables/#select_range
Select_range_check%Number of joins without keys that check for key usage after each row<br>&#9888;i&nbsp;&nbsp;If not <code>0</code>, you may need to check table indexes%https://mariadb.com/kb/en/server-status-variables/#select_range_check
Select_scan%Number of joins which used a full scan of the first table.%https://mariadb.com/kb/en/server-status-variables/#select_scan
Sort_rows%Number of rows sorted.%https://mariadb.com/kb/en/server-status-variables/#sort_rows
Slave_running%Whether the default connection slave is running (both I/O and SQL threads are running) or not.%https://mariadb.com/kb/en/replication-and-binary-log-status-variables/
Uptime%The number of seconds that the server has been up%https://mariadb.com/kb/en/server-status-variables/#uptime"

    # get the server uptime (needed for calculations)
    DaemonUptime=$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SHOW STATUS LIKE 'Uptime';" | awk '{print $2}')      # Ex: DaemonUptime=201346
    DaemonUptimeH=$((DaemonUptime / 3600))                                                                                  # Ex: DaemonUptimeH=55
    SQLStatusStr="        <tr><th colspan=\"2\">SQL status</th></tr>
        <tr><td colspan=\"2\">
            <table>
                <tr><td><b>Variable</b></td><td align=\"right\"><b>Value, absolute</b></td><td align=\"right\"><b>Value / hour</b></td><td><b>Explanation</b></td><td><b>Read more</b></td></tr>$NL"
    while IFS="%" read VAR EXPLANATION READMORE
    do
        EVALUATION=""
        VALUE="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SELECT FORMAT(VARIABLE_VALUE, 0) FROM INFORMATION_SCHEMA.GLOBAL_STATUS WHERE VARIABLE_NAME = '$VAR';")"  # Ex: VALUE=35,862,850
        # Deal with situations where we do not get a value at all:
        if [ -z $VALUE ]; then
            VALUE=0
        fi
        if [ "$VAR" = "Uptime" ]; then
            UptimeH="$(time_convert "${VALUE//,/}" | sed 's/ [0-9]* sec//')"                                                # Ex: UptimeH='2 days 6 hours 59 min'
            ExplAddendum="<br>($VALUE seconds = $UptimeH)"
            ValuePerHourStr=""
        else
            ExplAddendum=""
            ValuePerHour="$(( $(echo "${VALUE//,/}") / DaemonUptimeH))"                                                     # Ex: ValuePerHour=459882
            ValuePerHourStr="$(printf "%'d" $ValuePerHour)"                                                                 # Ex: ValuePerHourStr=459,882
        fi
        SQLStatusStr+="                <tr><td><pre>$VAR</pre></td><td align=\"right\"><code>$VALUE</code></td><td align=\"right\"><code>$ValuePerHourStr</code></td><td><i>$EXPLANATION $ExplAddendum</i></td><td><a href=\"$READMORE\" $LinkReferer>&#128214;</a> <span class="glyphicon">&#xe164;</span></td></tr>$NL"
    done <<< "$InterestingStatus"
    SQLStatusReadMoreStr='<br><p><i>Read about <a href="https://mariadb.com/kb/en/server-status-variables/" '$LinkReferer'>Server Status Variables</a> <span class="glyphicon">&#xe164;</span>.</i></p>'
    SQLStatusStr+="        </table>$SQLStatusReadMoreStr</td></tr>$NL"
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#   _____          _        _                 _        _                                                                        _          _           _           
#  |  __ \        | |      | |               | |      | |                                                                      | |        | |         | |          
#  | |  \/   ___  | |_     | |   __ _   ___  | |_     | | __  _ __     ___   __      __  _ __        __ _    ___     ___     __| |      __| |   __ _  | |_    __ _ 
#  | | __   / _ \ | __|    | |  / _` | / __| | __|    | |/ / | '_ \   / _ \  \ \ /\ / / | '_ \      / _` |  / _ \   / _ \   / _` |     / _` |  / _` | | __|  / _` |
#  | |_\ \ |  __/ | |_     | | | (_| | \__ \ | |_     |   <  | | | | | (_) |  \ V  V /  | | | |    | (_| | | (_) | | (_) | | (_| |    | (_| | | (_| | | |_  | (_| |
#   \____/  \___|  \__|    |_|  \__,_| |___/  \__|    |_|\_\ |_| |_|  \___/    \_/\_/   |_| |_|     \__, |  \___/   \___/   \__,_|     \__,_|  \__,_|  \__|  \__,_|
#                                                                                                    __/ |                                                         
#                                                                                                   |___/                                                          
get_last_known_good_data() {
    LastRunFileDatetime="$(stat --format %x "$LastRunFile" | sed 's/\.[0-9]*//')"                  # Ex: LastRunFileDatetime='2024-02-07 08:55:05 +0100'
    echo "        </tbody>" >> "$EmailTempFile"
    echo "    </table>" >> "$EmailTempFile"
    echo "    <p>&nbsp;</p>" >> "$EmailTempFile"
    echo "    <p>&nbsp;</p>" >> "$EmailTempFile"
    echo "    <h1 align=\"center\" style=\"color: red\">Last known good data</h1>" >> "$EmailTempFile"
    echo "    <p align=\"center\" style=\"color: red\">Date: $LastRunFileDatetime</p>" >> "$EmailTempFile"
    echo "    <p>&nbsp;</p>" >> "$EmailTempFile"
    echo "    <table id=\"jobe\">" >> "$EmailTempFile"
    echo "        <tbody>" >> "$EmailTempFile"
    cat "$LastRunFile" >> "$EmailTempFile"
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#    ___                                   _       _                               _                                       
#   / _ \                                 | |     | |                             | |                                      
#  / /_\ \  ___   ___    ___   _ __ ___   | |__   | |   ___     __      __   ___  | |__       _ __     __ _    __ _    ___ 
#  |  _  | / __| / __|  / _ \ | '_ ` _ \  | '_ \  | |  / _ \    \ \ /\ / /  / _ \ | '_ \     | '_ \   / _` |  / _` |  / _ \
#  | | | | \__ \ \__ \ |  __/ | | | | | | | |_) | | | |  __/     \ V  V /  |  __/ | |_) |    | |_) | | (_| | | (_| | |  __/
#  |_| |_| |___/ |___/  \___| |_| |_| |_| |_.__/  |_|  \___|      \_/\_/    \___| |_.__/     | .__/   \__,_|  \__, |  \___|
#                                                                                            | |               __/ |       
#                                                                                            |_|              |___/        
assemble_web_page() {
    # Get the head of the custom report, replace SERVER and DATE
    curl --silent $ReportHead | sed "s/SERVER/$ServerName/;s/DATE/$(date +%F)/;$CSS_colorfix;s/Backup/SQL/;s/1200/1250/" >> "$EmailTempFile"
    # Only continue if it worked
    if grep "SQL report for" "$EmailTempFile" &>/dev/null ; then
        echo "<body>" >> "$EmailTempFile"
        echo '<div class="main_page">' >> "$EmailTempFile"
        echo '  <div class="flexbox-container">' >> "$EmailTempFile"
        echo '    <div id="box-header">' >> "$EmailTempFile"
        echo "      <h3>SQL report for</h3>" >> "$EmailTempFile"
        echo "      <h1>$ServerName</h1>" >> "$EmailTempFile"
        echo "      <h4>$(date "+%Y-%m-%d %T %Z")</h4>" >> "$EmailTempFile"
        echo "    </div>" >> "$EmailTempFile"
        echo "  </div>" >> "$EmailTempFile"
        echo "  <section>" >> "$EmailTempFile"
        echo "    <p>&nbsp;</p>" >> "$EmailTempFile"
        echo "    <p align=\"left\"> Report generated by script: <code>${ScriptFullName}</code><br>" >> "$EmailTempFile"
        echo "      Script launched $ScriptLaunchText by: <code>${ScriptLauncher:---no launcher detected--}</code> </p>" >> "$EmailTempFile"
        echo '    <p align="left">&nbsp;</p>' >> "$EmailTempFile"
        echo '    <p align="left">&nbsp;</p>' >> "$EmailTempFile"
        if [ -n "$RunningDaemonLine" ]; then
            echo '    <h1 align="center">R u n n i n g&nbsp;&nbsp;&nbsp;&nbsp;i n s t a n c e</h1>' >> "$EmailTempFile"
            echo '    <p>&nbsp;</p>' >> "$EmailTempFile"
            echo '    <table id="jobe">' >> "$EmailTempFile"
            echo "      <tbody>" >> "$EmailTempFile"
            echo "$DaemonInfoStr" >> "$EmailTempFile"
            echo "$DBCheckString" >> "$EmailTempFile"
            echo "$DatabaseTblString" >> "$EmailTempFile"
            echo '      </tbody>' >> "$EmailTempFile"
            echo '    </table>' >> "$EmailTempFile"
            echo '    <p>&nbsp;</p>' >> "$EmailTempFile"
            echo '    <p>&nbsp;</p>' >> "$EmailTempFile"
            echo '    <h1 align="center">D a t a b a s e&nbsp;&nbsp;&nbsp;&nbsp;s e t t i n g s</h1>' >> "$EmailTempFile"
            echo '    <p>&nbsp;</p>' >> "$EmailTempFile"
            echo '    <table id="jobe">' >> "$EmailTempFile"
            echo '      <tbody>' >> "$EmailTempFile"
            echo "$MainReplicaString" >> "$EmailTempFile"
            echo "$SQLUsersTablePart" >> "$EmailTempFile"
            echo "$StorageEngineStr" >> "$EmailTempFile"
            echo "$SQLVariableStr" >> "$EmailTempFile"
            echo "$SQLStatusStr" >> "$EmailTempFile"
        else
            echo '    <h1 align="center" style="color: red">D E A D &nbsp;&nbsp;&nbsp;&nbsp;i n s t a n c e</h1>' >> "$EmailTempFile"
            echo '    <p>&nbsp;</p>' >> "$EmailTempFile"
            echo '    <table id="jobe">' >> "$EmailTempFile"
            echo "      <tbody>" >> "$EmailTempFile"
            echo "$DaemonInfoStr" >> "$EmailTempFile"
            get_last_known_good_data
        fi
        echo "      </tbody>" >> "$EmailTempFile"
        echo "    </table>" >> "$EmailTempFile"
        echo '    <p align="left">&nbsp;</p>' >> "$EmailTempFile"
        echo '    <p align="left">&nbsp;</p>' >> "$EmailTempFile"
        echo '    <h1 align="center">M i s c.&nbsp;&nbsp;&nbsp;&nbsp;i n f o</h1>' >> "$EmailTempFile"
        echo '    <p>&nbsp;</p>' >> "$EmailTempFile"
        echo '    <table id="jobe">' >> "$EmailTempFile"
        echo '      <tbody>' >> "$EmailTempFile"
        echo '		    <tr><th colspan="2">Performance</th></tr>' >> "$EmailTempFile"
        echo '		    <tr><td>MariaDB Internal Optimizations</td><td><a href="https://mariadb.com/kb/en/mariadb-internal-optimizations/" '$LinkReferer'>https://mariadb.com/kb/en/mariadb-internal-optimizations/</a> <span class="glyphicon">&#xe164;</span></td></tr>' >> "$EmailTempFile"
        echo '		    <tr><td>MariaDB Memory Allocation</td><td><a href="https://mariadb.com/kb/en/mariadb-memory-allocation/" '$LinkReferer'>https://mariadb.com/kb/en/mariadb-memory-allocation/</a> <span class="glyphicon">&#xe164;</span></td></tr>' >> "$EmailTempFile"
        echo '		    <tr><td>Optimizing Tables</td><td><a href="https://mariadb.com/kb/en/optimizing-tables/" '$LinkReferer'>https://mariadb.com/kb/en/optimizing-tables/</a> <span class="glyphicon">&#xe164;</span></td></tr>' >> "$EmailTempFile"
        echo '		    <tr><td><code>MySQLTuner.pl</code></td><td><a href="https://github.com/major/MySQLTuner-perl" '$LinkReferer'>https://github.com/major/MySQLTuner-perl</a> <span class="glyphicon">&#xe164;</span></td></tr>' >> "$EmailTempFile"
        echo '		    <tr><td>Optimization and Tuning</td><td><a href="https://mariadb.com/kb/en/optimization-and-tuning/" '$LinkReferer'>https://mariadb.com/kb/en/optimization-and-tuning/</a> <span class="glyphicon">&#xe164;</span></td></tr>' >> "$EmailTempFile"
        echo '		    <tr><td>How to check and repair MySQL Databases</td><td><a href="https://www.globo.tech/learning-center/how-to-check-and-repair-mysql-databases/" '$LinkReferer'>https://www.globo.tech/learning-center/how-to-check-and-repair-mysql-databases/</a> <span class="glyphicon">&#xe164;</span></td></tr>' >> "$EmailTempFile"
        echo '		    <tr><td>Ultimate Guide to MariaDB Performance Tuning</td><td><a href="https://www.cloudways.com/blog/mariadb-performance-tuning/" '$LinkReferer'>https://www.cloudways.com/blog/mariadb-performance-tuning/</a> <span class="glyphicon">&#xe164;</span></td></tr>' >> "$EmailTempFile"
        echo '		    <tr><td>Configuring InnoDB Buffer Pool Size</td><td><a href="https://dev.mysql.com/doc/refman/8.0/en/innodb-buffer-pool-resize.html" '$LinkReferer'>https://dev.mysql.com/doc/refman/8.0/en/innodb-buffer-pool-resize.html</a> <span class="glyphicon">&#xe164;</span></td></tr>' >> "$EmailTempFile"
        echo '		    <tr><th colspan="2">Security</th></tr>' >> "$EmailTempFile"
        echo '		    <tr><td>Securing MariaDB</td><td><a href="https://mariadb.com/kb/en/securing-mariadb/" '$LinkReferer'>https://mariadb.com/kb/en/securing-mariadb/</a> <span class="glyphicon">&#xe164;</span></td></tr>' >> "$EmailTempFile"
        echo '		    <tr><td>MariaDB Security: Threats and Best Practices</td><td><a href="https://satoricyber.com/mysql-security/mariadb-security-threats-and-best-practices/" '$LinkReferer'>https://satoricyber.com/mysql-security/mariadb-security-threats-and-best-practices/</a> <span class="glyphicon">&#xe164;</span></td></tr>' >> "$EmailTempFile"
        echo '	    </tbody>' >> "$EmailTempFile"
        echo '	  </table>' >> "$EmailTempFile"
        echo '' >> "$EmailTempFile"
        echo "  </section>" >> "$EmailTempFile"
        echo '  <p align="center"><em>Report generated by &#8220;sql-info&#8221; (<a href="https://github.com/Peter-Moller/sql-info" '$LinkReferer'>GitHub</a> <span class="glyphicon">&#xe164;</span>)</em></p>' >> "$EmailTempFile"
        echo '  <p align="center"><em>Department of Computer Science, LTH/LU</em></p>' >> "$EmailTempFile"
        echo '  <p align="center" style="font-size: smaller"><em>Version: '$Version'</em></p>' >> "$EmailTempFile"
        echo "</div>" >> "$EmailTempFile"
        echo "</body>" >> "$EmailTempFile"
        echo "</html>" >> "$EmailTempFile"
    else
        echo "<body>" >> "$EmailTempFile"
        echo "<h1>Could not get $ReportHead!!</h1>"
        echo "</body>" >> "$EmailTempFile"
        echo "</html>" >> "$EmailTempFile"
    fi

}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#   _____                         _                                                    _                                 _   _ 
#  /  __ \                       | |               ___                                | |                               (_) | |
#  | /  \/  _ __    ___    __ _  | |_    ___      ( _ )       ___    ___   _ __     __| |      ___   _ __ ___     __ _   _  | |
#  | |     | '__|  / _ \  / _` | | __|  / _ \     / _ \/\    / __|  / _ \ | '_ \   / _` |     / _ \ | '_ ` _ \   / _` | | | | |
#  | \__/\ | |    |  __/ | (_| | | |_  |  __/    | (_>  <    \__ \ |  __/ | | | | | (_| |    |  __/ | | | | | | | (_| | | | | |
#   \____/ |_|     \___|  \__,_|  \__|  \___|     \___/\/    |___/  \___| |_| |_|  \__,_|     \___| |_| |_| |_|  \__,_| |_| |_|

email_html_create_send() {
    EmailTempFile=$(mktemp /tmp/sql-info.XXXX)

    if $Verify; then
        # Get the status of the whole operation
        if [ $ES_mariadb_check -eq 0 ]; then
            Status="Database verification OK"
        else
            Status="Database NOT verified ok"
        fi
    elif [ -n "$RunningDaemonLine" ]; then
        Status="SQL info for $ServerName"
    else
        Status="Daemon is NOT RUNNING!"
    fi

    # Set the headers in order to use sendmail
    echo "To: $Recipient" >> "$EmailTempFile"
    echo "Subject: $Status" >> "$EmailTempFile"
    echo "Content-Type: text/html" >> "$EmailTempFile"
    echo "" >> "$EmailTempFile"

    # Create the html content
    assemble_web_page

    if [ -n "$Recipient" ]; then
        cat "$EmailTempFile" | /sbin/sendmail -t
        #echo "$MailReport" | mail -s "${ServerName}: $Status" "$Recipient"
    fi

}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#   _____                                                          _   _
#  /  __ \                                                        | | | |
#  | /  \/   ___    _ __    _   _      _ __    ___   ___   _   _  | | | |_
#  | |      / _ \  | '_ \  | | | |    | '__|  / _ \ / __| | | | | | | | __|
#  | \__/\ | (_) | | |_) | | |_| |    | |    |  __/ \__ \ | |_| | | | | |_
#   \____/  \___/  | .__/   \__, |    |_|     \___| |___/  \__,_| |_|  \__|
#                  | |       __/ |
#                  |_|      |___/

copy_result() {
    # Copy result if SCP=true
    if $SCP; then
        sed -n '5,$p' <"$EmailTempFile" >"${EmailTempFile}_scp"
        scp "${EmailTempFile}_scp" "${SCP_USER}@${SCP_HOST}:${SCP_DIR}/${ServerName,,}.html" &>/dev/null
    fi
}

#   _____   _   _  ______       _____  ______     ______   _   _   _   _   _____   _____   _____   _____   _   _   _____ 
#  |  ___| | \ | | |  _  \     |  _  | |  ___|    |  ___| | | | | | \ | | /  __ \ |_   _| |_   _| |  _  | | \ | | /  ___|
#  | |__   |  \| | | | | |     | | | | | |_       | |_    | | | | |  \| | | /  \/   | |     | |   | | | | |  \| | \ `--. 
#  |  __|  | . ` | | | | |     | | | | |  _|      |  _|   | | | | | . ` | | |       | |     | |   | | | | | . ` |  `--. \
#  | |___  | |\  | | |/ /      \ \_/ / | |        | |     | |_| | | |\  | | \__/\   | |    _| |_  \ \_/ / | |\  | /\__/ /
#  \____/  \_| \_/ |___/        \___/  \_|        \_|      \___/  \_| \_/  \____/   \_/    \___/   \___/  \_| \_/ \____/ 
#  
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

script_location

script_launcher

platform_info

get_daemon_info

# Only present stuff if the daemon *is* running
if [ -n "$RunningDaemonLine" ]; then
    do_mariadb_check

    get_database_overview

    get_sql_users

    get_storage_engines

    get_sql_variables

    get_sql_status

    echo "$DaemonInfoStr$NL$DatabaseTblString" > "$LastRunFile"
fi

email_html_create_send

copy_result

rm "$EmailTempFile"
