#!/bin/bash
# Define color codes
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
# Log
TS=$(date '+%Y%m%d_%H%M%S')
OUTPUT_FILE="Validation_Checks_$TS.log"
exec > >(tee -a "$OUTPUT_FILE") 2>/dev/null
# Load environment variables
[ -f "$HOME/.profile" ] && . "$HOME/.profile"  >/dev/null 2>&1 || true
#########################################################################################################################################
# --- Validate argument ---
if [[ $# -ne 1 ]]; then
  echo -e "${RED}|==> [FAIL]:${NC}Usage: $0 <health_check.conf>"
  exit 1
fi

CONFIG_FILE="$1"

# --- Validate config file ---
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "${RED}|==> [FAIL]:${NC}File not found: $CONFIG_FILE"
  exit 1
fi

source "$CONFIG_FILE"

# --- Optional: validate required variables ---
REQUIRED_VARS=(
MIN_ATA_HOME_FREE_PCT
MIN_TMP_FREE_PCT
MIN_MEM_AVAILABLE_PCT
MAX_TNSPING_LATENCY_MS
MAX_TABLESPACE_USED_PCT
ORASQL_EXEC_LIMIT
)

for var in "${REQUIRED_VARS[@]}"; do
  value="${!var}"
  # Check if variable is set and not empty 
  if [[ -z "$value" ]]; then
    echo -e "${RED}|==> [FAIL]:${NC}Variable '$var' is not set in config file"
    exit 1
  fi
   # Check if value is numeric (0–9 only)
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}|==> [FAIL]:${NC}Variable '$var' must contain only numeric values (0–9). Current value: '$value'"
    exit 1 
  fi
done
#Counters
WARN_FOUND=0
FAIL_FOUND=0
PASS_FOUND=0
TOTAL_CHECKS=0
TOTAL_FAIL_FOUND=0
TOTAL_WARN_FOUND=0
TOTAL_PASS_FOUND=0
TOTAL_TOTAL_CHECKS=0
##########################################################################################################################################
sv_user=$USER
# Functions
finished_script() {
echo -e "\n-------------------------------------------\nProcess ended: $(date)\n-------------------------------------------\n"
}
# Starting Script
echo -e "\n\n---------------------------------------------\nProcess started: $(date)\n---------------------------------------------\n"
echo -e "Pre- and Post-Deployment Validations\nENVIRONMENT USERNAME: ${sv_user}\nORACLE_SID: ${ORACLE_SID}"
echo -e "\nHealth Check Result Indicators:"
echo -e "${RED}|==> [FAIL]:${NC} Review required - please investigate and remediate."
echo -e "${YELLOW}|==> [WARN]:${NC} Verification needed - please confirm accuracy."
echo -e "${GREEN}|==> [PASS]:${NC} Output validated - results meet expected criteria.\n"
# Go through every single instance
instances_array=($(da_dump InstanceStatus | sed -n 1!p | awk -F '"*,"*' '{print $24}'))
for ((i=0; i<${#instances_array[@]}; i++)); do
# Servername InstanceStatus
    host="${instances_array[$i]}"
# HA is Active?    
    HA=$(env | grep 'HA_ACTIVE=1' | wc -l)
    if [ "$HA" -eq "1" ]; then
    	sv_ha=1
    else
    	sv_ha=0
    fi
# SV Instance Type
    if [ "${#instances_array[@]}" -eq 1 ]; then
    	sv_type=1
    else
    	if [ "$i" -eq 0 ]; then
        	sv_type=2
       	else
        	sv_type=3
        fi
   	fi

# Pass variables, execute ksh.
while read -r tag w f p t; do
  echo "$tag $w $f $p $t"

  [[ "$tag" != "__FOR_INSTANCE__" ]] && continue

  REMOTE_WARN_FOUND=${w#WARN_FOUND=}
  REMOTE_FAIL_FOUND=${f#FAIL_FOUND=}
  REMOTE_PASS_FOUND=${p#PASS_FOUND=}
  REMOTE_TOTAL_CHECKS=${t#TOTAL_CHECKS=}

done < <(
    ssh "$sv_user@$host" 'ksh -s' -- "$sv_type" "$i" "$host" "$sv_ha" "$MIN_ATA_HOME_FREE_PCT" "$MIN_TMP_FREE_PCT" "$MIN_MEM_AVAILABLE_PCT" "$MAX_TNSPING_LATENCY_MS" "$MAX_TABLESPACE_USED_PCT" "$ORASQL_EXEC_LIMIT" <<'REMOTE_KSH'
[ -f "$HOME/.profile" ] && . "$HOME/.profile"  >/dev/null 2>&1 || true
# Remote side (ksh)
set -u
# Receive arguments
sv_type="$1"
i="$2"
instance="$3"
sv_ha="$4"
MIN_ATA_HOME_FREE_PCT="$5"
MIN_TMP_FREE_PCT="$6"
MIN_MEM_AVAILABLE_PCT="$7"
MAX_TNSPING_LATENCY_MS="$8"
MAX_TABLESPACE_USED_PCT="$9"
ORASQL_EXEC_LIMIT="${10}"

# Define color codes
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

#Counters
WARN_FOUND=0
FAIL_FOUND=0
PASS_FOUND=0
TOTAL_CHECKS=0

print_counters() {
  print "__FOR_INSTANCE__ WARN_FOUND=${WARN_FOUND} FAIL_FOUND=${FAIL_FOUND} PASS_FOUND=${PASS_FOUND} TOTAL_CHECKS=${TOTAL_CHECKS}"
}
trap print_counters EXIT

# Functions
####
run_sv1_wihoutHA() {
    
    typeset MAX_TABLESPACE_USED_PCT="$1"
    typeset sv_type="$2"
    ###
    
if [ "$sv_type" -eq 2 ]; then  
    output=$(sv_status -cluster 2>&1 | tail -n +2)
    while read -r line; do
    # Alert conditions
        if ( [ "$line" = 'Server is in an unknown state. Tuxedo is running, but no BBL process exists on the server.' ] ||
            [ "$line" = 'CB Server NOT RUNNING.' ] ||
            [ "$line" = 'NO server running' ] ||
            [ "$line" = 'Server Common Processes RUNNING' ] ||
            [ "$line" = 'Server is STARTING UP.' ] ||
            [ "$line" = 'Server is SHUTTING DOWN.' ] ||
            [ "$line" = 'Unknown.' ] ); then
            print "${RED}|==> [FAIL][sv_status -cluster]:CB ERROR:${NC}[ $line]"
            ((FAIL_FOUND+=1))
            ((TOTAL_CHECKS+=1))
        fi
    done <<< "$output"
    ###
    output=$(sv_status -cluster | grep -e 'PE Server')
    while read -r line; do
        Active=$(echo "$line" | awk '{print $7}')
        Standby=$(echo "$line" | awk '{print $9}')
        RESTRICTED=$(echo "$line" | awk '{print $5}')
        if [ "$line" = 'PE Server NOT RUNNING.' ]; then
            print "${RED}|==> [FAIL]:[(sv_status -cluster]:PE Error:${NC}[ $line]"
            ((FAIL_FOUND+=1))
            ((TOTAL_CHECKS+=1))
        fi
        if [ "$Active" = 'Active' ] || [ "$Standby" = 'Standby' ] && [ "$RESTRICTED" != 'RESTRICTED' ]  ; then
            print "${GREEN}|==> [PASS]:[sv_status -cluster]:${NC}[ $line]"
            ((PASS_FOUND+=1))
            ((TOTAL_CHECKS+=1))
        fi
        if [ "$RESTRICTED" = 'RESTRICTED' ]; then
            print "${RED}|==> [FAIL]:[sv_status -cluster]:${NC}PE Error:[ $line]"
            ((FAIL_FOUND+=1))
            ((TOTAL_CHECKS+=1))
        fi
    done <<< "$output"  
    ###
 	# Get all rows where last column = 1
	enabled_rows=$(cfg STD -l ENABLED | awk 'NF>=3 && $NF==1 {print $1, $2}')
	rc=$?
	if [ "$rc" -ne 0 ]; then
    	print "${RED}|==> [FAIL]:[Validate STD process is active]:${NC}[Unable to run 'cfg STD -l ENABLED' (rc=$rc)]"
        ((FAIL_FOUND+=1))
        ((TOTAL_CHECKS+=1))
	else
    	count=$(printf "%s\n" "$enabled_rows" | wc -l | tr -d ' ')
    	case "$count" in
	        0)
            	print "${RED}|==> [FAIL]:[Validate STD process is active]:${NC}[No STD enabled]"
                ((FAIL_FOUND+=1))
                ((TOTAL_CHECKS+=1))
            	;;
      		1)
            	# Exactly one: extract index and STD name
            	read idx stdname <<EOF
$enabled_rows
EOF
            	# Get instance name
            	instance=$(cfg STD "$idx" INSTANCE | awk 'NF>0 {print $1; exit}')
            	# Check if Standby
            	if sv_status "$instance" | grep -q 'Standby'; then
                	print "${YELLOW}|==> [WARN]:[Validate STD process is active]:${NC}[STD running in Standby PE Node $instance]"
                    ((WARN_FOUND+=1))
                    ((TOTAL_CHECKS+=1))
           	 	else
                	print "${GREEN}|==> [PASS]:[Validate STD process is active]:${NC}[STD running in $instance, not on the first deployment node (Standby PE node)]"
                    ((PASS_FOUND+=1))
                    ((TOTAL_CHECKS+=1))
            	fi
            	;;
        	*)
            	print "${RED}|==> [FAIL]:[Validate STD process is active]:${NC}[More than one STD enabled]"
                ((FAIL_FOUND+=1))
                ((TOTAL_CHECKS+=1))
            	printf "%s\n" "$enabled_rows"
            	;;
    	esac
	fi
 ###
fi    
    output=$(cbtasks 2>&1 | grep 'No tasks.' | wc -l)
    if [ "$output" -eq "1" ]; then
        print "${GREEN}|==> [PASS]:[cbtasks]${NC}:[ No tasks.]"
        ((PASS_FOUND+=1))
        ((TOTAL_CHECKS+=1))
    else
        print "${YELLOW}|==> [WARN]:[cbtasks]${NC}:[ CB tasks found. Please validate.]"
        ((WARN_FOUND+=1))
        ((TOTAL_CHECKS+=1))
        cbtasks 2>&1 | grep -v PX | awk 'NR>1'
    fi
    ###
    output=$(orasize | awk -v t="$MAX_TABLESPACE_USED_PCT" '
        NF >= 8 &&
        $(NF-1) ~ /^[0-9.]+$/ &&
        $1 != "Total" &&
        $1 !~ /^-+/ &&
        $0 !~ /TEMP/ {
        used = 100 - $(NF-1)
        if (used > t) {
            printf "%-25s Used=%5.1f%%\n", $1, used
            fail = 1
            }
        }
        END { exit fail }
    ')
    rc=$?
    if [ "$rc" -eq 0 ]; then
        print "${GREEN}|==> [PASS]:[Database storage utilization]:${NC}[ Tablespace usage is healthy and below ${MAX_TABLESPACE_USED_PCT}% ]"
        ((PASS_FOUND+=1))
        ((TOTAL_CHECKS+=1))
    else
        print "${YELLOW}|==> [WARN]:[Database storage utilization]:${NC}[  Tablespaces above ${MAX_TABLESPACE_USED_PCT}% ]"
        ((WARN_FOUND+=1))
        ((TOTAL_CHECKS+=1))
        print "$output"
    fi
    ###
	output=$(dbverify 2>&1)
    if echo "$output" | grep -q 'table.diff'; then
    	diff_line=$(echo "$output" | grep 'table.diff')
    	print "${RED}|==> [FAIL]:[dbverify]:${NC}:[$diff_line]"
        ((FAIL_FOUND+=1))
        ((TOTAL_CHECKS+=1))
    else
   	    print "${GREEN}|==> [PASS]:[dbverify]:${NC}:[No 'table.diff' found]"
        ((PASS_FOUND+=1))
        ((TOTAL_CHECKS+=1))
	fi
    output=$(orasql -e $ORASQL_EXEC_LIMIT 2>&1)
    if echo "$output" | grep -q 'No matching active SQL!!'; then
    	diff_line=$(echo "$output" | grep 'No matching active SQL!!')
    	print "${GREEN}|==> [PASS]:[orasql -e $ORASQL_EXEC_LIMIT]:${NC}:[$diff_line]"
        ((PASS_FOUND+=1))
        ((TOTAL_CHECKS+=1))
	else
   		print "${YELLOW}|==> [WARN]:[orasql -e $ORASQL_EXEC_LIMIT]:${NC}:[Queries found that have been executing for $ORASQL_EXEC_LIMIT seconds or more. Please check]"
        ((WARN_FOUND+=1))
        ((TOTAL_CHECKS+=1))
	fi
    ###         
    ztables=$(sqlplus -S "$ATADBACONNECT" <<EOF
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET VERIFY OFF
SET LINESIZE 32000
SET TIMING OFF
SELECT table_name FROM all_tables WHERE table_name LIKE 'Z%';
EXIT
EOF
)
    # Remove empty lines and normalize
    ztables=$(echo "$ztables" | awk 'NF')
    if [ -z "$ztables" ]; then
        print "${GREEN}|==> [PASS]:[ztables check]:${NC}[  No tables starting with 'Z' were found]"
        ((PASS_FOUND+=1))
        ((TOTAL_CHECKS+=1))
    else
        count=$(echo "$ztables" | wc -l | tr -d ' ')
        print "${RED}|==> [FAIL]:[ztables check]:${NC}[Found $count table(s) starting with 'Z']"
        ((FAIL_FOUND+=1))
        ((TOTAL_CHECKS+=1))
        print "[ztables Found:]"
        echo "$ztables"
    fi
    ###
	debug_check=$(sqlplus -S "$ATADBACONNECT" <<EOF
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET VERIFY OFF
SET LINESIZE 32767
SET TRIMSPOOL ON
SET TIMING OFF

SELECT
       cit.configuration_item_type_name || '|' ||
       ci.configuration_item_name || '|' ||
       cat.configuration_attr_name || '|' ||
       ca.value
FROM configuration_attribute ca
JOIN configuration_attr_type cat USING (configuration_attr_type_id)
JOIN configuration_item ci USING (configuration_item_id)
JOIN configuration_item_type cit
  ON ci.configuration_item_type_id = cit.configuration_item_type_id
WHERE
      cit.configuration_item_type_name <> 'FTS'
  AND (
        (cat.configuration_attr_name LIKE '%DEBUG%'
         AND ca.value IS NOT NULL
         AND ca.value <> '0')
     OR (cat.configuration_attr_name = 'COMMAND_LINE_ARGS'
         AND ca.value LIKE '%-d%')
      )
ORDER BY
       cit.configuration_item_type_name,
       ci.configuration_item_name,
       cat.configuration_attr_name;

EXIT;
EOF
)
    # Remove empty lines
	debug_check=$(print -- "$debug_check" | awk 'NF')
	if [[ -z "$debug_check" ]]; then
    	print -- "${GREEN}|==> [PASS]:[Conf. Items Debug check]:${NC}[No configuration items with debug enabled found]"
        ((PASS_FOUND+=1))
        ((TOTAL_CHECKS+=1))
	else
   		count=$(print -- "$debug_check" | wc -l | tr -d ' ')
    	print -- "${RED}|==> [FAIL]:[Conf. Items Debug check]:${NC}[Found $count configuration items with debug enabled]"
        ((FAIL_FOUND+=1))
        ((TOTAL_CHECKS+=1))
        print ""
    	# Print header + formatted rows
    	print -- "$debug_check" | awk -F'|' '
    	BEGIN {
        	printf "%-25s %-35s %-30s %-20s\n", \
            "CONFIGURATION_ITEM_TYPE_NAME", \
            "CONFIGURATION_ITEM_NAME", \
            "CONFIGURATION_ATTR_NAME", \
            "VALUE"
        	printf "%-25s %-35s %-30s %-20s\n", \
            "--------------------------", \
            "-----------------------------------", \
            "------------------------------", \
            "--------------------"
    		}
    	{
        	printf "%-25s %-35s %-30s %-20s\n", $1, $2, $3, $4
    	}'
	fi
}
####
run_svx(){
typeset svi="$1"
typeset sv_host="$2"
typeset MIN_ATA_HOME_FREE_PCT="$3"
typeset MIN_TMP_FREE_PCT="$4"
typeset MIN_MEM_AVAILABLE_PCT="$5"
typeset MAX_TNSPING_LATENCY_MS="$6"
typeset dir_req=$ATA_HOME
typeset dir_tmp=/tmp
###
output=$(svstatus 2>&1)
while read -r line; do
error=$(echo "$line" | awk '{print $1}' | cut -c1-2)
if [ "$error" = '<E' ] || [ "$error" = '<W' ]; then
        print "${RED}|==> [FAIL]:[svstatus]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[$line]"
        ((FAIL_FOUND+=1))
        ((TOTAL_CHECKS+=1))
else
        if [ "$line" = '<S90003> Singleview is running' ]; then
        print "${GREEN}|==> [PASS]:[svstatus]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[$line]"
        ((PASS_FOUND+=1))
        ((TOTAL_CHECKS+=1))
        fi
fi
done <<< "$output"
sv_output=$(sv_status | tail -n +3)
print -- "$sv_output"
###
output=$(cache_check 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    print "${RED}|==> [FAIL]:[cache_check]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[Error executing cache_check (rc=$rc)]"
    ((FAIL_FOUND+=1))
    ((TOTAL_CHECKS+=1))
    printf "%s\n" "$output"
else
    error_lines=$(printf "%s\n" "$output" | grep '<E')
    if [ -n "$error_lines" ]; then
        print "${RED}|==> [FAIL]:[cache_check]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[Found error(s)]"
        ((FAIL_FOUND+=1))
        ((TOTAL_CHECKS+=1))
        printf "%s\n" "$error_lines"
    else
        print "${GREEN}|==> [PASS]:[cache_check]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[SV cache check is OK]"
        ((PASS_FOUND+=1))
        ((TOTAL_CHECKS+=1))
    fi
fi
###
set -- $(df -BG -P "$dir_req" | awk 'NR==2 {
    gsub("G","",$2);   # total
    gsub("G","",$4);   # available
    gsub("%","",$5);   # used%
    print $2, $4, 100-$5
}')

total_gb=$1
avail_gb=$2
free_pct=$3

req_gb=$(( total_gb * MIN_ATA_HOME_FREE_PCT / 100 ))

if (( free_pct < MIN_ATA_HOME_FREE_PCT )); then
    print "${YELLOW}|==> [WARN]:[\$ATA_HOME directory]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[${dir_req}. Free space required:${MIN_ATA_HOME_FREE_PCT}%(${req_gb}GB). Free space available:${free_pct}%(${avail_gb}GB).]"
    ((WARN_FOUND+=1))
    ((TOTAL_CHECKS+=1))
else
    print "${GREEN}|==> [PASS]:[\$ATA_HOME directory]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[${dir_req}. Free space required:${MIN_ATA_HOME_FREE_PCT}%(${req_gb}GB). Free space available:${free_pct}%(${avail_gb}GB).]"
    ((PASS_FOUND+=1))
    ((TOTAL_CHECKS+=1))
fi
###
set -- $(df -BG -P "$dir_tmp" | awk 'NR==2 {
    gsub("G","",$2);   # total
    gsub("G","",$4);   # available
    gsub("%","",$5);   # used%
    print $2, $4, 100-$5
}')

total_gb=$1
avail_gb=$2
free_pct=$3

req_gb=$(( total_gb * MIN_TMP_FREE_PCT / 100 ))

if (( free_pct < MIN_TMP_FREE_PCT )); then
    print "${YELLOW}|==> [WARN]:[/tmp directory]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[${dir_tmp}. Free space required:${MIN_TMP_FREE_PCT}%(${req_gb}GB). Free space available:${free_pct}%(${avail_gb}GB).]"
    ((WARN_FOUND+=1))
    ((TOTAL_CHECKS+=1))
else
    print "${GREEN}|==> [PASS]:[/tmp directory]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[${dir_tmp}. Free space required:${MIN_TMP_FREE_PCT}%(${req_gb}GB). Free space available:${free_pct}%(${avail_gb}GB).]"
    ((PASS_FOUND+=1))
    ((TOTAL_CHECKS+=1))
fi
###
set -- $(free -g | awk '/^Mem:/ {
    print $2, $7
}')
total_mem_gb=$1
avail_mem_gb=$2
if [[ -z "$total_mem_gb" || -z "$avail_mem_gb" ]]; then
  print "${RED}|==> [FAIL]:[Memory]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[ ERROR: Unable to determine memory values ]"
  ((FAIL_FOUND+=1))
  ((TOTAL_CHECKS+=1))
fi
avail_mem_pct=$(( avail_mem_gb * 100 / total_mem_gb ))
req_mem_gb=$(( total_mem_gb * MIN_MEM_AVAILABLE_PCT / 100 ))

if (( avail_mem_pct < MIN_MEM_AVAILABLE_PCT )); then
  print "${YELLOW}|==> [WARN]:[Memory]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[ Free memory required:${MIN_MEM_AVAILABLE_PCT}%(${req_mem_gb}GiB). Free memory available:${avail_mem_pct}%(${avail_mem_gb}GiB). ]"
  ((WARN_FOUND+=1))
  ((TOTAL_CHECKS+=1))
else
  print "${GREEN}|==> [PASS]:[Memory]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[ Free memory required:${MIN_MEM_AVAILABLE_PCT}%(${req_mem_gb}GiB). Free memory available:${avail_mem_pct}%(${avail_mem_gb}GiB). ]"
  ((PASS_FOUND+=1))
  ((TOTAL_CHECKS+=1))
fi
###
# Run tnsping silently and extract msec
msec=$(tnsping "$ORACLE_SID" 2>/dev/null | awk -F'[()]' '/msec/ {print $2}' | awk '{print $1}')
if [ -z "$msec" ] || ! echo "$msec" | grep -q '^[0-9][0-9]*$'; then
  print "${RED}|==> [FAIL]:[tnsping $ORACLE_SID]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[ Invalid or missing TNS ping value: '$msec']"
  ((FAIL_FOUND+=1))
  ((TOTAL_CHECKS+=1))
else
  if [ "$msec" -gt "$MAX_TNSPING_LATENCY_MS" ]; then
    print "${YELLOW}|==> [WARN]:[tnsping $ORACLE_SID]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[ TNS ping ${msec} ms (threshold ${MAX_TNSPING_LATENCY_MS} ms)]"
    ((WARN_FOUND+=1))
    ((TOTAL_CHECKS+=1))
  else
    print "${GREEN}|==> [PASS]:[tnsping $ORACLE_SID]:${NC}$(whoami):SV$((svi+1)):${sv_host}:[ TNS ping ${msec} ms (threshold ${MAX_TNSPING_LATENCY_MS} ms)]"
    ((PASS_FOUND+=1))
    ((TOTAL_CHECKS+=1))
  fi
fi
###
}

run_sv_healt_checks() {
    typeset sv_type="$1"
    typeset svi="$2"
    typeset sv_host="$3"
    typeset sv_ha="$4"
    typeset MIN_MEM_AVAILABLE_PCT="$5"
    typeset MAX_TNSPING_LATENCY_MS="$6"
    typeset MAX_TABLESPACE_USED_PCT="$7"
    typeset ORASQL_EXEC_LIMIT="$8"
    typeset key="${sv_type}_${sv_ha}"
    case "$key" in
        2_1)
            #|==> sv_type=2 sv_ha=1 Multi-Inst: Just SV1 multi-instance HA
            print "||======================================================================================================================================||"
            output=$(sv_ha_ctl cluster_status 2>&1 | grep 'No inactive resources' | wc -l)
            if [ "$output" -eq "1" ]; then
            	print "${GREEN}|==> [PASS]:[sv_ha_ctl cluster_status]${NC}:[ No inactive resources]"
                ((PASS_FOUND+=1))
                ((TOTAL_CHECKS+=1))
            else
                print "${RED}|==> [FAIL]:[sv_ha_ctl cluster_status]${NC}:[ Found inactive resources, please check]"
                ((FAIL_FOUND+=1))
                ((TOTAL_CHECKS+=1))
                sv_ha_ctl cluster_status 2>&1 | grep '* Node'
            fi    
            run_sv1_wihoutHA "$MAX_TABLESPACE_USED_PCT" "$sv_type"
            run_svx "$svi" "$sv_host" "$MIN_ATA_HOME_FREE_PCT" "$MIN_TMP_FREE_PCT" "$MIN_MEM_AVAILABLE_PCT" "$MAX_TNSPING_LATENCY_MS"
            ;;
        3_1)
            #|==> sv_type=3 sv_ha=1: Multi-Inst SVx
            print "||======================================================================================================================================||"
            run_svx "$svi" "$sv_host" "$MIN_ATA_HOME_FREE_PCT" "$MIN_TMP_FREE_PCT" "$MIN_MEM_AVAILABLE_PCT" "$MAX_TNSPING_LATENCY_MS"
            ;;
        #######################################################################
        1_0)
            #|==> sv_type=1 sv_ha=0: Single-Inst SV1
            print "||======================================================================================================================================||"
            run_sv1_wihoutHA "$MAX_TABLESPACE_USED_PCT" "$sv_type"
            run_svx "$svi" "$sv_host" "$MIN_ATA_HOME_FREE_PCT" "$MIN_TMP_FREE_PCT" "$MIN_MEM_AVAILABLE_PCT" "$MAX_TNSPING_LATENCY_MS"
            ;;
        2_0)
            #|==> sv_type=2 sv_ha=0: Just SV1 Multi-instance nonHA
            print "||======================================================================================================================================||"
            run_sv1_wihoutHA "$MAX_TABLESPACE_USED_PCT" "$sv_type"
            run_svx "$svi" "$sv_host" "$MIN_ATA_HOME_FREE_PCT" "$MIN_TMP_FREE_PCT" "$MIN_MEM_AVAILABLE_PCT" "$MAX_TNSPING_LATENCY_MS"
            ;;
        3_0)
            #|==> sv_type=3 sv_ha=0:  Multi-Inst: SVx
            print "||======================================================================================================================================||"
            run_svx "$svi" "$sv_host" "$MIN_ATA_HOME_FREE_PCT" "$MIN_TMP_FREE_PCT" "$MIN_MEM_AVAILABLE_PCT" "$MAX_TNSPING_LATENCY_MS"
            ;;
       ########################################################################
    esac
}
run_sv_healt_checks "$sv_type" "$i" "$instance" "$sv_ha" "$MIN_MEM_AVAILABLE_PCT" "$MAX_TNSPING_LATENCY_MS" "$MAX_TABLESPACE_USED_PCT" "$ORASQL_EXEC_LIMIT"

REMOTE_KSH  
) 

# Accumulate
((TOTAL_FAIL_FOUND+=REMOTE_FAIL_FOUND))
((TOTAL_PASS_FOUND+=REMOTE_PASS_FOUND))
((TOTAL_WARN_FOUND+=REMOTE_WARN_FOUND))
((TOTAL_TOTAL_CHECKS+=REMOTE_TOTAL_CHECKS))

done
echo " "
echo " "
echo -e "||======================================================================================================================================||"
echo -e "|==> SUMMARY: ${RED}FAIL:${NC} $TOTAL_FAIL_FOUND - ${YELLOW}WARN:${NC} $TOTAL_WARN_FOUND - ${GREEN}PASS:${NC} $TOTAL_PASS_FOUND == TOTAL CHECKS: $TOTAL_TOTAL_CHECKS"
if (( TOTAL_FAIL_FOUND >= 1 )); then
  echo -e "|==> The release cannot be installed. All detected failures must be resolved first (${RED}FAILURES:${NC} $TOTAL_FAIL_FOUND)"
else
    if (( TOTAL_WARN_FOUND >= 1 )); then
        echo -e "|==> Release installation can proceed; however, it is recommended to review ${YELLOW}WARN:${NC} $TOTAL_WARN_FOUND and resolve those deemed necessary before continuing."
    else
         echo -e "|==> Release can be installed. All pre- and post-release checks passed successfully."
    fi
fi
echo -e "||======================================================================================================================================||"
echo " "
echo " "
finished_script
