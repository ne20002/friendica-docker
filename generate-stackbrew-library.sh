#!/bin/bash
set -Eeuo pipefail

declare -A release_channel=(
  [stable]=$( cat latest.txt )
)

self="$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# Get the most recent commit which modified any of "$@".
fileCommit() {
  commit="$(git log -1 --format='format:%H' HEAD -- "$@")"
  if [ -z "$commit" ]; then
    # return some valid sha1 hash to make bashbrew happy
    echo '0000000000000000000000000000000000000000'
  else
    echo "$commit"
  fi
}

# Get the most recent commit which modified "$1/Dockerfile" or any file that
# the Dockerfile copies into the rootfs (with COPY).
dockerfileCommit() {
  local dir="$1"; shift
  (
    cd "$dir";
    fileCommit Dockerfile \
      $(awk '
        toupper($1) == "COPY" {
          for (i = 2; i < NF; i++)
              print $i;
        }
      ' Dockerfile)
  )
}

getArches() {
  local repo="$1"; shift
  local officialImagesUrl='https://github.com/docker-library/official-images/raw/master/library/'

  eval "declare -g -A parentRepoToArches=( $(
    find -maxdepth 3 -name 'Dockerfile' -exec awk '
        toupper($1) == "FROM" && $2 !~ /^('"$repo"'|scratch|microsoft\/[^:]+)(:|$)/ {
          print "'"$officialImagesUrl"'" $2
        }
      ' '{}' + \
      | sort -u \
      | xargs bashbrew cat --format '[{{ .RepoName }}:{{ .TagName }}]="{{ join " " .TagEntry.Architectures }}"'
  ) )"
}
getArches 'friendica'

# Header.
cat <<-EOH
# This file is generated via https://github.com/friendica/docker/blob/$(fileCommit "$self")/$self

Maintainers: Friendica <info@friendi.ca> (@friendica), Philipp Holzer <admin@philipp.info> (@nupplaphil), @ne20002
GitRepo: https://github.com/friendica/docker.git
GitFetch: refs/heads/stable
EOH

# prints "$2$1$3$1...$N"
join() {
  local sep="$1"; shift
  local out; printf -v out "${sep//%/%%}%s" "$@"
  echo "${out#$sep}"
}

latest=$( cat latest.txt )
develop=$( cat develop.txt )

# Generate each of the tags.
versions=( */ )
versions=( "${versions[@]%/}" )
for version in "${versions[@]}"; do
  variants=( $version/*/ )
  variants=( $(for variant in "${variants[@]%/}"; do
    basename "$variant"
  done) )
  for variant in "${variants[@]}"; do
    commit="$(dockerfileCommit "$version/$variant")"

    versionAliases=( )
    versionPostfix=""

    versionAliases+=( "$version$versionPostfix" )
    if [ "$version" = "$latest" ]; then
			versionAliases+=( "latest" )
		fi

    if [[ "$version" == *-rc ]]; then
      versionAliases+=( "rc" )
    fi
    if [[ "$version" == "$develop" ]]; then
      versionAliases+=( "dev" )
    fi

    for channel in "${!release_channel[@]}"; do
      if [ "$version" = "${release_channel[$channel]}" ]; then
        versionAliases+=( "$channel" )
      fi
    done

    variantAliases=( "${versionAliases[@]/%/-$variant}" )
    variantAliases=( "${variantAliases[@]//latest-}" )

    if [ "$variant" = "apache" ]; then
      variantAliases+=( "${versionAliases[@]}" )
    fi

    variantParent="$(awk 'toupper($1) == "FROM" { print $2 }' "$version/$variant/Dockerfile")"
    # shellcheck disable=SC2154
    variantArches="${parentRepoToArches[$variantParent]}"

    cat << EOE

Tags: $(join ', ' "${variantAliases[@]}")
Architectures: $(join ', ' $variantArches)
GitCommit: $commit
Directory: $version/$variant
EOE
  done
done
