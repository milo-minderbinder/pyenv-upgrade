#!/usr/bin/env bash

set -o errexit -o errtrace -o noclobber -o nounset -o pipefail

trap 'e=$?; if [ "$e" -ne "0" ]; then printf "LINE %s: exit %s <- %s%s\\n" "$BASH_LINENO" "$e" "${BASH_COMMAND}" "$(printf " <- %s" "${FUNCNAME[@]:-main}")" 1>&2; fi' EXIT


PROGNAME="${0##*/}"


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

main() {
	local OPTIND
	local OPTARG
	local func_name
	local usage
	local required_opts
	local additive_opts
	local min_positional_args
	local max_positional_args
	local provided_opts
	local missing_opts

	local verbosity
	local list

	verbosity=()
	list=""

	func_name="$PROGNAME"

	usage() {
		>&2 cat <<EOF | sed 's/^\t\t//'
		NAME
			${func_name} -- CLI utility to update Python versions installed with pyenv.

		SYNOPSIS
			${func_name} [-hvl] [VERSION_PREFIX]

		DESCRIPTION
			pyenv-upgrade is a CLI utility to update Python versions installed with pyenv.

			The options are as follows:

			-h	print this help and exit

			-v	increase verbosity
				may be given more than once

			-l	list matching versions and exit without installing

EOF
	}

	# options which must be given
	required_opts=()
	# options which may be given more than once
	additive_opts=("v")
	# minimum number of positional arguments allowed (ignored if empty)
	min_positional_args=""
	# maximum number of positional arguments allowed (ignored if empty)
	max_positional_args="1"

	# tracks which options have been provided
	provided_opts=()
	while getopts 'hvl' opt; do
		if ! contains_value "$opt" "${additive_opts[@]:-}" && contains_value "$opt" "${provided_opts[@]:-}"; then
			>&2 printf '%s:%d: option cannot be given more than once -- %s\n' "$0" "$BASH_LINENO" "$opt"
			usage
			exit 1
		fi

		case "$opt" in
			h)
				usage
				exit 0
				;;
			v)
				verbosity+=("y")
				;;
			l)
				list="y"
				;;
			*)
				usage
				exit 1
				;;
		esac
		provided_opts+=("$opt")
	done
	shift $((OPTIND - 1))

	if [ -n "$min_positional_args" ] && [ "$#" -lt "$min_positional_args" ]; then
		>&2 printf '%s:%d: at least %d positional argument(s) are needed but got %d -- %s\n' "$0" "$BASH_LINENO" "$min_positional_args" "$#" "$(printf "'%s' " "$@")"
		usage
		exit 1
	fi
	if [ -n "$max_positional_args" ] && [ "$#" -gt "$max_positional_args" ]; then
		>&2 printf '%s:%d: up to %d positional argument(s) are allowed but got %d -- %s\n' "$0" "$BASH_LINENO" "$max_positional_args" "$#" "$(printf "'%s' " "$@")"
		usage
		exit 1
	fi

	if [ "${#required_opts[@]}" -gt "0" ]; then
		missing_opts=()
		for opt in "${required_opts[@]}"; do
			if ! contains_value "$opt" "${provided_opts[@]:-}"; then
				missing_opts+=("${opt}")
			fi
		done
		if [ "${#missing_opts[@]}" -gt "0" ]; then
			>&2 printf '%s:%d: missing required options -- %s\n' "$0" "$BASH_LINENO" "${missing_opts[*]}"
			usage
			exit 1
		fi
	fi

	>&2 printf 'verbosity: "%s"\n' "${verbosity[@]:-}"
	>&2 printf 'list: "%s"\n' "${list:-}"
}

main "$@"

