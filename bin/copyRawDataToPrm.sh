#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]
then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi

set -e # Exit if any subcommand or pipeline returns a non-zero exit status.
set -u # Raise exception if variable is unbound. Combined with set -e will halt execution when an unbound variable is encountered.
set -o pipefail # Fail when any command in series of piped commands failed as opposed to only when the last command failed.

umask 0027

# Env vars.
export TMPDIR="${TMPDIR:-/tmp}" # Default to /tmp if $TMPDIR was not defined.
SCRIPT_NAME="$(basename "${0}")"
SCRIPT_NAME="${SCRIPT_NAME%.*sh}"
INSTALLATION_DIR="$(cd -P "$(dirname "${0}")/.." && pwd)"
LIB_DIR="${INSTALLATION_DIR}/lib"
CFG_DIR="${INSTALLATION_DIR}/etc"
HOSTNAME_SHORT="$(hostname -s)"
ROLE_USER="$(whoami)"
REAL_USER="$(logname 2>/dev/null || echo 'no login name')"

#
##
### Functions.
##
#

if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]
then
	# shellcheck source=lib/sharedFunctions.bash
	source "${LIB_DIR}/sharedFunctions.bash"
else
	printf '%s\n' "FATAL: cannot find or cannot access sharedFunctions.bash"
	trap - EXIT
	exit 1
fi

