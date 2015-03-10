#!/bin/bash

# Treat unset variables as an error when substituting.
set -u

# New line to terminal when Ctrl-C in read [Y/n].
# More pretty.
trap 'echo ; exit 1' SIGINT

# Default settings

##
## Local variables
##

#Staff variables.
APP="`basename "$0" .sh`"
EXIT_CODE=0
MESG=

# MODE can be: 'identify' - show mode
#              'remove'   - remove mode
# will be finally mandatory set before main body.
MODE=

# Summary mode. Can be non-empty ('yes')
#                applicable if MODE='identify' only
SUMMARY_MODE=

# Mandatory parameters.
DIRECTORY=
DAYS_AGO=

## store here user's version of passvalue.
OPT_FORCE=

## Size rank (int; in bytes.)
OPT_SIZE=

# when remove - more informative.
DEL_VERBOSE=


# declared as int to increase speed.
# (to speedup calculation within loop )
declare -i LOOP_SIZE
declare -i TSIZE=0
declare -i TSKIP_SIZE

# for imitation of 'recursive' mode
declare -i CUMULATIVE_SIZE

# counters. Only for  MODE==identify
declare -i SKIP_ITEM_COUNTER
declare -i DEL_ITEM_COUNTER=0


## The original size of the specified directory.
declare -i ORIGIN_SIZE

## For pretty printf. '*' printf specification. (tuned field length)
declare -i ORIGIN_SIZE_LENGTH
declare -i ORIGIN_SIZE_LENGTH2 # for human readable length
declare -i LPADDING=3 # Leading spaces lpadding for data line


# staff variables for CUMULATIVE mode (alternate of 'recursive' )
OLD_ITEM=     # file name
OLD_ATIME=    # access time

# This flag is an alternative for 'recursive' mode.
# 'recursive' is native simple mode. Default.
CUMULATIVE=

# Flag for size skiping
SIZE_SKIP_FLAG=

while [ $# -gt 0 ]
do
  case "$1" in
    --help|-h|-\?)
      pod2usage -verbose 1 "$0"
      exit 0
    ;;

    --man)
      pod2usage -verbose 2 "$0"
      exit 0
    ;;

    --directory|-d)
      shift 1
      [ -n "${DIRECTORY}" ] && {
        echo "The --directory (-d) option is defined more than two times. Error." 
        pod2usage --output ">&2" "$0"
        exit 2
      }

      if [ $# -gt 0 -a "${1:0:1}" != '-' ]; then
        DIRECTORY="$1/"
        shift 1 # Discard option from list of arguments
      else
        echo "The --directory (-d) option can not be empty." 
        pod2usage --output ">&2" "$0"
        exit 2
      fi
    ;;

    --summary|-v)
      shift 1
      [ -n "${SUMMARY_MODE}" ] && {
        echo "Redundant --summary(-v) option."
        pod2usage --output ">&2" "$0"
        exit 2
      }
      SUMMARY_MODE='yes' ;;

    --remove)
      shift 1
      [ -n "${MODE}" ] && {
        echo "Only --summary or --remove option may be specified at the same time."
        pod2usage --output ">&2" "$0"
        exit 2
      }
      MODE='remove'
      while [  $# -ge 1 -a "${1:0:1}" != '-' ]; do
        case $1 in
          verbose)
            [ -n "${DEL_VERBOSE}" ] && {
              echo "The --remove option can have one verbose and one passvalue argument only."
              pod2usage --output ">&2" "$0"
               exit 2
             }
            DEL_VERBOSE='yes'
            ;; 
          *)
            [ -n "${OPT_FORCE}" ] && {
              echo "The --remove option can have one verbose and one passvalue argument only."
              pod2usage --output ">&2" "$0"
               exit 2
             }
             # we get user's version of passvalue
             OPT_FORCE="$1"
            ;;
        esac
        shift
      done
    ;;

    --days-ago|-D)
      shift 
      [ -n "${DAYS_AGO}" ] && {
        echo "The --days-ago (-D) option is set more than two times. Error." 
        pod2usage --output ">&2" "$0"
        exit 2
      }
      if [ $# -gt 0 -a "${1:0:1}" != '-' ]; then
        DAYS_AGO=$1
        shift 1 # Discard option from list of arguments
      else
        echo "The --days-ago (-D) option can not be empty."
        pod2usage --output ">&2" "$0"
        exit 2
      fi
    ;;

    --size|-s)
      shift
      [ -n "${OPT_SIZE}" ] && {
        echo "The --size (-s) option is set more than two times. Error." 
        pod2usage --output ">&2" "$0"
        exit 2
      }
 
      if [ $# -gt 0 -a "${1:0:1}" != '-' ]; then
        OPT_SIZE=$1
        shift 1 # Discard option from list of arguments
      else
        echo "The --size (-s) option can not be empty."
        pod2usage --output ">&2" "$0"
        exit 2
      fi
    ;;

    --cumulative|-c)
      CUMULATIVE='yes'
      shift
    ;;
    -*)
      echo "Unknown option: $1" >&2
      pod2usage --output ">&2" "$0"
      exit 2
    ;;

     *) 
      echo "Non-optional argument is not expected." 
      pod2usage --output ">&2" "$0"
      exit 2

  esac
