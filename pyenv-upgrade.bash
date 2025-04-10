#!/usr/bin/env bash

set -o errexit -o errtrace -o noclobber -o nounset -o pipefail

trap 'e=$?; if [ "$e" -ne "0" ]; then printf "LINE %s: exit %s <- %s%s\\n" "$BASH_LINENO" "$e" "${BASH_COMMAND}" "$(printf " <- %s" "${FUNCNAME[@]:-main}")" 1>&2; fi' EXIT


PROGNAME="${0##*/}"
VERBOSITY="${VERBOSITY:-}"


_log_msg() {
	local level
	local ansi_escapes

	if [ "$#" -eq "0" ]; then
		_log_msg error "${FUNCNAME[0]} requires at least one argument"
		return 1
	elif [ "$#" -eq "1" ]; then
		printf '%s\n' "$1" 1>&2
		return 0
	fi

	case "$(tr '[:lower:]' '[:upper:]' <<< "$1")" in
		DEBUG)
			if [ -z "${VERBOSITY:-}" ] || [ "${#VERBOSITY}" -lt "3" ]; then
				return 0
			fi
			level='DEBUG'
			ansi_escapes="$(tput setaf 2)"
			;;
		INFO)
			if [ -z "${VERBOSITY:-}" ] || [ "${#VERBOSITY}" -lt "1" ]; then
				return 0
			fi
			level='INFO'
			ansi_escapes="$(tput setaf 2)"
			;;
		WARN*)
			level='WARN'
			ansi_escapes="$(tput setaf 3)"
			;;
		ERROR)
			level='ERROR'
			ansi_escapes="$(tput setaf 0)$(tput setab 1)"
			;;
		*)
			level="$1"
			ansi_escapes=''
			if [ "$#" -gt "2" ]; then
				ansi_escapes="$2"
				shift
			fi
			;;
	esac
	shift

	if [ -z "$level" ]; then
		for msg in "$@"; do
			printf '%s%s%s\n' "${ansi_escapes:-}" "$msg" "${ansi_escapes:+$(tput sgr0)}" 1>&2
		done
	else
		printf '%s%s%s: ' "${ansi_escapes:-}" "$level" "${ansi_escapes:+$(tput sgr0)}" 1>&2
		printf '%s\n' "$@" | \
			sed "$(printf '2,$s/^/%*s/' "$((${#level} + 2))" '')" 1>&2
	fi
}

log_debug() {
	_log_msg debug "$@"
}

log_info() {
	_log_msg info "$@"
}

log_warn() {
	_log_msg warn "$@"
}

log_error() {
	_log_msg error "$@"
}

log_verbose() {
	if [ -n "${VERBOSITY:-}" ] && [ "${#VERBOSITY}" -ge "2" ]; then
		log_info "$@"
	fi
}

get_context() {
	local line
	local subroutine
	local filename
	line="$1"
	subroutine='call'
	if [ "$#" -eq "2" ]; then
		filename="$2"
	elif [ "$#" -eq "3" ]; then
		subroutine="$2"
		filename="$3"
	else
		log_error 'incorrect number of arguments!'
		exit 1
	fi
	printf '%s%s on line %d of %s:%s\n' "$(tput setaf 1)" "$subroutine" "$line" "$filename" "$(tput sgr0)"
	awk 'NR>L-4 && NR<L+4 { printf "%-5d%3s%s\n",NR,(NR==L?">>>":""),$0 }' L="$line" "$filename"
}

log_stack_trace() {
	local last_exit=$?
	local depth
	local call_info
	if [ "$last_exit" -ne "0" ]; then
		declare -i depth="${1:-$((${#FUNCNAME[@]} - 2))}"
		while [ "$depth" -ge "0" ] && call_info=($(caller "$depth" 2>/dev/null)); do
			log_error "$(get_context "${call_info[0]}" "${call_info[1]}" "${call_info[*]:2}")"
			(( depth -= 1 ))
		done
		call_info=($(caller 0))
		log_error "$(printf '%s(%d): %s -> exit %d\n' "${call_info[*]:2}" "${call_info[0]}" "${call_info[1]}" "$last_exit")"
	fi
}

append_trap () {
	local trap_cmd
	local trap_sig
	local old_trap_cmd

	trap_cmd="$1"
	trap_sig="$2"

	old_trap_cmd="$(trap -p "$trap_sig" | sed -E -e "s/^[^'\"]*['\"]//" -e "s/['\"][[:space:]]*${trap_sig}\$//")"
	if [[ -n "$old_trap_cmd" ]]; then
		trap_cmd="$old_trap_cmd; $trap_cmd"
	fi
	trap "$trap_cmd" "$trap_sig"
}

trap 'log_stack_trace' EXIT

get_script_dir() {
	## resolve the directory of the given script
	# example:
	# 	SCRIPTDIR="$(get_script_dir "${BASH_SOURCE[0]}")"
	SOURCE="${1}"
	#SOURCE="${BASH_SOURCE[0]}"
	while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
		SCRIPTDIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
		SOURCE="$(readlink "$SOURCE")"
		[[ $SOURCE != /* ]] && SOURCE="$SCRIPTDIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
	done
	SCRIPTDIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
	printf '%s\n' "${SCRIPTDIR}"
}

contains_value() {
	local value
	value="$1"
	shift
	for arg in "$@"; do
		if [ "$value" == "$arg" ]; then
			return 0
		fi
	done
	return 1
}

get_installed() {
	pyenv versions --bare --skip-aliases --skip-envs
}

get_available() {
	pyenv install --list | \
		sed -n '2,$p' | \
		sed 's/^[[:space:]]*//'
}

remove_dev_versions() {
	local dev_versions
	dev_versions=()
	while IFS=	read -r; do
		if ! printf '%s\n' "$REPLY" | grep -Eiv -e '-dev$' -e '-src$' -e '-latest$' -e '(a|b|rc)[0-9]+$' -e '[0-9]t$'; then
			dev_versions+=("$REPLY")
		fi
	done < <(cat -)
	if [ "${#dev_versions[@]}" -gt "0" ]; then
		log_verbose "excluding ${#dev_versions[@]} dev versions:" "${dev_versions[@]}"
	fi
}

get_prefix_pattern() {
	local escaped_prefix
	escaped_prefix="$(printf '%s\n' "$1" | sed 's/[.-]/\\&/g')"
	printf '^%s([.-].*)?$\n' "$escaped_prefix"
}

main() {
	local OLD_VERBOSITY
	local OPTIND
	local OPTARG
	local func_name
	local main_usage
	local additive_opts
	local provided_opts

	local verbosity
	local list

	verbosity=()
	list=""

	func_name="${0##*/}"

	main_usage() {
		cat <<EOF | sed 's/^\t\t//' >&2
		NAME
			${func_name} -- CLI utility to update Python versions installed with
			pyenv.

		SYNOPSIS
			${func_name} [-hvl] [<VERSION_PREFIX>]

		DESCRIPTION
			pyenv-upgrade is a CLI utility to update Python versions installed
			with pyenv.

			The options are as follows:

			-h	print this help and exit

			-v	increase verbosity
				(may be given more than once)

			-l	list matching versions and exit without installing

			Positional Arguments:

			<VERSION_PREFIX>
				(optional) Python version prefix to check (e.g. 3, 3.12)


EOF
	}

	additive_opts=("v")

	# tracks which options have been provided
	provided_opts=()
	while getopts ':hvl' opt; do
		if \
			! grep --quiet --fixed-strings --line-regexp --regexp="$opt" <(printf '%s\n' "${additive_opts[@]:-}") && \
			grep --quiet --fixed-strings --line-regexp --regexp="$opt" <(printf '%s\n' "${provided_opts[@]:-}");
		then
			main_usage
			log_error "option cannot be given more than once: $opt"
			exit 1
		fi

		case "$opt" in
			h)
				main_usage
				exit 0
				;;
			v)
				verbosity+=("y")
				;;
			l)
				list="y"
				;;
			':')
				main_usage
				log_error "option requires an argument value: ${OPTARG}"
				exit 1
				;;
			'?')
				main_usage
				log_error "unknown option: ${OPTARG}"
				exit 1
				;;
			*)
				main_usage
				log_error "CLI error due to unhandled option: opt='$opt'\tOPTARG='$OPTARG'"
				exit 1
				;;
		esac
		provided_opts+=("$opt")
	done
	shift $((OPTIND - 1))

	OLD_VERBOSITY="${VERBOSITY:-}"
	VERBOSITY="$(printf '%s' "${verbosity[@]:-}")"

	if [ "$#" -gt "1" ]; then
		main_usage
		log_error "up to 1 positional argument(s) allowed but got $#:" "$@"
		exit 1
	fi

	log_debug "verbosity:" "${verbosity[@]:-}"
	log_debug "list: ${list:-}"
	if [[ "$#" -gt "0" ]]; then
		log_debug "positional args:" "$@"
	else
		log_debug 'no positional args given'
	fi

	local prefix_pattern
	local installed
	local available
	local latest_installed
	local latest_available

	installed=()
	available=()
	if [ "$#" -gt "0" ]; then
		prefix_pattern="$(get_prefix_pattern "$1")"
	else
		prefix_pattern='.*'
		if [ "${VERBOSITY:-}" == "" ]; then
			VERBOSITY="v"
		fi
	fi

	# get installed versions
	while IFS=	read -r; do \
		installed+=("$REPLY")
	done < <(get_installed | grep -Eo "$prefix_pattern" | remove_dev_versions | uniq)

	# get available versions
	while IFS=	read -r; do \
		available+=("$REPLY")
	done < <(get_available | grep -Eo "$prefix_pattern" | remove_dev_versions | uniq)

	if [ "$#" -eq "0" ]; then
		if [ "${#installed[@]}" -gt "0" ]; then
			log_info "${#installed[@]} installed versions:" "${installed[@]}"
		else
			log_info 'no versions currently installed'
		fi

		if [ "${#available[@]}" -gt "0" ]; then
			log_info "${#available[@]} available versions:" "${available[@]}"
		else
			log_error 'no installable version could be found!'
			exit 2
		fi
		return 0
	else
		if [ "${#installed[@]}" -gt "0" ]; then
			log_info "${#installed[@]} installed versions matching '$prefix_pattern':" "${installed[@]}"
			# latest_installed="${installed[${#installed[@]}-1]}"
			latest_installed="$(pyenv latest "$1")"
			log_info "latest installed version: $latest_installed"
		else
			log_warn "no versions matching '$prefix_pattern' currently installed"
			latest_installed=""
		fi

		if [ "${#available[@]}" -gt "0" ]; then
			log_info "${#available[@]} available versions matching '$prefix_pattern':" "${available[@]}"
			# latest_available="${available[${#available[@]}-1]}"
			latest_available="$(pyenv latest --known "$1")"
			log_info "latest available version: $latest_available"
		else
			log_error 'no installable version could be found!'
			exit 2
		fi

		printf '%s\n' "$latest_available"
		if [ "$latest_installed" == "$latest_available" ]; then
			log_info 'already up to date!'
		elif [ -n "$list" ]; then
			log_warn "newer version available: $latest_installed -> $latest_available"
			return 1
		else
			log_warn "installing: $latest_available"
			>&2 pyenv install --skip-existing "$latest_available"
			log_info 'temporarily activating installed version in shell and updating pip and setuptools'
			eval "$(pyenv init -)"
			>&2 pyenv rehash
			>&2 pyenv shell "$latest_available"
			>&2 python -m pip install --upgrade --upgrade-strategy=eager pip setuptools
			>&2 pyenv shell -
		fi
	fi

	VERBOSITY="${OLD_VERBOSITY:-}"
}

main "$@"