function contains() {
	local n=$#
	local value=${!n}
	for ((i=1;i < $#;i++)) {
		if [ "${!i}" == "${value}" ]; then
			echo "y"
			return 0
		fi
	}
	echo "n"
	return 1
}

function rsyncRuns() {
	local _run="${1}"
	local count="${2}"
	local totalCount="${3}"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_run} ..."
	#
	# ToDo: change location of job control files back to ${TMP_ROOT_DIR} once we have a 
	#       proper prm mount on the GD clusters and this script can run a GD cluster
	#       instead of on a research cluster.
	#
	#local JOB_CONTROLE_FILE_BASE="${TMP_ROOT_DIR}/logs/${_run}/run01.${SCRIPT_NAME}"
	local JOB_CONTROLE_FILE_BASE="${PRM_ROOT_DIR}/logs/${_run}/run01.${SCRIPT_NAME}"
	local _logFile="${JOB_CONTROLE_FILE_BASE}.log"
	#
	# Determine whether an rsync is required for this run, which is the case when
	#  1. either the sequence run has finished successfully and this copy script has not
	#  2. or when a pipeline has updated the results after a previous execution of this script.
	#
	# Check if production of raw data @ sourceServer has finished.
	#
	if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
	then
		#
		# Get modification times as integers (seconds since epoch) 
		# and check if ${_run}/run01.demultiplexing.finished is newer than *.dataCopiedToPrm,
		# which indicates the run was re-demultiplexed and converted to FastQ files.
		#
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Checking if ${_run}/${STEPBEFOREFINISHEDFILE}  is newer than ${JOB_CONTROLE_FILE_BASE}.finished"
		local _fileFinishedModTime=$(ssh ${DATA_MANAGER}@${sourceServerFQDN} stat --printf='%Y' "${SCR_ROOT_DIR}/${STEPBEFOREFINISHEDFILEPATH}/${_run}/${STEPBEFOREFINISHEDFILE}")
		local _myFinishedModTime=$(stat --printf='%Y' "${JOB_CONTROLE_FILE_BASE}.finished")
		if [[ "${_fileFinishedModTime}" -gt "${_myFinishedModTime}" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_run}/${STEPBEFOREFINISHEDFILE} newer than ${JOB_CONTROLE_FILE_BASE}.finished."
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_run}/${STEPBEFOREFINISHEDFILE} older than ${JOB_CONTROLE_FILE_BASE}.finished."
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run}."
			return
		fi
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "No ${JOB_CONTROLE_FILE_BASE}.finished present."
	fi
	#
	# Track and Trace: log that we will start rsyncing to prm.
	#
	# ToDo: FIX THIS FOR GAP.
	#
	touch "${JOB_CONTROLE_FILE_BASE}.started"
	echo "started: $(date +%FT%T%z)" > "${JOB_CONTROLE_FILE_BASE}.totalRuntime"
	trackAndTracePut 'status_overview' "${_run}" 'copy_raw_prm' 'started'
	
	#
	# Perform rsync.
	#  1. For ${_run} dir: recursively with "default" archive (-a),
	#     which checks for differences based on file size and modification times.
	#     No need to use checksums here as we will verify checksums later anyway.
	#  2. For *.md5 list of checksums with archive (-a) and -c to determine
	#     differences based on checksum instead of file size and modification time.
	#     It is vitally important (and computationally cheap) to make sure
	#     the list of checksums is complete and up-to-date!
	#
	# ToDo: Do we need to add --delete to get rid of files that should no longer be there
	#       if an analysis run got updated?
	#
	local _transferSoFarSoGood='true'
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing ${_run} dir ..."
	echo "working on ${_run}" > "${PRM_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"
	local _rawDataType
	for _rawDataType in "${RAWDATATYPES[@]}"
	do
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Making dir: ${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_run} ..."
		mkdir -m 2750 -p "${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_run}"
		
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Rsyncing ${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/rawdata/${_rawDataType}/${_run} to ${PRM_ROOT_DIR}/rawdata/${_rawDataType}/ ..."
		rsync -vrltDL --progress --log-file="${JOB_CONTROLE_FILE_BASE}.started" --chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' ${dryrun:-} \
			"${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/rawdata/${_rawDataType}/${_run}" \
			"${PRM_ROOT_DIR}/rawdata/${_rawDataType}/" \
		|| {
			mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Failed to rsync ${sourceServerFQDN}:${SCR_ROOT_DIR}/rawdata/${_rawDataType}/${_run}/ dir. See ${JOB_CONTROLE_FILE_BASE}.failed for details."
			echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync of sequence run dir failed. See ${JOB_CONTROLE_FILE_BASE}.failed for details." \
				>> "${JOB_CONTROLE_FILE_BASE}.failed"
			_transferSoFarSoGood='false'
		}
		#
		# Sanity check.
		#
		#  1. Firstly do a quick count of the amount of files to make sure we are complete.
		#     (No need to waist a lot of time on computing checksums for a partially failed transfer).
		#  2. Secondly verify checksums on the destination.
		#
		if [[ "${_transferSoFarSoGood}" == 'true' ]];then
			local _countFilesRunDirScr=$(ssh ${DATA_MANAGER}@${sourceServerFQDN} "find ${SCR_ROOT_DIR}/rawdata/${_rawDataType}/${_run}/* -type f | wc -l")
			local _countFilesRunDirPrm=$(find "${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_run}/"* -type f | wc -l)
			local _checksumVerification='unknown'
			if [[ ${_countFilesRunDirScr} -ne ${_countFilesRunDirPrm} ]]; then
				mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
				echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): Amount of files for ${_run} on scr (${_countFilesRunDirScr}) and prm (${_countFilesRunDirPrm}) is NOT the same!" \
					>> "${JOB_CONTROLE_FILE_BASE}.failed"
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
					"Amount of files for ${_run} on tmp (${_countFilesRunDirScr}) and prm (${_countFilesRunDirPrm}) is NOT the same!"
				_checksumVerification='FAILED'
			else
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files on tmp and prm is the same for ${_run}: ${_countFilesRunDirPrm}."
				#
				# Verify checksums on prm storage.
				#
				if [[ "${_rawDataType}" == 'array/IDAT' ]]
				then
					_checksumVerification='PASS'
				else
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
						"Started verification of checksums by ${DATA_MANAGER}@${sourceServerFQDN} using checksums from ${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_run}/*.md5." \
						2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
					_checksumVerification=$(cd ${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_run}
						if md5sum -c *.md5 > ${JOB_CONTROLE_FILE_BASE}.md5.log 2>&1
						then
							echo 'PASS'
						else
							echo 'FAILED'
						fi
					)
				fi
			fi
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "_checksumVerification = ${_checksumVerification}"
			if [[ "${_checksumVerification}" == 'FAILED' ]]
			then
				mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
				echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): checksum verification failed. See ${JOB_CONTROLE_FILE_BASE}.md5.log for details." \
					>> "${JOB_CONTROLE_FILE_BASE}.failed"
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Checksum verification failed. See ${JOB_CONTROLE_FILE_BASE}.md5.log for details."
			elif [[ "${_checksumVerification}" == 'PASS' ]]
				then
				#
				# Overwrite any previously created *.failed file if present,
				# add new status info incl. demultiplex stats to *.failed file and
				# then move the *.failed file to *.finished.
				# (Note: the content of *.finished will get inserted in the body of email notification messages,
				# when enabled in <group>.cfg for use by notifications.sh)
				#
				echo "The results can be found in: ${PRM_ROOT_DIR}." > "${JOB_CONTROLE_FILE_BASE}.failed"
				if ls "${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_run}/${_run}"*.log 1>/dev/null 2>&1
				then
					cat "${PRM_ROOT_DIR}/rawdata/${_rawDataType}/${_run}/${_run}"*.log >> "${JOB_CONTROLE_FILE_BASE}.failed"
				fi
				echo "OK! $(date '+%Y-%m-%d-T%H%M'): checksum verification succeeded. See ${JOB_CONTROLE_FILE_BASE}.md5.log for details." \
					>>    "${JOB_CONTROLE_FILE_BASE}.failed" \
					&& mv "${JOB_CONTROLE_FILE_BASE}."{failed,finished}
				echo "finished: $(date +%FT%T%z)" >> "${JOB_CONTROLE_FILE_BASE}.totalRuntime"
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Checksum verification succeeded.'
			fi
		fi
	done
	#
	# Sanity check and report status to track & trace.
	#
	if [[ -e "${JOB_CONTROLE_FILE_BASE}.failed" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${JOB_CONTROLE_FILE_BASE}.failed. Setting track & trace state to failed :(."
		trackAndTracePut 'status_overview' "${_run}" 'copy_raw_prm' 'failed'
	elif [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${JOB_CONTROLE_FILE_BASE}.finished. Setting track & trace state to finished :)."
		trackAndTracePut 'status_overview' "${_run}" 'copy_raw_prm' 'finished'
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' 'Ended up in unexpected state:'
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Expected either ${JOB_CONTROLE_FILE_BASE}.finished or ${JOB_CONTROLE_FILE_BASE}.failed, but both are absent."
	fi
}

function splitSamplesheetPerProject() {
	local _run="${1}"
	local _sampleSheet="${PRM_ROOT_DIR}/Samplesheets/archive/${_run}.${SAMPLESHEET_EXT}"
	#
	# ToDo: change location of job control files back to ${TMP_ROOT_DIR} once we have a 
	#       proper prm mount on the GD clusters and this script can run on a GD cluster
	#       instead of on a research cluster.
	#
	#local JOB_CONTROLE_FILE_BASE="${TMP_ROOT_DIR}/logs/${_run}/${_run}.splitSamplesheetPerProject"
	local _rsyncControlFileFinished="${PRM_ROOT_DIR}/logs/${_run}/run01.${SCRIPT_NAME}.finished"
	local JOB_CONTROLE_FILE_BASE="${PRM_ROOT_DIR}/logs/${_run}/run01.splitSamplesheetPerProject"
	local _logFile="${JOB_CONTROLE_FILE_BASE}.log"
	#
	#
	# Rsync samplesheet to prm samplesheets folder.
	#
	rsync -vrltD --progress --log-file="${JOB_CONTROLE_FILE_BASE}.started" --chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' ${dryrun:-} \
		"${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/Samplesheets/${_run}.${SAMPLESHEET_EXT}" \
		"${PRM_ROOT_DIR}/Samplesheets/archive/" \
	|| {
		mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Failed to rsync ${SCR_ROOT_DIR}/Samplesheets/${_run}.${SAMPLESHEET_EXT}. See ${JOB_CONTROLE_FILE_BASE}.failed for details."
		echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync of sample sheet failed. See ${JOB_CONTROLE_FILE_BASE}.failed for details." \
			>> "${JOB_CONTROLE_FILE_BASE}.failed"
	}
	if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${JOB_CONTROLE_FILE_BASE}.finished -> Skipping ${_run}."
		return
	elif [[ ! -e "${_rsyncControlFileFinished}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Not found ${_rsyncControlFileFinished} -> Skipping splitting ${_run}."
		return
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "No ${JOB_CONTROLE_FILE_BASE}.finished present -> Splitting sample sheet per project for ${_run} ..." \
			2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
	fi
	#
	# Parse sample sheet to get a list of project values.
	#
	declare -a _sampleSheetColumnNames=()
	declare -A _sampleSheetColumnOffsets=()
	local      _projectFieldIndex
	declare -a _projects=()
	declare -a _pipelines=()
	declare -a _demultiplexOnly=("n")
	IFS="${SAMPLESHEET_SEP}" _sampleSheetColumnNames=($(head -1 "${_sampleSheet}"))
	for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]:-0} ; _offset++ ))
	do
		_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
	done
	#
	# Check if the pipeline step can be skipped. 
	#
	if [[ ! -z "${_sampleSheetColumnOffsets["${PROJECTCOLUMN}"]+isset}" ]]; then
		_pipelineFieldIndex=$((${_sampleSheetColumnOffsets["${PIPELINECOLUMN}"]} + 1))
		_projectFieldIndex=$((${_sampleSheetColumnOffsets["${PROJECTCOLUMN}"]} + 1))
		IFS=$'\n' _pipelines=($(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f ${_pipelineFieldIndex} | sort | uniq ))
		if [[ "${#_pipelines[@]:-0}" -lt '1' ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} does not contain at least one pipeline value." \
				2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run} due to error in sample sheet." \
				2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started" \
				&& mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
			return
		elif [[ "${#_pipelines[@]:-0}" -eq '1' ]]
		then
			for _pipeline in "${_pipelines[@]}"
			do
				_pipeline_to_upper_case=$(echo "${_pipeline}"| awk '{print toupper($0)}')
				if [[ "${_pipeline_to_upper_case}" = *"DEMULTIPLEXING ONLY"* ]]
				then
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Demultiplexing only." \
						2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
					mv "${JOB_CONTROLE_FILE_BASE}."{started,finished}
					return
				fi
			done
		elif [[ "${#_pipelines[@]:-0}" -gt '1' ]]
		then
			for _pipeline in "${_pipelines[@]}"
			do
				_pipeline_to_upper_case=$(echo "${_pipeline}"| awk '{print toupper($0)}')
				if [[ "${_pipeline_to_upper_case}" == *"DEMULTIPLEXING ONLY"* ]]
				then
					IFS=$'\n' _demultiplexOnly=($(awk -F "${SAMPLESHEET_SEP}" "{if (NR>1 && \$${_pipelineFieldIndex} ~ /${_pipelines}/) {print}}" "${_sampleSheet}" |  awk "BEGIN{FS=\"${SAMPLESHEET_SEP}\"} {print \$${_projectFieldIndex}}" | sort -u))
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Demultiplexing only detected." \
						2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
				fi
			done
		fi
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "GCC_Analysis column missing in sample sheet." \
			2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Continue with ${_run} due to missing pipeline column." \
			2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
	fi
	#
	# Check if sample sheet contains required project column.
	#
	if [[ ! -z "${_sampleSheetColumnOffsets["${PROJECTCOLUMN}"]+isset}" ]]; then
		_projectFieldIndex=$((${_sampleSheetColumnOffsets["${PROJECTCOLUMN}"]} + 1))
		IFS=$'\n' _projects=($(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_projectFieldIndex}" | sort | uniq ))
		if [[ "${#_projects[@]:-0}" -lt '1' ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} does not contain at least one project value." \
				2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run} due to error in sample sheet." \
				2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started" \
				&& mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
			return
		fi
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "project column missing in sample sheet." \
			2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run} due to error in sample sheet." \
			2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started" \
			&& mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
		return
	fi
	

	#
	# Create sample sheet per project.
	#
	for _project in "${_projects[@]}"
	do
		printf '%s\n' "project,run_id,pipeline,url,capturingKit,message,copy_results_prm,finishedDate" \
			> "${JOB_CONTROLE_FILE_BASE}.trackAndTrace_projects.csv"
		printf '%s\n' "${_project},${_run},,,,,," \
			>> "${JOB_CONTROLE_FILE_BASE}.trackAndTrace_projects.csv"
		trackAndTracePostFromFile 'status_projects' 'add' \
			"${JOB_CONTROLE_FILE_BASE}.trackAndTrace_projects.csv"
		
		#
		# Skip project if demultiplexing only.
		#
		if [ $(contains "${_demultiplexOnly[@]}" "${_project}") == "y" ]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Demultiplexing Only for project: ${_project}, continue" \
			continue
		else
		#
		# ToDo: change location of sample sheet per project back to ${TMP_ROOT_DIR} once we have a 
		#       proper prm mount on the GD clusters and this script can run on a GD cluster
		#       instead of on a research cluster.
		#
		local _projectSampleSheet="${PRM_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT}"
		head -1 "${_sampleSheet}" > "${_projectSampleSheet}.tmp"
		grep "${_project}" "${_sampleSheet}" >> "${_projectSampleSheet}.tmp"
		mv "${_projectSampleSheet}"{.tmp,}
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Created ${_projectSampleSheet}." \
			2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
		fi
	done
	OLD_IFS="$IFS"
	IFS=","
	allProjects=$(echo "${_projects[*]}")
	IFS="$OLD_IFS"

	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "ALLPROJECTS:${allProjects}" 
	trackAndTracePut 'status_overview' "${_run}" 'projects' "'${allProjects}'"

	#
	# Move samplesheet to archive on sourceServerFQDN
	#
	if ssh "${DATA_MANAGER}@${sourceServerFQDN}" "mv ${SCR_ROOT_DIR}/Samplesheets/${_run}.${SAMPLESHEET_EXT}* ${SCR_ROOT_DIR}/Samplesheets/archive/"
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${_run}.${SAMPLESHEET_EXT} moved to ${SCR_ROOT_DIR}/Samplesheets/archive/ on ${sourceServerFQDN}." \
			2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started" \
			&& mv "${JOB_CONTROLE_FILE_BASE}."{started,finished}
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_run}.${SAMPLESHEET_EXT} cannot be moved to ${SCR_ROOT_DIR}/Samplesheets/archive/ on ${sourceServerFQDN}."
			2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started" \
			&& mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
		return
	fi
}

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to copy (sync) data from a succesfully finished run from tmp to prm storage.
Usage:
	$(basename "${0}") OPTIONS