done

function error() {
  echo "[$APP] ERROR: $@" >&2
}
function warn() {
  echo "[$APP] WARN: $@" >&2
}
function info() {
  echo -e "$@"
}

# Application functions
# Return first real ( first not-globbing up-dir )
function get_absolute_path() {
  local ANY_PATH="$1"
  local NEAREST_REAL_PATH="${ANY_PATH%%[\*\?]*}"
 
  # If globbing, truncate dir mask to 1st real, 
  # if "no" - nothing to do.
  [ "${#NEAREST_REAL_PATH}" != "${#ANY_PATH}" ] && \
    local NEAREST_REAL_PATH="${NEAREST_REAL_PATH%/*}"
  
  local ABS_PATH=$( cd "${NEAREST_REAL_PATH}" ; pwd )
  echo -n "${ABS_PATH}"
}

#
## Enhanced functionality 
## ( Bytes => K bytes )
function human_readable() {
  local -i SIZE="${1:-0}"
  local ADD_STR="${2:-}"
  local TMP=$((SIZE/1024))
  local i=
  local RES=

  for (( i=${#TMP}-3; i>0; i-=3 )); do
    RES="'${TMP:$i:3}${RES}" 
  done

  ((i+=3))
  RES="${TMP:0:$i}${RES}" 

  echo "[ ${RES} ${ADD_STR}]"
}


function print_head() {
  local EOL="${1:-}"
  printf "\n%*s%*s %-16s %s${EOL}\n" "${ORIGIN_SIZE_LENGTH}" "Size:bytes" $((ORIGIN_SIZE_LENGTH2+1)) "Kb" "ModifyTime" "Filename"
  echo '---------------------------------------'
}

# any output inside the loop is done through this function call only.
function print_line() {
  local LOCAL_SIZE="$1"
  # when we output the top-level directory in the cumulative mode
  # we change date to 'x' and time to 'x' ( for possible outer 'sort' or other pipes )
  local LOCAL_LACCESS="${2:-x     x}"
  local LOCAL_ITEM_NAME="$3"
  local EOL="${4:-}"

  printf "%*s %*s %16s %s${EOL}" "${ORIGIN_SIZE_LENGTH}" "${LOCAL_SIZE}"\
          "${ORIGIN_SIZE_LENGTH2}"   "$(human_readable ${LOCAL_SIZE})"\
          "${LOCAL_LACCESS}" "${LOCAL_ITEM_NAME}" 
}

# system 'rm' call. -v if specified
function real_delete() {
   ITEM="$1"
   [ -n "${DEL_VERBOSE}" ] && FLAG='-v'
   rm ${FLAG:-} "${ITEM}"
}

# Some manipulation to create pseudo random key (passvalue).
# The reversed value of ORIGIN_SIZE is passvalue.
function passvalue() {
  perl -e "print reverse split //, '$1'"
}

# For inside loop. This function increases all
# counters and sum variables. ( --size mode handling too here )
# return code: zero - normal handling, 'non zero' - need to skip

# Parameters passed and set as global variables
# LOOP_SIZE, OPT_SIZE        input parameters
# xxx_ITEM_COUNTER, xxx_SIZE output parameters
function counters_increasing_and_is_skip() {
  if [ -n "${OPT_SIZE}" ]; then
    if ((LOOP_SIZE < OPT_SIZE)); then
      ((TSKIP_SIZE+=LOOP_SIZE))
      ((SKIP_ITEM_COUNTER++))
      return 1
    else
      ((TSIZE+=LOOP_SIZE))
      ((DEL_ITEM_COUNTER++))
    fi
  else
    # count in any case. --size opt not specified.
    ((TSIZE+=LOOP_SIZE))
    ((DEL_ITEM_COUNTER++))
  fi

  return 0
}


##
## Body
[ -z "${DIRECTORY}" ] && {
  error 'The --directory(-d) option is required.'
  EXIT_CODE=1
}

(( ! DAYS_AGO )) && {
  error 'The -days-ago(-D) option is required.'
  EXIT_CODE=1
}

# For cumulative mode. Where to start separate dirs.
CUMULATIVE_ROOT_DIRECTORY=$( get_absolute_path "${DIRECTORY}" )
[ -n "${DIRECTORY}" -a ! -d "${CUMULATIVE_ROOT_DIRECTORY}" ] && {
  error "Directory '${DIRECTORY}' was not found"
  EXIT_CODE=1
}

[ "empty${MODE}" == 'empty' ] && MODE='identify'

[ "${MODE}" == 'remove' -a \
  -n "${SUMMARY_MODE}" ] && {
  error "Incompatible options --remove and --summary(-v)."
  EXIT_CODE=1
}

[ "${MODE}" == 'remove' -a \
  -n "${CUMULATIVE}" ] && {
  error "Incompatible options --remove and --cumulative(-c)."
  EXIT_CODE=1
}

[ -n "${OPT_SIZE}" -a \
   "${OPT_SIZE//[[:digit:]]/}digitsOnly" != 'digitsOnly' ] && {
  error 'Non digit value of --size(-s) option.'
  EXIT_CODE=1
}

[ "x$( ls -1 ${DIRECTORY} )" == 'x' ] && {
  info "The '${DIRECTORY}' is empty"
  exit 0
}

((EXIT_CODE)) && { 
  pod2usage --output ">&2" "$0"
  exit "${EXIT_CODE}"
}


# Output for summary mode and passvalue checking

ORIGIN_SIZE=$( LANG=C du -c -s -b ${DIRECTORY} | grep -P '^\d+\s+total' | cut -f 1 )
PASSVALUE=$( passvalue $ORIGIN_SIZE )

[ -n "${OPT_FORCE}" -a "${PASSVALUE}" != "${OPT_FORCE}" ] && {
  info "The passvalue '$OPT_FORCE' for --remove option is incorrect."
  exit 2
}

#
# check finished.
#####################
ORIGIN_SIZE_LENGTH="${#ORIGIN_SIZE}"
ORIGIN_SIZE_LENGTH2=$((ORIGIN_SIZE_LENGTH+5))

((ORIGIN_SIZE_LENGTH+=LPADDING))
if [    -n "${SUMMARY_MODE}" ]; then
  printf -v MESG "%*d %*s: bytes [ Kb ] in '${DIRECTORY}' (origin size)" "${ORIGIN_SIZE_LENGTH}" "${ORIGIN_SIZE}" "${ORIGIN_SIZE_LENGTH2}" "$(human_readable ${ORIGIN_SIZE})" 
  info "${MESG}"
else
  [ -z "${OPT_FORCE}" ] && \
    print_head
fi



# Redefine descriptor for pass 
# to new shell invocation:
# tmpwatch | { while... }  [y/n] answers
exec 5<&0



CMD="$(which tmpwatch) --test $((DAYS_AGO*24)) ${DIRECTORY}"

# When cumulative mode   - sort is very important.
# and tmpwatch doesn't always return sorted list.
[ -n "${CUMULATIVE}" ] && CMD="LANG=C ${CMD} | sort"

{ eval "${CMD}" ;} | {

  while read -r DEL_ITEM; do
    ITEM_TYPE="${DEL_ITEM:0:14}"
    ITEM_NAME="${DEL_ITEM:14}"

    ##  Script works if tmpwatch returns line whit such prefix.
    if [ "${ITEM_TYPE}" == 'removing file ' ]; then
      LOOP_SIZE=$( stat -c '%s' "${ITEM_NAME}" )
      LACCESS=$( stat -t -c '%x' "${ITEM_NAME}" )
      LACCESS="${LACCESS:0:16}"

      SIZE_SKIP_FLAG=
      counters_increasing_and_is_skip || {
        # not null 'error' code means 'to skip'

        # if 'remove' mode  - we can process next iteration
        # just here. (No manipulation for pre-counting)
        [ "${MODE}" == 'remove' ]  && continue

        # we do not to continue here.
        #   OLD_ITEM has to be handled for cumulative mode.
        SIZE_SKIP_FLAG='yes'
      }


      # No real actions. Manipulation with summary option
      # and manipulation with 'recursive' - 'cumulative' options
      [ "${MODE}" == 'identify' ] && {
        [ -z "${SUMMARY_MODE}" ] && {
          [ -z "${CUMULATIVE}" ] && {
            [ -z "${SIZE_SKIP_FLAG}" ] && \
              print_line "${LOOP_SIZE}" "${LACCESS}" "${ITEM_NAME}" "\n"
            continue
          } # [ -z "${CUMULATIVE}" ] && {
          
          TMP="${ITEM_NAME#${CUMULATIVE_ROOT_DIRECTORY}/}"
          CURR_ITEM="${TMP%%/*}"
          # we want to know - is it a directory  ?
          # either or '/' or  empty
          DIR_SYMBOL="${TMP:${#CURR_ITEM}:1}"
          [ -z "${SIZE_SKIP_FLAG}" ] && {
            if [ "${OLD_ITEM}" != "${CURR_ITEM}${DIR_SYMBOL}" ]; then
              [ -n "${OLD_ITEM}" ] && \
                print_line "${CUMULATIVE_SIZE}" "${OLD_ATIME}" "${CUMULATIVE_ROOT_DIRECTORY}/${OLD_ITEM}" "\n"
              ((CUMULATIVE_SIZE=LOOP_SIZE))
            else
              ((CUMULATIVE_SIZE+=LOOP_SIZE))
            fi
          }

          APPLICABLE_LACCESS_TIME=
          [ -z "${DIR_SYMBOL}" ] && APPLICABLE_LACCESS_TIME="${LACCESS}"

          OLD_ITEM="${CURR_ITEM}${DIR_SYMBOL}"
          OLD_ATIME="${APPLICABLE_LACCESS_TIME}"
        } # [ -z "${SUMMARY_MODE}" ] && {
        continue
      } # [ "${MODE}" == 'identify' ]
      # Simple  ( and --summary ) 'identify' mode ended.

     
      # Situations left for remove only variants start here.
      if [ -z "${OPT_FORCE}" ]; then
        print_line "${LOOP_SIZE}" "${LACCESS}" "${ITEM_NAME}"
        echo -en "\t"
        read -u 5 -p "Delete ? [y/N]: " ANS 
        if [ "${ANS}" = 'y' -o "${ANS}" = 'Y' ]; then
          real_delete "${ITEM_NAME}" || {
            error "Non zero exit code when 'rm' '${ITEM_NAME}'."
            exit 1
          }
        fi

      # The passvalue specified ( and it is correct; we've already checked it)
      elif [ -n "${OPT_FORCE}" ]; then
        real_delete "${ITEM_NAME}" || {
          error "Non zero exit code when 'rm' '${ITEM_NAME}'."
          exit 1
        }
      fi

    # Third abnormal case in MAIN if-elif-else inside loop.
    else
      error "Undiscovered tmpwatch output: '${DEL_ITEM}'. Urgent stop." 
      exit 1
    fi
  done
  # loop ended. 
  # It is last outside loop output for CUMULATIVE mode.
  [ -n "${OLD_ITEM}" ] && {
    ITEM_NAME="${OLD_ITEM}${DIR_SYMBOL:-}"
    LOOP_SIZE="${CUMULATIVE_SIZE}"
    print_line "${CUMULATIVE_SIZE}" "${OLD_ATIME}" "${CUMULATIVE_ROOT_DIRECTORY}/${OLD_ITEM}" "\n"
  }

  # Report part. 
  # Output for summary mode.
  [ -n "${SUMMARY_MODE}" ] || ((DEL_ITEM_COUNTER==0)) && {
    # Two types of messages can be generated here. About --size(-s) option
    [ -n "${OPT_SIZE}" ] && {
      if (( SKIP_ITEM_COUNTER )); then
        printf -v MESG '%*s %*s:              in %d files older than '%d' days ago and with size less than %d bytes %s. They will not be deleted.' \
          "${ORIGIN_SIZE_LENGTH}" "${TSKIP_SIZE}" "${ORIGIN_SIZE_LENGTH2}" "$(human_readable ${TSKIP_SIZE} )" "${SKIP_ITEM_COUNTER}" "${DAYS_AGO}" \
                      "${OPT_SIZE}" "$(human_readable ${OPT_SIZE} 'Kb' )"
      else 
        printf -v MESG "%*sNo files with size less than %s %s." "${LPADDING}" ' ' "${OPT_SIZE}" "$(human_readable ${OPT_SIZE} 'Kb')"
      fi
      info "${MESG}"
    }


    # Two types of messages can be generated here. (about quantity of candidates to remove. )
    if (( DEL_ITEM_COUNTER )); then
      printf -v MESG "%*s %*s:              in %d files WILL BE REMOVED." "${ORIGIN_SIZE_LENGTH}" "${TSIZE}" "${ORIGIN_SIZE_LENGTH2}" "$(human_readable ${TSIZE})" "${DEL_ITEM_COUNTER}"
    else
      printf -v MESG '%*sNo files will be deleted' "${LPADDING}" ' '
    fi
    info "${MESG}"
  } 

  # we allow passvalue if user have 'saw' all list of candidates to delete only. 
  [ "${MODE}" == 'identify' -a -z "${SUMMARY_MODE}" -a -z "${CUMULATIVE}" ] && (( DEL_ITEM_COUNTER )) && {
    printf "%*sPassvalue: ${PASSVALUE}\n" $((ORIGIN_SIZE_LENGTH+ ORIGIN_SIZE_LENGTH2+19))
  }

}


exit $EXIT_CODE

__END__

=pod

=head1 NAME

remove-old-files.sh - tool to identify files in specified directory ( subirs tree ). 
as old (by date) and size ( 'grater or equal than' )
Removes old files if needed. 

=head1 SYNOPSIS

remove-old-files.sh -d <dir> -D <days_ago> [-s <size_in_bytes>] [--cumulative|-c]

remove-old-files.sh -d <dir> -D <days_ago> [-s <size_in_bytes>] --summary 

remove-old-files.sh -d <dir> -D <days_ago> [-s <size_in_bytes>] --remove [verobse] [<PASSVALUE>] ]


=head1 OPTIONS

=over 4

=item B<--help> | B<-h>

Print the brief help message and exit.

=item B<--man>

Print the manual page and exit.

=item General options:

=over 4

=item B<--directory|-d> <PATH_TO_DIR>

Mandatory.  Specifies the single directory to be analyzed for "older than X days" and "larger or equil than" files. Globs are allowed for the --directory, but must be surrounded by single or double quotes.  E.g. --directory '/ftp/*/feeds*'

=item B<--days-ago|-D> <DAYS_AGO>

Mandatory. Specifies the number of 'days' to treat file as 'old'.

=item B<--size|-s> <SIZE_IN_BYTES>

Selects files - candidates to remove based on size criteria also (grater or equal specified value in bytes)

=back

=item Action options:

=over 4

=item B<none> [--cumulative|-c]

if no options are specified, output the list of files - candidates for removal ( according general option above )
if appropriative files exist, additionally print the '<PASSVALUE>' (last line). It is the subargument for --remove option.
See description below for it.

if --cumulative(-c) option specified, do not deep into subdirs of --directorry(-d) option value.
The total size of subdirectory output.

=item B<--summary> 

if --size(-s) option specified, outputs two lines:
  1st: The origin size of specified in --directory(-d) option path. ( /usr/bin/du -s -b <dir> )
  2nd: The size and number of files that are expected to be deleted.
  (--cumulative option is ignored )

with --size(-s) option adds string between these lines with info about files that will not be deleted
according to size criteria (or a message that such file are absent ).

=item B<--remove> [<PASSVALUE>] [verbose]

When <PASSVALUE> not specified user should answer ['y' or 'Y'] when script asks for confirmatin.
When <PASSVALUE> is specified and correct the script will remove all files matching the criteria.
'verbose' produces more otput info ( script messages and as for 'rm -v' comand ). Useful together with '<PASSVALUE>'

=back

=back

=head1 DESCRIPTION

This tools helps to remove old files based on 'older' than specified 'days_ago' value
and 'larger than' criteria.
Logic to make decision on deleting is based on /usr/sbin/tmpwatch rules. This script does not delete directories.

Steps to get sorted by size files list.

remove-old-files.sh -d path -D days | grep -P '^\s+\d' | sort -n

Steps to get sorted by date files list.

remove-old-files.sh -d path -D days | grep -P '^\s+\d' | sort -k 5,6 

Note: When size is entered as 'Kb' (in square brackets ): it is the int part of the origin size divided on 1024.

=head1 SEE ALSO

Ticket #xxxx

=head1 AUTHOR

Vladyslav V. Gula <vladyslav.gula@gmail.com>

=cut

