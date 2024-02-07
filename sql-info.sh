#!/bin/bash
# Script to do a fairly thorough check of a MariaDB or MySQL database
# 2024-01-30 / Peter Möller
# Department of Computer Science, Lund University


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


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #   
#   _____   _____   _          _    _                  _           _       _              
#  /  ___| |  _  | | |        | |  | |                (_)         | |     | |             
#  \ `--.  | | | | | |        | |  | |   __ _   _ __   _    __ _  | |__   | |   ___   ___ 
#   `--. \ | | | | | |        | |  | |  / _` | | '__| | |  / _` | | '_ \  | |  / _ \ / __|
#  /\__/ / \ \/' / | |____     \ \/ /  | (_| | | |    | | | (_| | | |_) | | | |  __/ \__ \
#  \____/   \_/\_\ \_____/      \__/    \__,_| |_|    |_|  \__,_| |_.__/  |_|  \___| |___/

get_sql_variables() {
    #InterestingVariables="^binlog_expire_logs_seconds\b|^binlog_file_cache_size\b|^collation_connection\b|^collation_database\b|^collation_server\b|^datadir\b|^default_storage_engine\b|^general_log_file\b|^have_ssl\b|^hostname\b|^log_slow_query\b|^log_slow_query_file\b|^log_slow_query_time\b|^performance_schema\b|^pid_file\b|^plugin_dir\b|^port\b|^socket\b|^tls_version\b|^version\b|^version_ssl_library\b"
    SQLVariablesReadMoreStr='<br><p><i>Read about <a href="https://mariadb.com/kb/en/server-system-variables/">Server System Variables</a>.</i></p>'
    InterestingVariables="binlog_expire_logs_seconds	The binary log expiration period in seconds
binlog_file_cache_size	Size of in-memory cache that is allocated when reading binary log and relay log files. <a href=\"https://mariadb.com/kb/en/replication-and-binary-log-system-variables/#binlog_file_cache_size\">Read about it</a>
collation_connection	
collation_database	The collation used by the default database
collation_server	The server's default collation
datadir	The path to the MySQL server data directory
default_storage_engine	The default storage engine for tables
general_log_file	The name of the general query log file
have_ssl	YES if mysqld supports SSL connections. DISABLED if server is compiled with SSL support, but not started with  appropriate connection-encryption options
hostname	The server sets this variable to the server host name at startup
log_slow_query	<a href=\"https://mariadb.com/kb/en/server-system-variables/#log_slow_query\">Read about it</a>
log_slow_query_file	Name of the slow query log file.
log_slow_query_time	If a query takes longer than this many seconds to execute (microseconds can be specified too), the query is logged to the slow query log
performance_schema	<a href=\"https://mariadb.com/kb/en/performance-schema-system-variables/#performance_schema\">Read about performance_schema</a>
pid_file	Full path of the process ID file
plugin_dir	Path to the plugin directory
port	Port to listen for TCP/IP connections. If set to 0, will default to, in order of preference, my.cnf, the MYSQL_TCP_PORT environment variable, /etc/services, built-in default (3306)
socket	On Unix platforms, this variable is the name of the socket file that is used for local client connections. The default is <pre>/tmp/mysql.sock</pre>
tls_version	Which protocols the server permits for encrypted connections
version	The version number for the server
version_ssl_library	The version of the TLS library that is being used"

    #SQLVariables="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SHOW VARIABLES;" | grep -E "$InterestingVariables")"
    # Ex: SQLVariables='binlog_expire_logs_seconds	864000
    #                   binlog_file_cache_size	16384
    #                   collation_connection	utf8mb3_general_ci
    #                   collation_database	utf8mb4_general_ci
    #                   collation_server	utf8mb4_general_ci
    #                   datadir	/var/lib/mysql/
    #                   date_format	%Y-%m-%d
    #                   datetime_format	%Y-%m-%d %H:%i:%s
    #                   default_storage_engine	InnoDB
    #                   general_log_file	0f552df2da7f.log
    #                   have_ssl	DISABLED
    #                   hostname	0f552df2da7f
    #                   log_slow_query	ON
    #                   log_slow_query_file	slow-queries.log
    #                   log_slow_query_time	1.000000
    #                   performance_schema	OFF
    #                   pid_file	/run/mysqld/mysqld.pid
    #                   plugin_dir	/usr/lib/mysql/plugin/
    #                   port	3306
    #                   slow_query_log	ON
    #                   slow_query_log_file	slow-queries.log
    #                   socket	/run/mysqld/mysqld.sock
    #                   storage_engine	InnoDB
    #                   tls_version	TLSv1.1,TLSv1.2,TLSv1.3
    #                   version	10.11.4-MariaDB-1:10.11.4+maria~ubu2204-log
    #                   version_ssl_library	OpenSSL 3.0.2 15 Mar 2022'
    # READ MORE: https://dev.mysql.com/doc/refman/8.0/en/show-variables.html

    SQLVariableStr="        <tr><th align=\"right\" colspan=\"2\">SQL Variables</th></tr>
        <tr><td colspan=\"2\">
            <table>
                <tr><td><b>Variable</b></td><td><b>Value</b></td><td><b>Explanation</b></td></tr>$NL"
    while read VAR EXPLANATION
    do
        VALUE="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SHOW VARIABLES LIKE '$VAR';" | awk '{print $2}')"
        if [ "$VAR" = "binlog_expire_logs_seconds" ] && [ -n "$VALUE" ]; then
            SQLVariableStr+="                <tr><td><pre>$VAR</pre></td><td><code>$VALUE</code> <i>(=$(time_convert $VALUE))</i></td><td><i>$EXPLANATION</i></td></tr>$NL"
        else
            SQLVariableStr+="                <tr><td><pre>$VAR</pre></td><td><code>$VALUE</code></td><td><i>$EXPLANATION</i></td></tr>$NL"
        fi
    done <<< "$InterestingVariables"
    SQLVariableStr+="        </table>$SQLVariablesReadMoreStr</td></tr>$NL"