Options:
	-h   Show this help.
	-g   Group.
	-n   Dry-run: Do not perform actual sync, but only list changes instead.
	-l   Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.
	-s   Source server address from where the rawdate will be fetched
		Must be a Fully Qualified Domain Name (FQDN).
		E.g. gattaca01.gcc.rug.nl or gattaca02.gcc.rug.nl
	-r   Root dir on the server specified with -s and from where the raw data will be fetched (optional).
		By default this is the SCR_ROOT_DIR variable, which is compiled from variables specified in the
		<group>.cfg, <source_host>.cfg and sharedConfig.cfg config files (see below.)
		You need to override SCR_ROOT_DIR when the data is to be fetched from a non default path,
		which is for example the case when fetching data from another group.

Config and dependencies:
	This script needs 4 config files, which must be located in ${CFG_DIR}:
	1. <group>.cfg       for the group specified with -g
	2. <this_host>.cfg   for this server. E.g.: "${HOSTNAME_SHORT}.cfg"
	3. <source_host>.cfg for the source server. E.g.: "<hostname>.cfg" (Short name without domain)
	4. sharedConfig.cfg  for all groups and all servers.
	In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.
===============================================================================================================
EOH
	trap - EXIT
	exit 0
}

#
##
### Main.
##
#

#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments ..."
declare group=''
declare dryrun=''
declare sourceServerFQDN=''
declare sourceServerRootDir=''
while getopts "g:l:s:r:hn" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		n)
			dryrun='-n'
			;;
		s)
			sourceServerFQDN="${OPTARG}"
			sourceServer="${sourceServerFQDN%%.*}"
			;;
		r)
			sourceServerRootDir="${OPTARG}"
			;;
		l)
			l4b_log_level="${OPTARG^^}"
			l4b_log_level_prio="${l4b_log_levels["${l4b_log_level}"]}"
			;;
		\?)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Invalid option -${OPTARG}. Try $(basename "${0}") -h for help."
			;;
		:)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Option -${OPTARG} requires an argument. Try $(basename "${0}") -h for help."
			;;
		*)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Unhandled option. Try $(basename "${0}") -h for help."
			;;	esac
