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

get_installed() {
	pyenv versions | \
		sed -E -e 's/^\*?[[:space:]]*//' -e 's/[[:space:]].*//' | \
		grep -v 'system' | \
		sort --version-sort
}

get_available() {
	pyenv install --list | \
		sed -n '2,$p' | \
		sed 's/^[[:space:]]*//' | \
		sort --version-sort
}

get_prefix_pattern() {
	local escaped_prefix
	escaped_prefix="$(printf '%s\n' "$1" | sed 's/[.-]/\\&/g')"
	printf '^%s([.-].*)?$\n' "$escaped_prefix"
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
		prefix_pattern='^[^.-]+[.-][^.-]+'
	fi

	# get installed versions
	while IFS=	read -r; do \
		installed+=("$REPLY")
	done < <(get_installed | grep -Eo "$prefix_pattern" | uniq)

	# get available versions
	while IFS=	read -r; do \
		available+=("$REPLY")
	done < <(get_available | grep -Eo "$prefix_pattern" | uniq)

	if [ "$#" -eq "0" ]; then
		if [ "${#installed[@]}" -gt "0" ]; then
			>&2 printf '%d installed versions:\n' "${#installed[@]}"
			>&2 printf '\t%s\n' "${installed[@]}"
		else
			>&2 printf 'no versions currently installed\n'
		fi

		if [ "${#available[@]}" -gt "0" ]; then
			>&2 printf 'available versions:\n'
			>&2 printf '%d available versions:\n' "${#available[@]}"
			>&2 printf '\t%s\n' "${available[@]}"
		else
			>&2 printf '%sERROR%s: no installable version could be found!\n' "$(tput setaf 1)" "$(tput sgr0)"
			exit 2
		fi
		return 0
	else
		if [ "${#installed[@]}" -gt "0" ]; then
			>&2 printf '%d installed versions matching "%s":\n' "${#installed[@]}" "$prefix_pattern"
			>&2 printf '\t%s\n' "${installed[@]}"
			# latest_installed="$(printf '%s\n' "${installed[@]}" | sed -n '$p')"
			latest_installed="$(printf '%s\n' "${installed[${#installed[@]}-1]}")"
			>&2 printf 'latest installed version: %s\n' "$latest_installed"
		else
			>&2 printf 'no versions matching "%s" currently installed:\n' "$prefix_pattern"
			latest_installed=""
		fi

		if [ "${#available[@]}" -gt "0" ]; then
			>&2 printf '%d available versions matching "%s":\n' "${#available[@]}" "$prefix_pattern"
			>&2 printf '\t%s\n' "${available[@]}"
			# latest_available="$(printf '%s\n' "${available[@]}" | sed -n '$p')"
			latest_available="$(printf '%s\n' "${available[${#available[@]}-1]}")"
			>&2 printf 'latest available version: %s\n' "$latest_available"
		else
			>&2 printf '%sERROR%s: no installable version could be found!\n' "$(tput setaf 1)" "$(tput sgr0)"
			exit 2
		fi

		printf '%s\n' "$latest_available"
		if [ "$latest_installed" == "$latest_available" ]; then
			>&2 printf 'already up to date!\n'
		elif [ -n "$list" ]; then
			>&2 printf 'newer version available\n'
			return 1
		else
			>&2 printf 'installing: %s\n' "$latest_available"
			>&2 pyenv install "$latest_available"
			>&2 printf 'temporarily activating installed version in shell and updating pip and setuptools\n'
			>&2 pyenv shell "$latest_available"
			>&2 python -m pip install --upgrade --upgrade-strategy=eager pip setuptools
			>&2 pyenv shell -
		fi
	fi
}

main "$@"