#    # Print it:
#    while IFS=$'\t' read VAR VALUE
#    do 
#    	echo "Var: $VAR ||  Value: $VALUE"
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
    SQLStatusReadMoreStr='<br><p><i>Read about <a href="https://mariadb.com/kb/en/server-status-variables/">Server Status Variables</a>.</i></p>'
    InterestingStatus="Aborted_clients	The number of connections that were aborted because the client died without closing the connection properly
Aborted_connects	The number of failed attempts to connect to the MySQL server
Compression	Whether the client connection uses compression in the client/server protocol.
Connections	The number of connection attempts (successful or not) to the MySQL server.
Connection_errors_accept	The number of errors that occurred during calls to accept() on the listening port
Connection_errors_internal	The number of connections refused due to internal errors in the server, such as failure to start a new thread or an out-of-memory condition
innodb_buffer_pool_size	The size in bytes of the buffer pool, the memory area where InnoDB caches table and index data. Default is 128 MB.<br><a href=\"https://mariadb.com/kb/en/innodb-buffer-pool/\">Read about InnoDB Buffer Pool</a>
Max_statement_time_exceeded	If set, any query taking longer than this value (in seconds) to execute will be aborted
Max_used_connections	The maximum number of connections that have been in use simultaneously since the server started
Open_files	Number of files that are open, including regular files opened by the server but not sockets or pipes
Open_tables	The number of tables that are open
Queries	The number of statements executed by the server
Rpl_semi_sync_slave_status	Shows whether semisynchronous replication is currently operational on the replica
Slave_running	
Uptime	The number of seconds that the server has been up"

    SQLStatusStr="        <tr><th colspan=\"2\">SQL status</th></tr>
        <tr><td colspan=\"2\">
            <table>
                <tr><td><b>Variable</b></td><td><b>Value</b></td><td><b>Explanation</b></td></tr>$NL"
    while read VAR EXPLANATION
    do
        #VALUE="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SHOW STATUS LIKE '$VAR';" | awk '{print $2}')"
        VALUE="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SELECT FORMAT(VARIABLE_VALUE, 0) FROM INFORMATION_SCHEMA.GLOBAL_STATUS WHERE VARIABLE_NAME = '$VAR';")"
        SQLStatusStr+="            <tr><td><pre>$VAR</pre></td><td align=\"right\"><code>$VALUE</code></td><td><i>$EXPLANATION</i></td></tr>$NL"
    done <<< "$InterestingStatus"
    SQLStatusStr+="        </table>$SQLStatusReadMoreStr</td></tr>$NL"
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
    
    UserList="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SELECT user,host FROM mysql.user" | sed '1d' | tr -d '\r')"
    # Ex: UserList='replication_user	%
    #               root	%
    #               mariadb.sys	localhost
    #               root	localhost'
    ##UserQString="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "select distinct concat('SHOW GRANTS FOR ', QUOTE(user), '@', QUOTE(host), ';') as query from mysql.user;" | grep -Ev "^query$")"
    # Ex: UserQString='SHOW GRANTS FOR '\''replication_user'\''@'\''%'\'';
    #                  SHOW GRANTS FOR '\''root'\''@'\''%'\'';
    #                  SHOW GRANTS FOR '\''mariadb.sys'\''@'\''localhost'\'';
    #                  SHOW GRANTS FOR '\''root'\''@'\''localhost'\'';'
    # READ MORE: https://dev.mysql.com/doc/refman/8.0/en/show-grants.html
    
    ##GrantString="$(while read -r ROW; do ${SQLCommand/-it/} -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "$ROW" | sed "s/'[^']*'/'XXX'/"; done <<< "$UserQString")"
    # Ex: GrantString='GRANT REPLICATION SLAVE ON *.* TO `replication_user`@`%` IDENTIFIED BY PASSWORD '\''XXX'\''
    #                  GRANT ALL PRIVILEGES ON *.* TO `root`@`%` IDENTIFIED BY PASSWORD '\''XXX'\'' WITH GRANT OPTION
    #                  GRANT USAGE ON *.* TO `mariadb.sys`@`localhost`
    #                  GRANT SELECT, DELETE ON `mysql`.`global_priv` TO `mariadb.sys`@`localhost`
    #                  GRANT ALL PRIVILEGES ON *.* TO `root`@`localhost` IDENTIFIED BY PASSWORD '\''XXX'\'' WITH GRANT OPTION
    #                  GRANT PROXY ON '\''XXX'\''@'\''%'\'' TO '\''root'\''@'\''localhost'\'' WITH GRANT OPTION'

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
    # Ex: MariaDB [moodle]> SELECT engine, count(*) AS tables, concat(round (sum(table_rows)/(1000000), 2), 'M') AS num_rows, concat(round(sum(data_length)/(1024*1024*1024),2), 'GB') AS data, concat(round (sum(index_length)/(1024*1024*1024),2), 'GB') AS idx, concat(round (sum(data_length+index_length)/ (1024*1024*1024), 2), 'GB') AS total_size FROM information_schema.TABLES GROUP BY engine ORDER BY engine asc;
    # MariaDB [moodle]> SELECT engine, count(*) AS tables, concat(round (sum(table_rows)/(1000000), 2), 'M') AS num_rows, concat(round(sum(data_length)/(1024*1024*1024),2), 'GB') AS data, concat(round (sum(index_length)/(1024*1024*1024),2), 'GB') AS idx, concat(round (sum(data_length+index_length)/ (1024*1024*1024), 2), 'GB') AS total_size FROM information_schema.TABLES GROUP BY engine ORDER BY engine asc;
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
		<p><i>Read an overview of <a href=\"https://dev.mysql.com/doc/refman/8.0/en/pluggable-storage-overview.html\">storage engines</a></i></p></td></tr>"
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
    #DatabaseOverviewSQL="SELECT TABLE_SCHEMA,COUNT(TABLE_NAME),FORMAT(SUM(TABLE_ROWS),0),FORMAT(SUM(DATA_LENGTH),0),FORMAT(SUM(INDEX_LENGTH),0),DATA_FREE,TABLE_COLLATION,CREATE_TIME,UPDATE_TIME,ENGINE FROM information_schema.tables GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA ASC;"
    DatabaseOverviewSQL="SELECT TABLE_SCHEMA,COUNT(TABLE_NAME) AS Num_tables, FORMAT(SUM(TABLE_ROWS),0) AS ∑_rows, FORMAT(SUM(DATA_LENGTH),0) AS ∑_data, FORMAT(SUM(INDEX_LENGTH),0) AS ∑_index, DATA_FREE,TABLE_COLLATION,CREATE_TIME,UPDATE_TIME,ENGINE FROM information_schema.tables GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA ASC;"
    DatabaseOverview="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "$DatabaseOverviewSQL" | tr -d '\r')"
    # Ex: DatabaseOverview='information_schema	   79	       NULL	        106,496	        106,496	       0	utf8mb3_general_ci	2024-02-06 19:38:39	 2024-02-06 19:38:39  Aria
    #                       moodle	              510	100,056,805	 36,599,554,048	 11,567,128,576	       0	utf8mb4_unicode_ci	2024-01-18 13:15:42	 NULL	              InnoDB
    #                       mysql	               31	    145,369	      9,912,320	      2,727,936	       0	utf8mb3_general_ci	2024-01-18 14:31:27	 2024-01-18 14:31:27  Aria
    #                       performance_schema	   81	        535	              0	              0	       0	utf8mb3_general_ci	NULL	             NULL	              PERFORMANCE_SCHEMA
    #                       sys	                  101	          6	         16,384	         16,384	     NULL	NULL	            NULL	             NULL	              NULL'
    #                       Database           #table          ∑row    ∑data_length   ∑index_length  DataFree   Collation           Created              Updated              Storage Engine
    #                         1                     2             3               4               5         6   7                   8                    9                      10

    ##DatabaseOverviewSQL="SELECT TABLE_SCHEMA,COUNT(TABLE_NAME),FORMAT(SUM(TABLE_ROWS),0),SUM(DATA_LENGTH),SUM(INDEX_LENGTH),DATA_FREE,TABLE_COLLATION,CREATE_TIME,UPDATE_TIME,ENGINE FROM information_schema.tables GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA ASC;"
    # Ex: DatabaseOverview='information_schema	        79	           NULL	        106,496	        106,496	        0	utf8mb3_general_ci	2024-02-05 20:14:58	 2024-02-05 20:14:58	Aria
    #                       moodle	                   510	    100,054,996	 36,590,018,560	 11,565,973,504	        0	utf8mb4_unicode_ci	2024-01-18 13:15:42	 NULL	                InnoDB
    #                       mysql	                    31	        146,501	      9,912,320  	  2,727,936	        0	utf8mb3_general_ci	2024-01-18 14:31:27	 2024-01-18 14:31:27	Aria
    #                       performance_schema          81	            535	              0	              0	        0	utf8mb3_general_ci	NULL	             NULL	                PERFORMANCE_SCHEMA
    #                       sys	                       101	              6	         16,384	         16,384	     NULL	NULL	            NULL	             NULL	                NULL'
    #                       Database                #table             ∑row    ∑data_length   ∑index_length  DataFree   Collation           Created              Updated                Storage Engine
    #                         1                          2                3               4               5         6   7                   8                    9                      10
    # Ex: DatabaseOverview='moodle         510                 99,833,991                36,585,676,800              0          utf8mb4_unicode_ci  2024-01-29 06:43:46  NULL                 InnoDB    
    #                       mysql           31                 144,721                   9,912,320                   0          utf8mb3_general_ci  2024-01-18 14:31:27  2024-01-29 06:39:23  Aria      '
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
        #DataLength="$(numfmt --to=iec-i --suffix=B --format="%9.1f" $SumDataLength 2>/dev/null | sed 's/K/ K/;s/M/ M/;s/G/ G/;s/^ *//')"             # Ex: DataLength='34.1 GiB'
        #if [ -z "$DataLength" ]; then
        #    DataLength="$(numfmt --to=iec-i --suffix=B --format="%9f" $SumDataLength 2>/dev/null | sed 's/K/ K/;s/M/ M/;s/G/ G/;s/^ *//')"
        #fi
        #IndexLength="$(numfmt --to=iec-i --suffix=B --format="%9.1f" $SumIndexLength 2>/dev/null | sed 's/K/ K/;s/M/ M/;s/G/ G/;s/^ *//')"           # Ex: IndexLength='10.8 GiB'
        #if [ -z "$IndexLength" ]; then
        #    IndexLength="$(numfmt --to=iec-i --suffix=B --format="%9f" $SumIndexLength 2>/dev/null | sed 's/K/ K/;s/M/ M/;s/G/ G/;s/^ *//')"
        #fi
        DatabaseTblString+="            <tr><td><code>$DB</code></td><td align=\"right\">$NumTables</td><td align=\"right\">$SumRows</td><td align=\"right\">$SumDataLength</td><td align=\"right\">$SumIndexLength</td><td align=\"right\">${DatabaseDiskVolume:-0 KiB}</td><td>$Collation</td><td>${CreateTime/_/ }</td><td>$Engine</td></tr>$NL"
    done <<< "$(echo "$DatabaseOverview" | sed 's/ /_/g')"
    DatabaseTblString+="        </table></td></tr>$NL"

    # Get data for the 5 largest tables
    #FiveLargestTablesSQL="SELECT TABLE_SCHEMA,TABLE_NAME,FORMAT(TABLE_ROWS,0),FORMAT((DATA_LENGTH+INDEX_LENGTH)/1024/1024,0),ENGINE,CREATE_TIME,UPDATE_TIME,TABLE_COLLATION,ROUND((DATA_FREE/DATA_LENGTH)*100.0,1) FROM information_schema.TABLES ORDER BY TABLE_ROWS DESC LIMIT 5;"
    FiveLargestTablesSQL="SELECT TABLE_SCHEMA,TABLE_NAME,FORMAT(TABLE_ROWS,0) AS Num_rows,FORMAT((DATA_LENGTH+INDEX_LENGTH),0) AS ∑_size,ENGINE,CREATE_TIME,UPDATE_TIME,TABLE_COLLATION,ROUND((DATA_FREE/DATA_LENGTH)*100.0,1) AS Fragm FROM information_schema.TABLES ORDER BY TABLE_ROWS DESC LIMIT 5;"
    # Ex: FiveLargestTables='moodle	mdl_question_attempt_step_data	54,278,475	26,836,205,568	InnoDB	2024-01-18 13:50:02	 2024-02-06 19:50:35	utf8mb4_unicode_ci	0.0
    #                        moodle	mdl_logstore_standard_log	    23,341,868	11,951,456,256	InnoDB	2024-01-18 13:20:30	 2024-02-06 19:50:37	utf8mb4_unicode_ci	0.1
    #                        moodle	mdl_question_attempt_steps	    11,207,358	 2,299,527,168	InnoDB	2024-01-18 14:20:36	 2024-02-06 19:50:35	utf8mb4_unicode_ci	0.6
    #                        moodle	mdl_grade_grades_history	     3,002,327	 1,545,175,040	InnoDB	2024-01-18 13:16:57	 2024-02-06 19:49:13	utf8mb4_unicode_ci	0.8
    #                        moodle	mdl_question_attempts	         1,653,458	 3,970,580,480	InnoDB	2024-01-18 14:25:51	 2024-02-06 19:50:35	utf8mb4_unicode_ci	0.2'

    #FiveLargestTablesSQL="SELECT TABLE_SCHEMA,TABLE_NAME,FORMAT(TABLE_ROWS,0),(DATA_LENGTH+INDEX_LENGTH),ENGINE,CREATE_TIME,UPDATE_TIME,TABLE_COLLATION,ROUND((DATA_FREE/DATA_LENGTH)*100.0,1) FROM information_schema.TABLES ORDER BY TABLE_ROWS DESC LIMIT 5;"
    # Ex: FiveLargestTables='moodle   mdl_question_attempt_step_data  54,183,632  25,593   InnoDB  2024-01-18 13:50:02   2024-01-28 10:27:07  utf8mb4_unicode_ci  0.0
    #                        moodle   mdl_logstore_standard_log       23,284,656  11,398   InnoDB  2024-01-18 13:20:30   2024-01-28 10:27:09  utf8mb4_unicode_ci  0.1
    #                        moodle   mdl_question_attempt_steps      11,190,335   2,193   InnoDB  2024-01-18 14:20:36   2024-01-28 10:27:07  utf8mb4_unicode_ci  0.6
    #                        moodle   mdl_grade_grades_history         3,000,117   1,474   InnoDB  2024-01-18 13:16:57   2024-01-28 10:26:57  utf8mb4_unicode_ci  1.3
    #                        moodle   mdl_question_attempts            1,650,937   3,787   InnoDB  2024-01-18 14:25:51   2024-01-28 10:27:07  utf8mb4_unicode_ci  0.1'
    #                        Schema   table_name                    ∑_table_rows  ∑_size   Engine  Created               Updated              Collation           Fragmentation

    FiveLargestTables="$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NB -e "$FiveLargestTablesSQL")"
    # Create the table part:
    DatabaseTblString+="        <tr><td colspan=\"2\">The five largest tables:
        <table>
            <tr><td><b>Database</b></td><td><b>Table Name</b></td><td><b>Nbr. of rows</b>&nbsp;&#8595;</td><td align=\"right\"><b>&sum; size [B]</b></td><td><b>Disk use</b></td><td><b>Fragm.</b></td><td><b>Collation</b></td><td><b>Created</b></td><td><b>Updated</b></td><td><b>Storage engine</b></td></tr>$NL"
    while read TableSchema TableName SumRows SumSize StorageEngine Created Updated Collation Fragmentation
    do
        #case "${StorageEngine,,}" in
        #    "innodb" ) Extension="[Ii][Bb][Dd]";;
        #    "aria" )   Extension="[Mm][Aa][Ii]";;
        #    "myisam" ) Extension="[Mm][Yy][Dd]";;
        #esac
        TableDiskVolumeB="$(ls -ls $DB_ROOT/$TableSchema/${TableName}* | awk '{sum+=$6} END {print sum}')"               # Ex: TableDiskVolumeB=27816625772
        #TableDiskVolume="$(du -skh $DB_ROOT/$TableSchema/${TableName}."Extension" 2>/dev/null | awk '{print $1}' | sed 's/K/ KiB/;s/M/ MiB/;s/G/ GiB/')"     # Ex: TableDiskVolume='3.9 GiB'
        TableDiskVolume="$(numfmt --to=iec-i --suffix=B --format="%9.1f" $TableDiskVolumeB 2>/dev/null | sed 's/K/ K/;s/M/ M/;s/G/ G/;s/^ *//')"     # Ex: TableDiskVolume='26.0 GiB'
        if [ -z "$TableDiskVolume" ]; then
            TableDiskVolume="$(numfmt --to=iec-i --suffix=B --format="%9f" $TableDiskVolumeB 2>/dev/null | sed 's/K/ K/;s/M/ M/;s/G/ G/;s/^ *//')"   # Ex: TableDiskVolume='26 GiB'
        fi
        #Size="$(numfmt --to=iec-i --suffix=B --format="%9.1f" $SumSize 2>/dev/null | sed 's/K/ K/;s/M/ M/;s/G/ G/;s/^ *//')"                         # Ex: Size='25.0 GiB'
        #if [ -< "$Size" ]; then
        #    Size="$(numfmt --to=iec-i --suffix=B --format="%9f" $SumSize 2>/dev/null | sed 's/K/ K/;s/M/ M/;s/G/ G/;s/^ *//')"
        #fi
        DatabaseTblString+="            <tr><td><code>$TableSchema</code></td><td><code>$TableName</code></td><td align=\"right\">$SumRows</td><td align=\"right\">$SumSize</td><td align=\"right\">$TableDiskVolume</td><td align=\"right\">$(printf "%'.1f" $Fragmentation)%</td><td>$Collation</td><td>${Created/_/ }</td><td>${Updated/_/ }</td><td>$StorageEngine</td></tr>$NL"
    done <<< "$(echo "$FiveLargestTables" | sed 's/ /_/g')"
    DatabaseTblString+="        </table><br><i>Table size = DATA_LENGTH + INDEX_LENGTH,&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Fragmentation = DATA_FREE / DATA_LENGTH</i><br>
        <i>NOTE: the information above comes from <code>information_schema</code> and is not entirely accurate!</i></td></tr>"


    Port=$($SQLCommand -u$SQLUser -p"$DATABASE_PASSWORD" -NBe "SHOW VARIABLES LIKE 'port';" | awk '{print $2}')      # Ex: Port=3306
    if [ -x /bin/lsof ]; then
        OpenSQLPorts="$(/bin/lsof -i:$Port)"
    elif [ -x /sbin/lsof ]; then
        OpenSQLPorts="$(/sbin/lsof -i:$Port)"
    fi
    # Ex: OpenSQLPorts='COMMAND    PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    #                   docker-pr 1629 root    4u  IPv4  38869      0t0  TCP *:mysql (LISTEN)
    #                   docker-pr 1639 root    4u  IPv6  38877      0t0  TCP *:mysql (LISTEN)'

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
        RunningDaemonPID="$(echo "$RunningDaemonLine" | awk '{print $2}')"                                            # Ex: RunningDaemonPID=58310
        RunningDaemonMemRSS="$(ps --no-headers -o rss:8 $RunningDaemonPID | awk '{print $1/1024}' | cut -d\. -f1)"    # Ex: RunningDaemonMemRSS=398
        RunningDaemonMemVSZ="$(ps --no-headers -o vsz:8 $RunningDaemonPID | awk '{print $1/1024}' | cut -d\. -f1)"    # Ex: RunningDaemonMemVSZ=1920
        RunningDaemonPPID="$(echo "$RunningDaemonLine" | awk '{print $3}')"                                           # Ex: RunningDaemonPPID=58288
        RunningDaemonPPIDCommand="$(ps -p $RunningDaemonPPID -o cmd= 2>/dev/null | awk '{print $1}')"                 # Ex: RunningDaemonPPIDCommand=/usr/bin/containerd-shim-runc-v2
        if [ -n "$(echo "$RunningDaemonPPIDCommand" | grep -Eo "containerd")" ]; then
            Dockers="$(docker ps | grep -Ev "^CONTAINER" | awk '{print $NF}')"
            # Ex: Dockers='moodledb
            #              moodleweb'
            while read DOCKER
            do
                if [ -n "$(docker top $DOCKER | grep -E "\b$RunningDaemonPID\b")" ]; then
                    RunningDocker="$DOCKER"                                                                           # Ex: RunningDocker=moodledb
                    RunningDockerStr="&nbsp;<i>(running inside docker <code>$RunningDocker</code>)</i>"
                    break
                fi
            done <<< "$Dockers"
        fi
        RunningDaemonUID="$(echo "$RunningDaemonLine" | awk '{print $1}')"                                            # Ex: RunningDaemonUID=999
        RunningDaemonUser="$(/bin/getent passwd "$RunningDaemonUID" | cut -d: -f1)"                                   # Ex: RunningDaemonUser=systemd-coredump
        RunningDaemonName="$(/bin/getent passwd "$RunningDaemonUID" | cut -d: -f5)"                                   # Ex: RunningDaemonName='systemd Core Dumper'
        RunningDaemon="$(echo "$RunningDaemonLine" | awk '{print $NF}')"                                              # Ex: RunningDaemon=mariadbd
        RunningDaemonSecs="$(ps -p $RunningDaemonPID -o etimes= 2>/dev/null)"                                         # Ex: RunningDaemonSecs=' 112408'
        RunningDaemonTimeH="$(time_convert $RunningDaemonSecs | sed 's/ [0-9]* sec$//')"                              # Ex: RunningDaemonTimeH='1 days 9 hours 19 min'
        #RunningDaemonStartTime="$(ps -p $RunningDaemonPID -o lstart=)"                                                # Ex: RunningDaemonStartTime='Mon Jan 29 07:43:45 2024'
        RunningDaemonStartTime="$(date +%F" "%T -d @"$(($(date +%s) - $(ps -p $RunningDaemonPID -o etimes=)))")"      # Ex: RunningDaemonStartTime='2024-01-29 07:43:45'
    fi
    UptimeSince="$(uptime -s)"                                                                                    # Ex: UptimeSince='2024-01-29 04:06:33'

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
            DaemonInfoStr+="        <tr><td><code>systemctl&nbsp;</code>:</td><td><pre>$SystemctlStatus</pre></td></tr>$NL"
        fi
    fi
}


