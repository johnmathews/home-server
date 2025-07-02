#!/bin/bash

# check each disk. If 
# - its an HDD not a SSD
# - its not in standby mode
# - its utilisaiton is above threshold for sample_duration
# then spin down the disk

# saved at /home/truenas_admin/spindown_hdds.sh
# run via a cron job in advanced settings UI.


# Colored output
if [[ -t 1 ]]; then
  BOLD=$(tput bold)
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  CYAN=$(tput setaf 6)
  RESET=$(tput sgr0)
else
  BOLD=""
  RED=""
  GREEN=""
  CYAN=""
  RESET=""
fi

LOG_FILE="$HOME/spindown.log"

SAMPLE_DURATION=30
UTIL_THRESHOLD=0.1

{
  echo "${CYAN}$(date) - Starting HDD spindown script${RESET}"
  echo "Utility threshold: $UTIL_THRESHOLD"
  for devpath in /dev/sd?; do
    devname=$(basename "$devpath")

    # Skip /dev/sda (boot/system disk)
    if [[ "$devname" == "sda" ]]; then
      echo "${RED}$devpath Skipping system disk${RESET}"
      continue
    fi

    # Check if rotational
    if [[ -f "/sys/block/$devname/queue/rotational" ]]; then
      is_rotational=$(< "/sys/block/$devname/queue/rotational")
      if [[ "$is_rotational" == "1" ]]; then

        # Check power state first to avoid unnecessary sampling
        current_state=$(sudo /sbin/hdparm -C "$devpath" 2>/dev/null | awk -F': ' '/drive state is/ {gsub(/^ +| +$/, "", $2); print $2}')
        if [[ -z "$current_state" ]]; then
          echo "${RED}$devpath Unable to determine power state, skipping${RESET}"
          continue
        fi

        if [[ "$current_state" == "standby" ]]; then
          echo "${CYAN}$devpath is already in standby mode – skipping${RESET}"
          continue
        fi

        # Sample utilization only if not already in standby
        echo "${CYAN}$devpath Sampling I/O activity for ${SAMPLE_DURATION}s...${RESET}"
        util=$(sudo iostat -d -x -y $SAMPLE_DURATION 2 | grep "^$devname" | tail -n1 | awk '{print $NF}')
        util=${util:-0.00}
        echo "$devpath utilization: $util%"

        if awk "BEGIN {exit !($util < $UTIL_THRESHOLD)}"; then
          echo "${BOLD}${GREEN}Spinning down $devpath... (util: $util%)${RESET}"
          sudo /sbin/hdparm -y "$devpath"
        else
          echo "${RED}$devpath is busy (util: $util%), skipping spindown${RESET}"
        fi

      else
        echo "${RED}$devpath Skipping non-rotational device${RESET}"
      fi
    else
      echo "${RED}$devpath No rotational info, skipping${RESET}"
    fi
  done

  echo "${CYAN}$(date) - Spindown attempt completed${RESET}"
} | tee -a "$LOG_FILE"