done

#
# Check commandline options.
#
if [[ -z "${group:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -z "${sourceServerFQDN:-}" ]]
then
log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a Fully Qualified Domain Name (FQDN) for sourceServer with -s.'
fi
if [[ -n "${dryrun:-}" ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Enabled dryrun option for rsync.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/${sourceServer}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	"${HOME}/molgenis.cfg"
)
for configFile in "${configFiles[@]}"
do
	if [[ -f "${configFile}" && -r "${configFile}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config file ${configFile} ..."
		#
		# In some Bash versions the source command does not work properly with process substitution.
		# Therefore we source a first time with process substitution for proper error handling
		# and a second time without just to make sure we can use the content from the sourced files.
		#
		# Disable shellcheck code syntax checking for config files.
		# shellcheck source=/dev/null
		mixed_stdouterr=$(source "${configFile}" 2>&1) || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" "${?}" "Cannot source ${configFile}."
		# shellcheck source=/dev/null
		source "${configFile}"  # May seem redundant, but is a mandatory workaround for some Bash versions.
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Config file ${configFile} missing or not accessible."
	fi
done

#
# Overrule group's SCR_ROOT_DIR if necessary.
#
if [[ ! -z "${sourceServerRootDir:-}" ]]
then
	SCR_ROOT_DIR="${sourceServerRootDir}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Using alternative sourceServerRootDir ${sourceServerRootDir} as SCR_ROOT_DIR."
fi

#
# Write access to prm storage requires data manager account.
#
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
fi
#
# Make sure only one copy of this script runs simultaneously
# per data collection we want to copy to prm -> one copy per group.
# Therefore locking must be done after
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data transfers.
#
# ToDo: change location of job control files back to ${TMP_ROOT_DIR} once we have a 
#       proper prm mount on the GD clusters and this script can run a GD cluster
#       instead of on a research cluster.
#
#lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
lockFile="${PRM_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
#log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${PRM_ROOT_DIR}/logs ..."

#
# Use multiplexing to reduce the amount of SSH connections created
# when rsyncing using the group's data manager account.
# 
#  1. Become the "${DATA_MANAGER} user who will rsync the data to prm and 
#  2. Add to ~/.ssh/config:
#		ControlMaster auto
#		ControlPath ~/.ssh/tmp/%h_%p_%r
#		ControlPersist 5m
#  3. Create ~/.ssh/tmp dir:
#		mkdir -p -m 700 ~/.ssh/tmp
#  3. Recursively restrict access to the ~/.ssh dir to allow only the owner/user:
#		chmod -R go-rwx ~/.ssh
#

#
# Get a list of all sample sheets for this group on the specified sourceServer, where the raw data was generated,
# then
#	1. loop over their analysis ("run") sub dirs and check if there are any we need to rsync.
#	2. split the sample sheets per project and the data was rsynced.
#
declare -a sampleSheetsFromSourceServer=($(ssh ${DATA_MANAGER}@${sourceServerFQDN} "find ${SCR_ROOT_DIR}/Samplesheets/ -mindepth 1 -maxdepth 1 \( -type l -o -type f \) -name '*.${SAMPLESHEET_EXT}'"))

if [[ "${#sampleSheetsFromSourceServer[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No sample sheets found at ${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/Samplesheets/*.${SAMPLESHEET_EXT}."
else
	for sampleSheet in "${sampleSheetsFromSourceServer[@]}"
	do
		#
		# Process this sample sheet / run.
		#
		filePrefix="$(basename "${sampleSheet%.*}")"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${filePrefix} ..."
		#
		# ToDo: change location of log files back to ${TMP_ROOT_DIR} once we have a 
		#       proper prm mount on the GD clusters and this script can run a GD cluster
		#       instead of on a research cluster.
		#
		#mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${filePrefix}/"
		if ssh ${DATA_MANAGER}@${sourceServerFQDN} "head -1 "${sampleSheet}" | grep 'SentrixBarcode_A'"
		then
			colnum="$(ssh ${DATA_MANAGER}@${sourceServerFQDN} "head -1 "${sampleSheet}" | sed 's/,/\n/g'| nl | grep 'SentrixBarcode_A$' | grep -o '[0-9][0-9]*'")"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found SentrixBarcode_A in column number ${colnum}."
			barcodes=($(ssh ${DATA_MANAGER}@${sourceServerFQDN} "tail -n +2 "${sampleSheet}" | cut -d , -f "${colnum}" | sort | uniq"))
		else
			barcodes=("${filePrefix}")
		fi
		numberOfBarcodes=${#barcodes[@]}
		count=0
		for barcode in "${barcodes[@]}"
		do
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${barcode} ..."
			mkdir -m 2770 -p "${PRM_ROOT_DIR}/logs/${barcode}/"
			mkdir -m 2770 -p "${PRM_ROOT_DIR}/logs/${filePrefix}/"
			mkdir -m 2750 -p "${PRM_ROOT_DIR}/Samplesheets/archive/"
			echo "counting: ${count} of ${numberOfBarcodes}" 

			if ssh ${DATA_MANAGER}@${sourceServerFQDN} test -e "${SCR_ROOT_DIR}/${STEPBEFOREFINISHEDFILEPATH}/${barcode}/${STEPBEFOREFINISHEDFILE}"
			then
				count=$((count+1))
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/${STEPBEFOREFINISHEDFILEPATH}/${barcode}/${STEPBEFOREFINISHEDFILE} present."
				rsyncRuns "${barcode}" "${count}" "${numberOfBarcodes}"

			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/${STEPBEFOREFINISHEDFILEPATH}/${barcode}/${STEPBEFOREFINISHEDFILE} absent."
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${barcode}."
			fi
		done
	
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${count} ${numberOfBarcodes}"
		if [ "${count}" == "${numberOfBarcodes}" ]
		then
			touch "${PRM_ROOT_DIR}/logs/${filePrefix}/run01.${SCRIPT_NAME}.finished"
			splitSamplesheetPerProject "${filePrefix}"
		fi

	done
fi

log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'
echo "done" > "${PRM_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"

trap - EXIT
exit 0