get_last_known_good_data() {
    LastRunFileDatetime="$(stat --format %x "$LastRunFile" | sed 's/\.[0-9]*//')"                  # Ex: LastRunFileDatetime='2024-02-07 08:55:05 +0100'
    echo "        </tbody>" >> $EmailTempFile
    echo "    </table>" >> $EmailTempFile
    echo "    <p>&nbsp;</p>" >> $EmailTempFile
    echo "	  <p>&nbsp;</p>" >> $EmailTempFile
    echo "	  <h1 align=\"center\" style=\"color: red\">Last known good data</h1>" >> $EmailTempFile
    echo "	  <p align=\"center\" style=\"color: red\">Date: $LastRunFileDatetime</p>" >> $EmailTempFile
    echo "	  <p>&nbsp;</p>" >> $EmailTempFile
    echo "	  <table id=\"jobe\">" >> $EmailTempFile
    echo "		  <tbody>" >> $EmailTempFile
    cat "$LastRunFile" >> $EmailTempFile
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
    curl --silent $ReportHead | sed "s/SERVER/$ServerName/;s/DATE/$(date +%F)/;$CSS_colorfix;s/Backup/SQL/;s/1200/1250/" >> $EmailTempFile
    # Only continue if it worked
    if grep "SQL report for" $EmailTempFile &>/dev/null ; then
        echo "<body>" >> $EmailTempFile
        echo '<div class="main_page">' >> $EmailTempFile
        echo '  <div class="flexbox-container">' >> $EmailTempFile
        echo '    <div id="box-header">' >> $EmailTempFile
        echo "      <h3>SQL report for</h3>" >> $EmailTempFile
        echo "      <h1>$ServerName</h1>" >> $EmailTempFile
        echo "      <h4>$(date "+%Y-%m-%d %T %Z")</h4>" >> $EmailTempFile
        echo "    </div>" >> $EmailTempFile
        echo "  </div>" >> $EmailTempFile
        echo "  <section>" >> $EmailTempFile
        echo "    <p>&nbsp;</p>" >> $EmailTempFile
        echo "    <p align=\"left\"> Report generated by script: <code>${ScriptFullName}</code><br>" >> $EmailTempFile
        echo "      Script launched $ScriptLaunchText by: <code>${ScriptLauncher:---no launcher detected--}</code> </p>" >> $EmailTempFile
        echo '    <p align="left">&nbsp;</p>' >> $EmailTempFile
        echo '    <p align="left">&nbsp;</p>' >> $EmailTempFile
        echo '    <h1 align="center">R u n n i n g&nbsp;&nbsp;&nbsp;&nbsp;i n s t a n c e</h1>' >> $EmailTempFile
        echo '    <p>&nbsp;</p>' >> $EmailTempFile
        echo '    <table id="jobe">' >> $EmailTempFile
        echo "      <tbody>" >> $EmailTempFile
        echo "$DaemonInfoStr" >> $EmailTempFile
        if [ -n "$RunningDaemonLine" ]; then
            echo "$DBCheckString" >> $EmailTempFile
            echo "$DatabaseTblString" >> $EmailTempFile
            echo '      </tbody>' >> $EmailTempFile
            echo '    </table>' >> $EmailTempFile
            echo '    <p>&nbsp;</p>' >> $EmailTempFile
            echo '    <p>&nbsp;</p>' >> $EmailTempFile
            echo '    <h1 align="center">D a t a b a s e&nbsp;&nbsp;&nbsp;&nbsp;s e t t i n g s</h1>' >> $EmailTempFile
            echo '    <p>&nbsp;</p>' >> $EmailTempFile
            echo '    <table id="jobe">' >> $EmailTempFile
            echo '      <tbody>' >> $EmailTempFile
            echo "$MainReplicaString" >> $EmailTempFile
            echo "$SQLUsersTablePart" >> $EmailTempFile
            echo "$StorageEngineStr" >> $EmailTempFile
            echo "$SQLVariableStr" >> $EmailTempFile
            echo "$SQLStatusStr" >> $EmailTempFile
        else
            get_last_known_good_data
        fi
        echo "      </tbody>" >> $EmailTempFile
        echo "    </table>" >> $EmailTempFile
        echo "  </section>" >> $EmailTempFile
        echo '  <p align="center"><em>Report generated by &#8220;sql-info&#8221; (<a href="https://github.com/Peter-Moller/sql-info" target="_blank" rel="noopener noreferrer">GitHub</a> <span class="glyphicon">&#xe164;</span>)</em></p>' >> $EmailTempFile
        echo '  <p align="center"><em>Department of Computer Science, LTH/LU</em></p>' >> $EmailTempFile
        echo "</div>" >> $EmailTempFile
        echo "</body>" >> $EmailTempFile
        echo "</html>" >> $EmailTempFile
    else
        echo "<body>" >> $EmailTempFile
        echo "<h1>Could not get $ReportHead!!</h1>"
        echo "</body>" >> $EmailTempFile
        echo "</html>" >> $EmailTempFile
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
    else
        Status="SQL info for $ServerName"
    fi

    # Set the headers in order to use sendmail
    echo "To: $Recipient" >> $EmailTempFile
    echo "Subject: $Status" >> $EmailTempFile
    echo "Content-Type: text/html" >> $EmailTempFile
    echo "" >> $EmailTempFile

    # Create the html content
    assemble_web_page

    if [ -n "$Recipient" ]; then
        cat $EmailTempFile | /sbin/sendmail -t
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
    get_sql_variables

    get_sql_status

    get_sql_users

    get_storage_engines

    do_mariadb_check

    get_database_overview

    echo "$DaemonInfoStr$NL$DatabaseTblString" > "$LastRunFile"
fi

email_html_create_send

copy_result

rm $EmailTempFile
